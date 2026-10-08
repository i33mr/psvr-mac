import AVFoundation
import CoreVideo
import Metal
import simd

/// A frame in 4:2:0 YCbCr, as two Metal textures, plus the matrix that turns it into RGB. The
/// shader converts only the pixels it shows; converting a whole 8K frame to RGB beforehand costs
/// enough GPU time to make the headset miss refreshes.
struct VideoFrame {
    let luma: MTLTexture
    let chroma: MTLTexture
    /// rgb = matrix * (ycbcr - offset)
    let matrix: simd_float3x3
    let offset: SIMD3<Float>
    /// Increases with every new frame (the renderer uses it to rebuild mipmaps once per frame).
    let sequence: Int
    var width: Int { luma.width }
    var height: Int { luma.height }
}

/// Where the renderer gets frames from: a video file or a live window/screen capture.
protocol FrameSource: AnyObject {
    /// The frame to show at `hostTime` (nil until the first frame arrives).
    func frame(hostTime: CFTimeInterval) -> VideoFrame?
    /// Frames handed out so far (for --stats).
    var newFrames: Int { get }
    /// Downscaled sampling with mipmaps: sharp, shimmer-free text for screen capture.
    var wantsMipmaps: Bool { get }
}

/// Turns decoder/capture pixel buffers into `VideoFrame`s without copying.
final class FrameConverter {
    private var cache: CVMetalTextureCache?
    private var sequence = 0

    /// Biplanar 4:2:0 formats; AVFoundation picks the one the decoder produces natively.
    static let formats: [OSType] = [
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]

    init(device: MTLDevice) {
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    /// The frame plus the CoreVideo textures that keep its memory alive.
    func makeFrame(_ buffer: CVPixelBuffer) -> (frame: VideoFrame, keepAlive: [CVMetalTexture])? {
        guard let cache, CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let fullRange = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        func plane(_ index: Int, _ pixelFormat: MTLPixelFormat) -> CVMetalTexture? {
            var texture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, buffer, nil, pixelFormat,
                CVPixelBufferGetWidthOfPlane(buffer, index), CVPixelBufferGetHeightOfPlane(buffer, index),
                index, &texture)
            return texture
        }
        guard let y = plane(0, tenBit ? .r16Unorm : .r8Unorm),
              let c = plane(1, tenBit ? .rg16Unorm : .rg8Unorm),
              let luma = CVMetalTextureGetTexture(y),
              let chroma = CVMetalTextureGetTexture(c) else { return nil }

        let matrixKey = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let (matrix, offset) = Self.conversion(matrix: matrixKey, fullRange: fullRange)
        sequence += 1
        return (VideoFrame(luma: luma, chroma: chroma, matrix: matrix, offset: offset, sequence: sequence), [y, c])
    }

    /// YCbCr -> RGB for the frame's colour matrix and range (10-bit samples are MSB-aligned,
    /// so normalised values match 8-bit).
    static func conversion(matrix: String?, fullRange: Bool) -> (simd_float3x3, SIMD3<Float>) {
        let (kr, kb): (Float, Float)
        switch matrix {
        case String(kCVImageBufferYCbCrMatrix_ITU_R_601_4): (kr, kb) = (0.299, 0.114)
        case String(kCVImageBufferYCbCrMatrix_ITU_R_2020): (kr, kb) = (0.2627, 0.0593)
        default: (kr, kb) = (0.2126, 0.0722)   // BT.709, also the safe default for HD/UHD
        }
        let kg = 1 - kr - kb
        // Columns: contribution of Y, Cb, Cr to (R, G, B).
        var m = simd_float3x3(
            SIMD3(1, 1, 1),
            SIMD3(0, -2 * kb * (1 - kb) / kg, 2 * (1 - kb)),
            SIMD3(2 * (1 - kr), -2 * kr * (1 - kr) / kg, 0))
        if fullRange {
            return (m, SIMD3(0, 0.5, 0.5))
        }
        let yScale: Float = 255 / 219, cScale: Float = 255 / 224
        m.columns.0 *= yScale
        m.columns.1 *= cScale
        m.columns.2 *= cScale
        return (m, SIMD3(16.0 / 255, 0.5, 0.5))
    }
}

/// AVPlayer whose decoded frames are exposed as Metal textures.
final class VideoSource: FrameSource {
    let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let converter: FrameConverter
    private var current: (frame: VideoFrame, keepAlive: [CVMetalTexture])?

    init(url: URL, device: MTLDevice) {
        let item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: FrameConverter.formats,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        converter = FrameConverter(device: device)
    }

    private var loopObserver: NSObjectProtocol?

    /// Restart from the beginning whenever the end is reached.
    var loops = false {
        didSet {
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
            loopObserver = nil
            guard loops else { return }
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
            ) { [player] _ in
                player.seek(to: .zero)
                player.play()
            }
        }
    }

    var error: Error? { player.currentItem?.error }
    private(set) var newFrames = 0
    var wantsMipmaps: Bool { false }

    func frame(hostTime: CFTimeInterval) -> VideoFrame? {
        let time = output.itemTime(forHostTime: hostTime)
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
           let made = converter.makeFrame(buffer) {
            current = made
            newFrames += 1
        }
        return current?.frame
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if let item = player.currentItem, item.currentTime() >= item.duration { player.seek(to: .zero) }
            player.play()
        }
    }

    func seek(by seconds: Double) {
        let target = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: CMTimeMaximum(target, .zero), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private var tracksObservation: NSKeyValueObservation?

    /// No sound at all: the audio tracks are switched off, so no sound device is even opened
    /// (muting alone still streams silence to the current output).
    func disableAudio() {
        player.isMuted = true
        let apply = { [weak self] in
            for track in self?.player.currentItem?.tracks ?? [] where track.assetTrack?.mediaType == .audio {
                track.isEnabled = false
            }
        }
        apply()
        tracksObservation = player.currentItem?.observe(\.tracks) { _, _ in DispatchQueue.main.async(execute: apply) }
    }

    func stop() {
        loops = false
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
