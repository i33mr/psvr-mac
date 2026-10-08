import AppKit
import Metal
import QuartzCore
import PSVRKit
import ScreenCaptureKit
import VideoToolbox

/// What to show in the headset.
public enum PlaybackSource {
    /// A video file. `info` comes from a download (otherwise it is read from the file).
    case file(URL, info: SphericalInfo? = nil)
    /// A Mac window or display on a virtual screen.
    case capture(SCContentFilter)
    /// Calibration grid.
    case testGrid
}

public struct PlaybackOptions {
    public var projection: Projection?
    public var layout: StereoLayout?
    public var swapEyes = false
    public var loop = false
    public var stats = false
    public var fov: Float?
    /// Use this NSScreen index instead of the PSVR display.
    public var screenIndex: Int?
    public var hz: Double = 120
    /// Play in a window on the Mac screen (mouse look, no lens correction).
    public var preview = false
    public var lens: Bool?
    public var keepVR = false
    /// Also show the headset view in a small window on the Mac (off unless asked for).
    public var mirrorOnMac = false
    /// Switch the headset's blue tracking lights off while playing.
    public var lightsOff = false
    /// Pause (and show black) while the headset is taken off; resume when it's back on.
    public var pauseWhenRemoved = false
    /// Switch them back on when playback ends (off when the app keeps them off all the time).
    public var restoreLights = true
    /// Play sound only on this output device (by UID). If it isn't connected, play without sound.
    /// nil: the Mac's current output, locked at start.
    public var soundDeviceUID: String?
    public var soundDeviceName: String?

    public init() {}
}

/// One playback in the headset: prepares the display, switches VR mode, renders, and restores
/// everything when it ends. A program can run any number of sessions, one at a time.
public final class PlaybackSession {
    public enum EndReason {
        case quit
        /// Double-tap on mic-mute: the headset screen is already off.
        case quickExit
        case failed(String)
    }

    /// Status lines for the terminal or the app's UI.
    public var onMessage: (String) -> Void = { print($0) }
    /// Called right after the picture is gone, before the (slower) display restore.
    public var onStopping: ((EndReason) -> Void)?
    /// Called when everything is restored.
    public var onEnded: ((EndReason) -> Void)?
    public private(set) var isRunning = false

    private let sourceSpec: PlaybackSource
    private let options: PlaybackOptions
    private let headset: Headset?
    private var window: PlayerWindow?
    private var renderer: Renderer?
    private var renderLoop: RenderLoop?
    private var video: VideoSource?
    private var capture: CaptureSource?
    private var mirrorWindow: MirrorWindow?
    private var mirrorLoop: MirrorLoop?
    /// Keeps the Mac and its displays awake (no sleep, no screen saver) while something plays.
    private var awake: NSObjectProtocol?
    /// Stops everything if a cable or audio device drops (see DisconnectWatch).
    private var watch: DisconnectWatch?
    private var headsetDisplay: CGDirectDisplayID?
    /// The device this session's sound is locked to (nil: muted or no sound).
    public private(set) var soundDeviceUID: String?
    /// Why the last quick exit happened (nil: the headset's double-tap).
    public private(set) var quickExitReason: String?
    private var settings = Settings.load()

    public init(source: PlaybackSource, options: PlaybackOptions, headset: Headset?) {
        self.sourceSpec = source
        self.options = options
        self.headset = headset
        // YouTube's high-resolution streams are VP9; macOS decodes it only when asked to.
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
    }

    /// Starts on the main thread (after the app has finished launching).
    public func start() throws {
        guard !isRunning else { return }
        guard let device = MTLCreateSystemDefaultDevice() else { throw SessionError("Metal is not available") }
        let isCapture: Bool
        if case .capture = sourceSpec { isCapture = true } else { isCapture = false }

        let screen = try chooseScreen()
        if !options.preview, let headset {
            headset.send(.vrMode(true))
            onMessage("headset in VR mode")
            if options.lightsOff {
                setLights(on: false)
                // Again a moment later in case the mode change resets them.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    if self?.isRunning == true, self?.lightsAreOff == true { self?.setLights(on: false) }
                }
            }
        }

        // Window: borderless on the headset display, or a normal window for previews.
        let frame = options.preview ? NSRect(x: 0, y: 0, width: 1280, height: 720) : screen.frame
        let window = PlayerWindow(contentRect: frame,
                                  styleMask: options.preview ? [.titled, .closable, .resizable, .miniaturizable] : [.borderless],
                                  backing: .buffered, defer: false)
        window.title = "PSVR"   // generic: video names stay out of window lists and screen-sharing pickers
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.takesInput = !isCapture
        if options.preview {
            window.center()
        } else {
            window.setFrame(screen.frame, display: false)
            window.pinnedFrame = screen.frame
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.isMovable = false
            window.animationBehavior = .none
            window.alphaValue = 0   // shown once it is confirmed on the headset display
            // The virtual screen never takes clicks: they belong to the app being shared.
            window.ignoresMouseEvents = isCapture
        }
        let view = PlayerView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        window.contentView = view
        self.window = window

        // Frames, and what the file says about its projection.
        var source: FrameSource?
        var projection = options.projection
        var layout = options.layout
        var swapEyes = options.swapEyes
        var meshes: [SphericalMesh] = []
        switch sourceSpec {
        case .file(let url, let downloaded):
            let video = VideoSource(url: url, device: device)
            // Lock the sound to one device. If that device disappears, the player goes silent instead of
            // following macOS to the speakers (tested: no fallback), so not even the moment before the
            // quick exit can reach a speaker. A chosen device that isn't connected means no sound at all
            // (locking to an absent device makes AVPlayer fail, so the audio is switched off instead).
            if let uid = options.soundDeviceUID {
                let name = options.soundDeviceName ?? "the chosen sound device"
                if AudioOutput.isConnected(uid) {
                    video.player.audioOutputDeviceUniqueID = uid
                    soundDeviceUID = uid
                    onMessage("sound: \(name)")
                } else {
                    video.disableAudio()
                    onMessage("no sound: \(name) isn't connected")
                }
            } else if let output = AudioOutput.currentDefault() {
                video.player.audioOutputDeviceUniqueID = output.uid
                soundDeviceUID = output.uid
                trace("sound locked to \(output.name)")
            }
            video.loops = options.loop
            self.video = video
            source = video
            let info = downloaded ?? SphericalMetadata.read(url)
            if let payload = info.meshPayload {
                do { meshes = try SphericalMesh.parse(projectionPayload: payload) } catch {
                    onMessage("warning: \(error); showing it as plain VR180")
                }
            }
            let name = FormatGuess.fromName(url.deletingPathExtension().lastPathComponent)
            let fileProjection = info.projection == .mesh && meshes.isEmpty ? .equirect180 : info.projection
            projection = projection ?? fileProjection ?? name.0
            layout = layout ?? info.layout ?? name.1
            swapEyes = swapEyes != info.rightEyeFirst
        case .capture(let filter):
            let capture = CaptureSource(filter: filter, device: device)
            capture.onStopped = { [weak self] error in
                self?.onMessage("screen sharing ended\(error.map { ": \($0.localizedDescription)" } ?? "")")
                self?.stop(.quit)
            }
            self.capture = capture
            source = capture
            projection = projection ?? .flat
            layout = layout ?? .mono
        case .testGrid:
            break
        }

        let renderer = try Renderer(device: device, pixelFormat: view.metalLayer.pixelFormat,
                                    tracker: headset?.tracker, source: source,
                                    projection: projection, layout: layout,
                                    distortion: options.lens ?? !options.preview,
                                    fovDegrees: options.fov ?? settings.fovDegrees,
                                    meshes: meshes)
        renderer.printsStats = options.stats
        renderer.update {
            $0.swapEyes = swapEyes
            $0.stereoSeparationDegrees = settings.stereoSeparationDegrees
            $0.flatScreenDegrees = settings.flatScreenDegrees ?? (isCapture ? 80 : 70)
        }
        renderer.onFormatResolved = { [weak self] p, l, w, h in
            DispatchQueue.main.async {
                self?.onMessage(isCapture
                    ? "sharing \(w)x\(h) on a virtual screen  (- / = size, L for side-by-side 3D)"
                    : "video \(w)x\(h): projection \(p.rawValue), layout \(l.rawValue)  (P / L keys to change)")
            }
        }
        self.renderer = renderer

        view.onKey = { [weak self] key in self?.handle(key) }
        view.onMouseLook = { [weak renderer] dx, dy in
            renderer?.update {
                $0.mouseYaw += dx * 0.005
                $0.mousePitch = max(-1.5, min(1.5, $0.mousePitch + dy * 0.005))
            }
        }

        headset?.onPlaybackGesture = { [weak self] gesture in
            switch gesture {
            case .seekForward: self?.handle(.right)
            case .seekBackward: self?.handle(.left)
            case .togglePlayPause: self?.handle(.space)
            default: break
            }
        }
        headset?.onQuickExit = { [weak self] in self?.stop(.quickExit) }
        if options.pauseWhenRemoved, !options.preview, let headset {
            headset.onWornChange = { [weak self] worn in self?.headsetWorn(worn) }
            // Started from the Mac before putting the headset on: wait for it (from the beginning).
            if headset.isWorn == false {
                offHold = true
                renderer.update { $0.blanked = true }
                onMessage("waiting for the headset to be put on")
            }
        }

        let renderLoop = RenderLoop(layer: view.metalLayer, renderer: renderer,
                                    refreshRate: Float(screen.maximumFramesPerSecond))
        self.renderLoop = renderLoop
        isRunning = true
        // Nobody touches the mouse or keyboard while watching in the headset; without this the Mac
        // would start the screen saver or sleep mid-video.
        awake = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Playing in the PSVR headset")

        // Optional preview on the Mac's own screen (never the headset's).
        if options.mirrorOnMac && !options.preview {
            let macScreen = NSScreen.screens.first { displayID($0) != displayID(screen) } ?? NSScreen.screens[0]
            renderer.enableMirror(width: 1280, height: 720)
            let mirror = MirrorWindow(on: macScreen, device: device, width: 1280, height: 720)
            mirror.orderFrontRegardless()
            let loop = MirrorLoop(layer: mirror.metalLayer, renderer: renderer)
            loop.start()
            mirrorWindow = mirror
            mirrorLoop = loop
            onMessage("preview on this Mac is on (for this session only)")
        }

        // Show it. The virtual screen leaves keyboard focus with the app being shared.
        if isCapture && !options.preview {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        }
        renderLoop.start()
        if !options.preview {
            if !isCapture { NSCursor.hide() }
            // Reveal only once the window is confirmed on the headset display; until then it stays
            // fully transparent (and is put back if macOS placed it elsewhere).
            revealWhenOnHeadset(window, attempts: 12)
        }

        if let video {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak video] in
                if let error = video?.error {
                    self?.onMessage("cannot play this file: \(error.localizedDescription)")
                    self?.onMessage("tip: convert with  ffmpeg -i input -c:v libx264 -crf 18 -c:a aac output.mp4")
                }
            }
            if offHold == nil { video.player.play() }
        }
        // Cables, displays and audio devices dropping mid-session: quick exit, rather than macOS moving the
        // player onto the Mac's screen and the sound onto its speakers.
        if !options.preview {
            renderer.requiredDisplay = headsetDisplay
            let watch = DisconnectWatch(displayID: headsetDisplay, window: window, headset: headset,
                                        soundDeviceUID: soundDeviceUID,
                                        stopOnOutputSwitch: options.soundDeviceUID == nil) { [weak self] reason in
                self?.quickExit(reason)
            }
            watch.start()
            self.watch = watch
        }

        if let capture {
            Task { @MainActor [weak self] in
                do { try await capture.start() } catch {
                    self?.onMessage("cannot share that: \(error.localizedDescription)")
                    self?.stop(.failed(error.localizedDescription))
                }
            }
        }
    }

    /// Ends the session: picture off first, then the headset and display are restored.
    /// - Parameter waitForRestore: block until the headset and display are restored (when the
    ///   process is about to exit); otherwise the slow restore steps run afterwards without blocking,
    ///   so hiding the picture reaches the screen immediately.
    public func stop(_ reason: EndReason = .quit, waitForRestore: Bool = false) {
        guard isRunning else { return }
        isRunning = false
        trace("stop(\(reason)) begins")
        watch?.stop()   // before restoring the display below, which would otherwise trigger it
        watch = nil
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil

        // 1. Picture and sound off, now.
        video?.stop()
        capture?.stop()
        renderLoop?.stop()
        mirrorLoop?.stop()
        mirrorWindow?.orderOut(nil)
        mirrorWindow?.close()
        window?.alphaValue = 0
        window?.orderOut(nil)
        window?.close()
        CATransaction.flush()   // push the hide to the window server right away
        trace("window hidden")
        NSCursor.unhide()
        headset?.onPlaybackGesture = nil
        headset?.onQuickExit = nil
        headset?.onWornChange = nil
        offHold = nil
        onStopping?(reason)

        // 2. Headset and display back to normal (the unit needs ~1 s to leave VR mode first).
        var isQuickExit = false
        if case .quickExit = reason { isQuickExit = true }
        if let headset, !options.preview, lightsAreOff, options.restoreLights, !isQuickExit {
            headset.sendNow(.lights(100))
            lightsAreOff = false
        }
        let restoreDisplay = headset != nil && !options.preview && (!options.keepVR || isQuickExit)
        if restoreDisplay { headset?.sendNow(.vrMode(false)) }

        let finish = { [self] in
            if restoreDisplay {
                PSVRDisplay.restoreCinematicRate()
                if !isQuickExit { onMessage("headset back in cinematic mode (display at 60 Hz)") }
            }
            window = nil
            mirrorWindow = nil
            mirrorLoop = nil
            renderer = nil
            renderLoop = nil
            video = nil
            capture = nil
            onEnded?(reason)
        }
        if waitForRestore {
            if restoreDisplay { Thread.sleep(forTimeInterval: 1) }
            finish()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + (restoreDisplay ? 1 : 0), execute: finish)
        }
    }

    /// A cable, display or audio device dropped: picture and sound off at once, headset off, then the
    /// usual quick-exit handling (terminal cleared / app quits).
    public func quickExit(_ reason: String) {
        guard isRunning else { return }
        trace("quick exit: \(reason)")
        quickExitReason = reason
        window?.alphaValue = 0
        window?.orderOut(nil)
        CATransaction.flush()
        video?.player.pause()
        headset?.sendNow(.headsetPower(false))
        headset?.sendNow(.vrMode(false))
        stop(.quickExit)
    }

    // MARK: Placement

    /// The display's position as AppKit reports it, if it agrees with CoreGraphics (which is
    /// authoritative); they disagree while a reconfiguration is still being processed.
    private func settledFrame(_ id: CGDirectDisplayID) -> (NSScreen, NSRect)? {
        guard CGDisplayIsOnline(id) != 0, let screen = NSScreen.screens.first(where: { displayID($0) == id }),
              let main = NSScreen.screens.first else { return nil }
        let cg = CGDisplayBounds(id)   // top-left origin
        let expected = NSRect(x: cg.minX, y: main.frame.maxY - cg.maxY, width: cg.width, height: cg.height)
        return screen.frame == expected ? (screen, expected) : nil
    }

    /// Waits (up to 8 s) until the display has kept the same, consistent position for 0.6 s.
    private func waitForStableScreen(_ id: CGDirectDisplayID) -> NSScreen? {
        let deadline = Date().addingTimeInterval(8)
        var last: NSRect?
        var stableSince = Date()
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            guard let (screen, frame) = settledFrame(id) else { last = nil; continue }
            if frame != last {
                last = frame
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 0.6 {
                trace("headset display settled at \(frame)")
                return screen
            }
        }
        return nil
    }

    private func revealWhenOnHeadset(_ window: PlayerWindow, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak window] in
            guard let self, let window, self.isRunning, let id = self.headsetDisplay else { return }
            let onHeadset = window.screen.map(displayID) == id && self.settledFrame(id).map { $0.1 == window.frame } == true
            if onHeadset {
                trace("window confirmed on the headset display, revealing")
                window.alphaValue = 1
            } else if attempts > 0, let (_, frame) = self.settledFrame(id) {
                trace("window not on the headset display yet (\(window.frame)), moving it")
                window.pinnedFrame = frame
                window.setFrame(frame, display: false)
                self.revealWhenOnHeadset(window, attempts: attempts - 1)
            } else if attempts > 0 {
                self.revealWhenOnHeadset(window, attempts: attempts - 1)
            } else {
                self.onMessage("the headset display didn't settle; stopping")
                self.stop(.failed("headset display not ready"))
            }
        }
    }

    // MARK: Lights

    /// Whether this session switched the tracking lights off (they come back on when it ends).
    public private(set) var lightsAreOff = false

    /// The headset's blue tracking lights, during playback.
    public func setLights(on: Bool) {
        guard let headset, !options.preview else { return }
        headset.send(.lights(on ? 100 : 0))
        lightsAreOff = !on
    }

    // MARK: Headset off

    /// Set while paused because the headset is off: whether to play again when it's back on.
    private var offHold: Bool?
    /// Headset taken off (false) or put back on (true), for the UI.
    public var onHeadsetWorn: ((Bool) -> Void)?

    private func headsetWorn(_ worn: Bool) {
        guard isRunning else { return }
        if !worn, offHold == nil {
            offHold = video.map { $0.player.rate != 0 } ?? false
            video?.player.pause()
            renderer?.update { $0.blanked = true }
            onMessage("headset off: paused")
            onHeadsetWorn?(false)
        } else if worn, let resume = offHold {
            offHold = nil
            if let video, resume {
                video.seek(by: -2)   // pick up a moment before where it stopped
                video.player.play()
            }
            renderer?.update { $0.blanked = false }
            onMessage(resume ? "headset on: playing" : "headset on")
            onHeadsetWorn?(true)
        }
    }

    // MARK: Keys

    public func handle(_ key: Key) {
        guard isRunning, let r = renderer else { return }
        switch key {
        case .esc, .char("q"): stop(.quit)
        case .space:
            guard let video else { break }
            if offHold != nil {
                // Manual override (e.g. watching with the headset held up to the face).
                offHold = nil
                r.update { $0.blanked = false }
                onHeadsetWorn?(true)
            }
            video.togglePlay()
            onMessage(video.player.rate == 0 ? "paused" : "playing")
        case .left, .right, .down, .up:
            guard let video else { break }
            let seconds: Double = key.isArrow(.left) ? -10 : key.isArrow(.right) ? 10 : key.isArrow(.down) ? -60 : 60
            video.seek(by: seconds)
            let t = max(0, video.player.currentTime().seconds + seconds)
            onMessage(String(format: "%+.0f s → %d:%02d", seconds, Int(t) / 60, Int(t) % 60))
        case .char("r"):
            r.tracker?.recenterYaw()
            r.update {
                $0.mouseYaw = 0
                $0.mousePitch = 0
            }
            onMessage("recentered")
        case .char("p"):
            let projection = r.update {
                $0.projection = $0.projection.next
                if $0.projection == .mesh && !r.hasMesh { $0.projection = $0.projection.next }
                return $0.projection.rawValue
            }
            onMessage("projection \(projection)")
        case .char("l"):
            onMessage("layout \(r.update { $0.layout = $0.layout.next; return $0.layout.rawValue })")
        case .char("s"):
            onMessage("eyes \(r.update { $0.swapEyes.toggle(); return $0.swapEyes } ? "swapped" : "normal")")
        case .char("d"):
            onMessage("lens correction \(r.update { $0.distortion.toggle(); return $0.distortion } ? "on" : "off")")
        case .char("["), .char("]"):
            let fov = r.update { $0.fovDegrees += key.isChar("]") ? 1 : -1; return $0.fovDegrees }
            onMessage("field of view \(Int(fov))° (saved)")
            saveTuning(r.current)
        case .char(","), .char("."):
            let sep = r.update { $0.stereoSeparationDegrees += key.isChar(".") ? 0.1 : -0.1; return $0.stereoSeparationDegrees }
            onMessage(String(format: "3D separation %+.1f° (saved)", sep))
            saveTuning(r.current)
        case .char("-"), .char("="):
            let size = r.update {
                $0.flatScreenDegrees = max(20, min(150, $0.flatScreenDegrees + (key.isChar("=") ? 5 : -5)))
                return $0.flatScreenDegrees
            }
            onMessage("screen \(Int(size))° wide (saved)")
            saveTuning(r.current)
        default: break
        }
    }

    private func saveTuning(_ state: ViewState) {
        Settings.update {
            $0.fovDegrees = state.fovDegrees
            $0.stereoSeparationDegrees = state.stereoSeparationDegrees
            $0.flatScreenDegrees = state.flatScreenDegrees
        }
    }

    // MARK: Display

    private func chooseScreen() throws -> NSScreen {
        if options.preview { return NSScreen.main ?? NSScreen.screens[0] }
        if let n = options.screenIndex {
            guard NSScreen.screens.indices.contains(n) else { throw SessionError("no screen \(n)") }
            headsetDisplay = displayID(NSScreen.screens[n])
            return NSScreen.screens[n]
        }
        // VR mode only shows an image at 90/120 Hz RGB, and the HDMI link must come up in cinematic mode.
        let id = try PSVRDisplay.prepare(hz: options.hz, beforeRelink: { [headset] in
            headset?.send(.vrMode(false))
            Thread.sleep(forTimeInterval: 3)   // the unit needs a moment to leave VR mode
        }, log: { [weak self] in self?.onMessage($0) })
        // The 120 Hz setup can make the display reconnect; wait until it has settled, or the window
        // could be placed using a stale position (on another screen).
        guard let s = waitForStableScreen(id) else { throw PSVRDisplay.SetupError.notConnected }
        headsetDisplay = id
        if let mode = CGDisplayCopyDisplayMode(id) {
            onMessage("using \(s.localizedName): \(mode.pixelWidth)x\(mode.pixelHeight) @ \(Int(mode.refreshRate.rounded())) Hz")
        }
        return s
    }
}

/// Timing trace for diagnosing disconnects: set PSVR_TRACE=1 (goes to stderr, with wall-clock time).
func trace(_ message: String) {
    guard ProcessInfo.processInfo.environment["PSVR_TRACE"] != nil else { return }
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    FileHandle.standardError.write("[\(f.string(from: Date()))] \(message)\n".data(using: .utf8)!)
}

public struct SessionError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}
