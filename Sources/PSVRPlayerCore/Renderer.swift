import CoreGraphics
import Metal
import os
import PSVRKit
import QuartzCore
import simd

struct EyeUniforms {
    var rot0, rot1, rot2: SIMD4<Float>
    var videoRect: SIMD4<Float>
    var fov: SIMD4<Float>
    var k: SIMD4<Float>
    var params: SIMD4<Float>
    var aberration: SIMD4<Float>
    var mode: SIMD4<Float>
    var color0, color1, color2: SIMD4<Float>
    var colorOffset: SIMD4<Float>
    var meshInfo: SIMD4<Float>
}

/// PSVR lens model (panotools, values from Monado's PSVR driver).
enum Lens {
    static let k = SIMD4<Float>(0.75, -0.01, 0.75, 0.0)
    static let k4: Float = 3.8
    static let aberration = SIMD3<Float>(0.999, 1.008, 1.018)
    static let scaleFactor: Float = 1.2   // times eye viewport width
}

/// What the viewer controls. Changed on the main thread (keys, mouse), read once per frame
/// on the render thread.
struct ViewState {
    var projection: Projection = .equirect360
    var layout: StereoLayout = .mono
    var formatResolved = false
    var swapEyes = false
    var distortion: Bool
    var fovDegrees: Float              // horizontal, per eye
    var flatScreenDegrees: Float = 70  // horizontal size of the virtual screen
    var mouseYaw: Float = 0
    var mousePitch: Float = 0
    /// Draw nothing (headset taken off).
    var blanked = false
    /// Turns the two eye views apart (positive: images move outwards, the scene feels farther away).
    /// Matches the stereo image to the viewer's eye spacing.
    var stereoSeparationDegrees: Float = 0
}

/// Renders both eyes for one display refresh. Called on the render thread by `RenderLoop`.
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let placeholderLuma: MTLTexture
    private let placeholderChroma: MTLTexture
    /// Direction -> texture coordinate table for mesh projections (6 faces per mesh).
    private let meshLUT: MTLTexture
    private let meshCount: Int
    var hasMesh: Bool { meshCount > 0 }

    let tracker: OrientationTracker?
    let source: FrameSource?
    var video: VideoSource? { source as? VideoSource }
    /// Mipmapped copies of the current frame (screen capture): smooth downscaling for text.
    private var mipLuma: MTLTexture?
    private var mipChroma: MTLTexture?
    private var mippedSequence = -1
    private let requestedProjection: Projection?
    private let requestedLayout: StereoLayout?
    private let state: OSAllocatedUnfairLock<ViewState>

    var onFormatResolved: ((Projection, StereoLayout, Int, Int) -> Void)?
    /// The headset display: if it isn't connected, frames are drawn black (so a window macOS moves to
    /// another screen shows nothing).
    var requiredDisplay: CGDirectDisplayID?

    /// The PSVR's OLED lights up a few ms after the frame's presentation time.
    private let panelLatency: Double = 0.003

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, tracker: OrientationTracker?, source: FrameSource?,
         projection: Projection?, layout: StereoLayout?, distortion: Bool, fovDegrees: Float,
         meshes: [SphericalMesh] = []) throws {
        self.device = device
        queue = device.makeCommandQueue()!
        self.tracker = tracker
        self.source = source
        self.requestedProjection = projection
        self.requestedLayout = layout

        var initial = ViewState(distortion: distortion, fovDegrees: fovDegrees)
        if source == nil {
            initial.projection = projection ?? .equirect360
            initial.formatResolved = true
        }
        state = OSAllocatedUnfairLock(initialState: initial)

        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        desc.fragmentFunction = library.makeFunction(name: "eye_fragment")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear          // only matters for mipmapped (captured) frames
        s.maxAnisotropy = 8            // keeps a tilted virtual screen sharp
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)!

        placeholderLuma = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false))!
        placeholderChroma = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg8Unorm, width: 1, height: 1, mipmapped: false))!

        meshCount = min(meshes.count, 2)
        meshLUT = try Self.buildMeshLUT(device: device, queue: queue, library: library, meshes: Array(meshes.prefix(2)))
    }

    /// Thread-safe access for the UI.
    func update<T>(_ change: (inout ViewState) -> T) -> T { state.withLockUnchecked(change) }
    var current: ViewState { state.withLockUnchecked { $0 } }

    // MARK: - Frame pacing stats (--stats)

    /// Prints frame pacing once a second: how many display refreshes each video frame stayed up.
    var printsStats = false
    private var statsStart = CACurrentMediaTime()
    private var draws = 0
    private var missedRefreshes = 0
    private var lastPresentTime: CFTimeInterval?
    private var refreshesSinceNewFrame = 0
    private var holdHistogram: [Int: Int] = [:]
    private var lastNewFrames = 0
    private let gpuTimes = OSAllocatedUnfairLock(initialState: [Double]())

    private func recordStats(newFrame: Bool, presentTime: CFTimeInterval) {
        draws += 1
        // Gaps between target times reveal refreshes we never rendered for.
        let refresh = 1.0 / 120
        if let last = lastPresentTime {
            let slots = Int(((presentTime - last) / refresh).rounded())
            if slots > 1 { missedRefreshes += slots - 1 }
            refreshesSinceNewFrame += max(slots, 1)
        } else {
            refreshesSinceNewFrame += 1
        }
        lastPresentTime = presentTime
        if newFrame {
            holdHistogram[refreshesSinceNewFrame, default: 0] += 1
            refreshesSinceNewFrame = 0
        }
        let now = CACurrentMediaTime()
        guard now - statsStart >= 1 else { return }
        let holds = holdHistogram.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        let rate = video?.player.rate ?? 0
        let gpu = gpuTimes.withLock { times in defer { times = [] }; return times }
        print(String(format: "stats: %3.0f renders/s, %d missed, GPU %.1f ms avg %.1f max, %2d video frames/s, refreshes per frame: %@%@",
                     Double(draws) / (now - statsStart), missedRefreshes,
                     gpu.isEmpty ? 0 : gpu.reduce(0, +) / Double(gpu.count) * 1000, (gpu.max() ?? 0) * 1000,
                     holdHistogram.values.reduce(0, +), holds, video != nil && rate == 0 ? "  (paused)" : ""))
        statsStart = now
        draws = 0
        missedRefreshes = 0
        holdHistogram = [:]
    }

    // MARK: - Rendering

    /// Renders the frame that will be on screen at `presentTime` (host time, as CACurrentMediaTime).
    func render(to drawable: CAMetalDrawable, at presentTime: CFTimeInterval) {
        // Pick the video frame for the moment this image is shown, not for now.
        let frame = source?.frame(hostTime: presentTime)
        if printsStats {
            let frames = source?.newFrames ?? 0
            recordStats(newFrame: frames != lastNewFrames, presentTime: presentTime)
            lastNewFrames = frames
        }
        if let frame, !current.formatResolved {
            let (projection, layout) = FormatGuess.complete(
                projection: requestedProjection, layout: requestedLayout,
                width: frame.width, height: frame.height)
            update {
                $0.projection = projection
                $0.layout = layout
                $0.formatResolved = true
            }
            onFormatResolved?(projection, layout, frame.width, frame.height)
        }
        let view = current

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer() else { return }
        if view.blanked || requiredDisplay.map({ CGDisplayIsOnline($0) == 0 }) == true {
            commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()   // clear to black only
            commands.present(drawable)
            commands.commit()
            return
        }
        var luma = frame?.luma, chroma = frame?.chroma
        if let frame, source?.wantsMipmaps == true {
            (luma, chroma) = mipmapped(frame, commands)
        }
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Head pose predicted for when the panel lights up.
        let ahead = Float(presentTime + panelLatency - CACurrentMediaTime())
        var head = tracker.map { simd_float3x3($0.predictedOrientation(ahead: ahead)) } ?? matrix_identity_float3x3
        head = simd_float3x3(simd_quatf(angle: -view.mouseYaw, axis: SIMD3(0, 1, 0))) * head
            * simd_float3x3(simd_quatf(angle: -view.mousePitch, axis: SIMD3(1, 0, 0)))

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(luma ?? placeholderLuma, index: 0)
        encoder.setFragmentTexture(chroma ?? placeholderChroma, index: 1)
        encoder.setFragmentTexture(meshLUT, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)

        let width = Double(drawable.texture.width), height = Double(drawable.texture.height)
        let eyeWidth = width / 2
        for eye in 0..<2 {
            encoder.setViewport(MTLViewport(originX: Double(eye) * eyeWidth, originY: 0,
                                            width: eyeWidth, height: height, znear: 0, zfar: 1))
            let turn = (eye == 0 ? -0.5 : 0.5) * view.stereoSeparationDegrees * .pi / 180
            let eyeHead = head * simd_float3x3(simd_quatf(angle: turn, axis: SIMD3(0, 1, 0)))
            var u = uniforms(view, eye: eye, head: eyeHead,
                             eyeSize: SIMD2(Float(eyeWidth), Float(height)), frame: frame)
            encoder.setFragmentBytes(&u, length: MemoryLayout<EyeUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        renderMirror(commands, view: view, head: head, frame: frame, luma: luma, chroma: chroma)
        if printsStats {
            commands.addCompletedHandler { [gpuTimes] cb in
                gpuTimes.withLock { $0.append(cb.gpuEndTime - cb.gpuStartTime) }
            }
        }
        commands.present(drawable)
        commands.commit()
    }

    // MARK: - Mirror on the Mac

    /// Left-eye view without lens distortion, for a preview window on the Mac. Three images in
    /// rotation: the window copies the newest finished one while the next is being drawn, so
    /// neither side ever waits for the other (or slows the headset).
    private var mirrorTargets: [MTLTexture] = []
    private let mirrorReady = OSAllocatedUnfairLock(initialState: -1)
    private var mirrorFrame = 0

    func enableMirror(width: Int, height: Int) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        mirrorTargets = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
    }

    /// The newest finished mirror image (nil until the first one).
    func latestMirror() -> MTLTexture? {
        let i = mirrorReady.withLock { $0 }
        return i >= 0 && i < mirrorTargets.count ? mirrorTargets[i] : nil
    }

    private func renderMirror(_ commands: MTLCommandBuffer, view: ViewState, head: simd_float3x3,
                              frame: VideoFrame?, luma: MTLTexture?, chroma: MTLTexture?) {
        guard mirrorTargets.count == 3 else { return }
        mirrorFrame += 1
        guard mirrorFrame % 2 == 0 else { return }   // 60 fps is plenty for a preview
        let write = (max(mirrorReady.withLock { $0 }, 0) + 1) % 3
        let target = mirrorTargets[write]

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(luma ?? placeholderLuma, index: 0)
        encoder.setFragmentTexture(chroma ?? placeholderChroma, index: 1)
        encoder.setFragmentTexture(meshLUT, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(target.width),
                                        height: Double(target.height), znear: 0, zfar: 1))
        var flat = view
        flat.distortion = false
        let turn = -0.5 * view.stereoSeparationDegrees * .pi / 180
        var u = uniforms(flat, eye: 0, head: head * simd_float3x3(simd_quatf(angle: turn, axis: SIMD3(0, 1, 0))),
                         eyeSize: SIMD2(Float(target.width), Float(target.height)), frame: frame)
        encoder.setFragmentBytes(&u, length: MemoryLayout<EyeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.addCompletedHandler { [mirrorReady] _ in mirrorReady.withLock { $0 = write } }
    }

    /// Copies a new frame into mipmapped textures (once per frame) and returns them.
    private func mipmapped(_ frame: VideoFrame, _ commands: MTLCommandBuffer) -> (MTLTexture?, MTLTexture?) {
        func target(_ existing: MTLTexture?, like t: MTLTexture) -> MTLTexture? {
            if let existing, existing.width == t.width, existing.height == t.height, existing.pixelFormat == t.pixelFormat {
                return existing
            }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: t.pixelFormat, width: t.width,
                                                             height: t.height, mipmapped: true)
            d.usage = [.shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let l = target(mipLuma, like: frame.luma), let c = target(mipChroma, like: frame.chroma) else {
            return (frame.luma, frame.chroma)
        }
        mipLuma = l
        mipChroma = c
        if frame.sequence != mippedSequence, let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: frame.luma, sourceSlice: 0, sourceLevel: 0, to: l, destinationSlice: 0, destinationLevel: 0,
                      sliceCount: 1, levelCount: 1)
            blit.copy(from: frame.chroma, sourceSlice: 0, sourceLevel: 0, to: c, destinationSlice: 0, destinationLevel: 0,
                      sliceCount: 1, levelCount: 1)
            blit.generateMipmaps(for: l)
            blit.generateMipmaps(for: c)
            blit.endEncoding()
            mippedSequence = frame.sequence
        }
        return (l, c)
    }

    /// Renders each mesh from the sphere's centre into six 90-degree faces, storing the texture
    /// coordinate seen in every direction. Without meshes it is a 1x1 placeholder.
    private static func buildMeshLUT(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary,
                                     meshes: [SphericalMesh]) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba16Unorm
        desc.width = meshes.isEmpty ? 1 : 512
        desc.height = desc.width
        desc.arrayLength = max(6 * meshes.count, 1)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        let lut = device.makeTexture(descriptor: desc)!
        guard !meshes.isEmpty else { return lut }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = library.makeFunction(name: "lut_vertex")
        pipelineDesc.fragmentFunction = library.makeFunction(name: "lut_fragment")
        pipelineDesc.colorAttachments[0].pixelFormat = .rgba16Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)

        let commands = queue.makeCommandBuffer()!
        for (m, mesh) in meshes.enumerated() {
            let positions = device.makeBuffer(bytes: mesh.positions, length: MemoryLayout<SIMD3<Float>>.stride * mesh.positions.count)!
            let uvs = device.makeBuffer(bytes: mesh.uvs, length: MemoryLayout<SIMD2<Float>>.stride * mesh.uvs.count)!
            let indices = device.makeBuffer(bytes: mesh.triangles, length: MemoryLayout<UInt32>.stride * mesh.triangles.count)!
            for face in 0..<6 {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = lut
                pass.colorAttachments[0].slice = m * 6 + face
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[0].storeAction = .store
                let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
                encoder.setRenderPipelineState(pipeline)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(positions, offset: 0, index: 0)
                encoder.setVertexBuffer(uvs, offset: 0, index: 1)
                var faceIndex = UInt32(face)
                encoder.setVertexBytes(&faceIndex, length: MemoryLayout<UInt32>.size, index: 2)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.triangles.count,
                                              indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
                encoder.endEncoding()
            }
        }
        commands.commit()
        commands.waitUntilCompleted()
        return lut
    }

    private func uniforms(_ view: ViewState, eye: Int, head: simd_float3x3, eyeSize: SIMD2<Float>, frame: VideoFrame?) -> EyeUniforms {
        let videoEye = view.swapEyes ? 1 - eye : eye
        var rect = SIMD4<Float>(0, 0, 1, 1)
        switch view.layout {
        case .mono: break
        case .sbs: rect = SIMD4(Float(videoEye) * 0.5, 0, 0.5, 1)
        case .tb: rect = SIMD4(0, Float(videoEye) * 0.5, 1, 0.5)
        }

        let tanX = tan(view.fovDegrees * .pi / 360)
        let tanY = tanX * eyeSize.y / eyeSize.x

        // Flat screen: keep the picture's aspect. Half-SBS/TB frames are ~16:9 overall.
        var aspect: Float = 16 / 9
        if let frame {
            let full = Float(frame.width) / Float(frame.height)
            let eyeAspect = full * rect.z / rect.w
            aspect = view.layout != .mono && (1.6...1.9).contains(full) ? full : eyeAspect
        }
        let halfW = tan(view.flatScreenDegrees * .pi / 360)
        let content: Float = source == nil ? 0 : (frame == nil ? 2 : 1)   // test pattern / video / loading
        let color = frame?.matrix ?? matrix_identity_float3x3
        let colorOffset = frame?.offset ?? .zero

        return EyeUniforms(
            rot0: SIMD4(head.columns.0, 0),
            rot1: SIMD4(head.columns.1, 0),
            rot2: SIMD4(head.columns.2, 0),
            videoRect: rect,
            fov: SIMD4(tanX, tanY, eyeSize.x, eyeSize.y),
            k: Lens.k,
            params: SIMD4(Lens.k4, Lens.scaleFactor * eyeSize.x, halfW, halfW / aspect),
            aberration: SIMD4(Lens.aberration, view.distortion ? 1 : 0),
            mode: SIMD4(view.projection.shaderValue, content, 0, 0),
            color0: SIMD4(color.columns.0, 0),
            color1: SIMD4(color.columns.1, 0),
            color2: SIMD4(color.columns.2, 0),
            colorOffset: SIMD4(colorOffset, 0),
            meshInfo: SIMD4(Float(meshCount == 2 ? videoEye * 6 : 0), 0, 0, 0)
        )
    }
}

/// Drives `Renderer` from the display's refresh on a dedicated high-priority thread, so main-thread
/// work (AppKit, AVFoundation) can never make it miss a refresh.
final class RenderLoop: NSObject, CAMetalDisplayLinkDelegate {
    private let renderer: Renderer
    private let link: CAMetalDisplayLink

    init(layer: CAMetalLayer, renderer: Renderer, refreshRate: Float) {
        self.renderer = renderer
        link = CAMetalDisplayLink(metalLayer: layer)
        super.init()
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: refreshRate, preferred: refreshRate)
    }

    private var runLoop: CFRunLoop?

    func start() {
        let thread = Thread { [link, weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            link.add(to: .current, forMode: .default)
            CFRunLoopRun()
        }
        thread.name = "render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops rendering and ends the render thread.
    func stop() {
        link.invalidate()
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        renderer.render(to: update.drawable, at: update.targetPresentationTimestamp)
    }
}

/// Shows the renderer's mirror image in a window on the Mac, at that display's own pace.
final class MirrorLoop: NSObject, CAMetalDisplayLinkDelegate {
    private let renderer: Renderer
    private let link: CAMetalDisplayLink
    private let queue: MTLCommandQueue
    private var runLoop: CFRunLoop?

    init(layer: CAMetalLayer, renderer: Renderer) {
        self.renderer = renderer
        link = CAMetalDisplayLink(metalLayer: layer)
        queue = renderer.device.makeCommandQueue()!
        super.init()
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    func start() {
        let thread = Thread { [link, weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            link.add(to: .current, forMode: .default)
            CFRunLoopRun()
        }
        thread.name = "mirror"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        link.invalidate()
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard let image = renderer.latestMirror(), let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return }
        let target = update.drawable.texture
        guard target.width == image.width, target.height == image.height else { blit.endEncoding(); return }
        blit.copy(from: image, to: target)
        blit.endEncoding()
        commands.present(update.drawable)
        commands.commit()
    }
}
