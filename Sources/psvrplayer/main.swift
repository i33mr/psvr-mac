import AppKit
import PSVRKit
import PSVRPlayerCore
import ScreenCaptureKit

let usage = """
usage: psvrplayer [options] <video file>
       psvrplayer [options] "<YouTube or other video link>"
       psvrplayer [options] --share                 (pick a window or screen for a virtual screen)
       psvrplayer [options] --share-window <name>   (share the window of that app / title)
       psvrplayer [options] --test
       psvrplayer --download-only [--to <category>] <link> [<link> …]

Plays 360/180/flat, mono/stereo videos on a PSVR (v1) with head tracking, or shows a Mac window
on a virtual screen. Format comes from the file's VR metadata, else its name ("_360_TB",
"_180_LR") and shape. Links are downloaded with yt-dlp first and deleted afterwards.

options:
  --projection 360|180|flat   override the projection
  --layout mono|sbs|tb        override the stereo layout (sbs = left/right, tb = top/bottom)
  --swap-eyes                 swap left/right eye images
  --loop                      repeat the video until you quit
  --keep                      links: save the download to the library (default ~/Movies/psvr-samples)
  --download-only             links: just add them to the library (one after another), don't play
  --to <category>             with --keep / --download-only: save into this category (a sub-folder)
  --max-height <pixels>       links: limit the download resolution (e.g. 2160)
  --stats                     print frame pacing once a second (diagnostics)
  --fov <deg>                 per-eye horizontal field of view (default: saved setting, else 85)
  --screen <n>                use screen number n instead of the PSVR display
  --hz 120|90                 PSVR refresh rate in VR mode (default 120)
  --lens on|off               force lens correction (default: on in the headset, off with --window)
  --window                    play in a window on the Mac screen instead of the headset (mouse look)
  --mirror                    ALSO show what the headset shows in a small window on this Mac
  --lights-off                switch the headset's blue tracking lights off while playing
  --pause-when-off            pause and go black while the headset is taken off; resume when it's back on
  --sound <name>              play sound only on this output (e.g. AirPods); none if it isn't connected
  --no-headset                do not talk to the PSVR over USB
  --keep-vr                   stay in VR mode on exit (default: back to cinematic)
  --test                      no video: show a calibration grid

headset remote:  mic-mute = recenter          double-tap mic-mute = quick exit
                 vol+ / vol- = seek 10 s      hold vol+ or vol- = play/pause
                 (quick exit: headset screen off, playback stopped, this terminal cleared, quit)

keys:  space play/pause   ←/→ seek 10 s   ↓/↑ seek 60 s   R recenter
       P projection   L layout   S swap eyes   D lens correction   - = screen size
       [ ] field of view   , . 3D separation   (saved to ~/.config/psvr-mac/settings.json)
       mouse drag look around   Esc/Q quit
       (sharing a window: keys go to the shared app; use the terminal and the headset remote)
"""

// MARK: - Arguments

struct Options {
    var file: URL?
    var links: [String] = []
    var downloadOnly = false
    var category: String?
    var share = false
    var shareWindow: String?
    var keep = false
    var maxHeight: Int?
    var test = false
    var headset = true
    var playback = PlaybackOptions()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func value(_ flag: String) -> String {
        guard !args.isEmpty else { fail("\(flag) needs a value") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-h", "--help": print(usage); exit(0)
        case "--projection":
            guard let p = Projection(rawValue: value(a)), p != .mesh else { fail("--projection must be 360, 180 or flat") }
            o.playback.projection = p
        case "--layout":
            guard let l = StereoLayout(rawValue: value(a)) else { fail("--layout must be mono, sbs or tb") }
            o.playback.layout = l
        case "--swap-eyes": o.playback.swapEyes = true
        case "--loop": o.playback.loop = true
        case "--keep": o.keep = true
        case "--download-only": o.downloadOnly = true
        case "--to": o.category = value(a)
        case "--max-height":
            guard let h = Int(value(a)) else { fail("--max-height needs a number of pixels") }
            o.maxHeight = h
        case "--stats": o.playback.stats = true
        case "--fov":
            guard let fov = Float(value(a)) else { fail("--fov needs a number of degrees") }
            o.playback.fov = fov
        case "--screen": o.playback.screenIndex = Int(value(a))
        case "--hz":
            guard let hz = Double(value(a)), hz == 90 || hz == 120 else { fail("--hz must be 90 or 120 (VR mode stays black at 60 Hz)") }
            o.playback.hz = hz
        case "--window": o.playback.preview = true
        case "--mirror": o.playback.mirrorOnMac = true
        case "--lights-off": o.playback.lightsOff = true
        case "--pause-when-off": o.playback.pauseWhenRemoved = true
        case "--sound":
            let name = value(a)
            let match = AudioOutput.devices().first { $0.name.localizedCaseInsensitiveContains(name) }
            // No match: a device ID that can't exist, so the session plays without sound.
            o.playback.soundDeviceUID = match?.uid ?? "not-connected:\(name)"
            o.playback.soundDeviceName = match?.name ?? name
        case "--lens":
            switch value(a) {
            case "on": o.playback.lens = true
            case "off": o.playback.lens = false
            default: fail("--lens must be on or off")
            }
        case "--no-headset": o.headset = false
        case "--keep-vr": o.playback.keepVR = true
        case "--test": o.test = true
        case "--share": o.share = true
        case "--share-window": o.shareWindow = value(a)
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)\n\n\(usage)") }
            if Downloader.isLink(a) {
                o.links.append(a)
            } else {
                o.file = URL(fileURLWithPath: (a as NSString).expandingTildeInPath)
            }
        }
    }
    if o.file == nil && o.links.isEmpty && !o.test && !o.share && o.shareWindow == nil { print(usage); exit(1) }
    if o.downloadOnly && o.links.isEmpty { fail("--download-only needs at least one link") }
    if !o.downloadOnly && o.links.count > 1 { fail("play one link at a time, or add several with --download-only") }
    if let f = o.file, !FileManager.default.fileExists(atPath: f.path) { fail("no such file: \(f.path)") }
    return o
}

// MARK: - Terminal keys

/// Keys typed in the launching terminal also control playback, so the player works even when
/// macOS leaves the terminal focused (you can't see which window has focus with the headset on).
enum TerminalKeys {
    private static var original = termios()

    static func start(_ handler: @escaping (Key) -> Void) {
        guard isatty(STDIN_FILENO) != 0, tcgetattr(STDIN_FILENO, &original) == 0 else { return }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        atexit { tcsetattr(STDIN_FILENO, TCSANOW, &TerminalKeys.original) }

        Thread {
            var buffer = [UInt8](repeating: 0, count: 16)
            while true {
                let n = read(STDIN_FILENO, &buffer, buffer.count)
                if n <= 0 { return }
                for key in parse(Array(buffer[0..<n])) {
                    DispatchQueue.main.async { handler(key) }
                }
            }
        }.start()
    }

    private static func parse(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x1B, i + 2 < bytes.count, bytes[i + 1] == UInt8(ascii: "[") {
                switch bytes[i + 2] {
                case UInt8(ascii: "A"): keys.append(.up)
                case UInt8(ascii: "B"): keys.append(.down)
                case UInt8(ascii: "C"): keys.append(.right)
                case UInt8(ascii: "D"): keys.append(.left)
                default: break
                }
                i += 3
                continue
            }
            switch bytes[i] {
            case 0x1B: keys.append(.esc)
            case 0x20: keys.append(.space)
            default: keys.append(.char(Character(Unicode.Scalar(bytes[i])).lowercased().first!))
            }
            i += 1
        }
        return keys
    }
}

// MARK: - Run

setvbuf(stdout, nil, _IOLBF, 0)
let options = parseOptions()

let library = Settings.libraryFolder
let saveTo = options.category.map { library.appendingPathComponent($0) } ?? library

// Adding links to the library without playing.
if options.downloadOnly {
    var failed = 0
    for (i, link) in options.links.enumerated() {
        print("[\(i + 1)/\(options.links.count)] \(link)")
        do {
            _ = try Downloader.fetch(link, maxHeight: options.maxHeight, keepIn: saveTo)
        } catch {
            failed += 1
            print("  could not add it: \(error)")
        }
    }
    print(failed == 0 ? "done: \(options.links.count) added to \(saveTo.path)"
                      : "done: \(options.links.count - failed) added, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

// Links are downloaded first, before the headset switches to VR mode.
var downloadCache: URL?
var source: PlaybackSource = .testGrid
if let link = options.links.first {
    do {
        let saveFolder = options.keep ? saveTo : nil
        let result = try Downloader.fetch(link, maxHeight: options.maxHeight, keepIn: saveFolder)
        downloadCache = result.cacheDir
        source = .file(result.file, info: result.info)
    } catch {
        fail("\(error)")
    }
} else if let file = options.file {
    source = .file(file)
}

/// Deletes a link's download (not one saved with --keep).
func removeDownload() {
    if let downloadCache { try? FileManager.default.removeItem(at: downloadCache) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

var headset: Headset?
if options.headset {
    let h = Headset()
    if h.start() {
        headset = h
        print("PSVR connected. Leave the headset still until \"tracking: gyro bias calibrated\" appears.")
    } else {
        print("warning: PSVR not found on USB; continuing without head tracking (mouse look only)")
    }
}

var session: PlaybackSession?

func run(_ source: PlaybackSource) {
    let s = PlaybackSession(source: source, options: options.playback, headset: headset)
    s.onStopping = { reason in
        if case .quickExit = reason {
            if isatty(STDOUT_FILENO) != 0 {
                // Leave a clean terminal: screen and scrollback (the launch command names the video).
                print("\u{1B}[H\u{1B}[2J\u{1B}[3J", terminator: "")
            }
            print("stopped" + (s.quickExitReason.map { ": \($0)" } ?? ""))
        }
    }
    s.onEnded = { reason in
        removeDownload()
        if case .failed = reason { exit(1) }
        exit(0)
    }
    session = s
    do {
        try s.start()
    } catch {
        removeDownload()
        fail("\(error)")
    }
    TerminalKeys.start { key in session?.handle(key) }
    print("ready. Keys work in this terminal\(options.share || options.shareWindow != nil ? "" : " or the player window"). Esc or Q to quit.")
}

// Ctrl-C / kill: leave the headset in cinematic mode too.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        if let session, session.isRunning { session.stop(.quit) } else { removeDownload(); exit(0) }
    }
    source.resume()
    signalSources.append(source)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onLaunched: (() -> Void)?

    // Windows are shown only after launch: AppKit repositions windows that exist during launch.
    func applicationDidFinishLaunching(_ notification: Notification) { onLaunched?() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        session?.stop(.quit, waitForRestore: true)
        removeDownload()
    }
}
let delegate = AppDelegate()
app.delegate = delegate

delegate.onLaunched = {
    if options.share {
        print("choose a window or screen to share…")
        MainActor.assumeIsolated {
            CaptureTarget.pick { filter in
                guard let filter else { print("nothing chosen"); exit(0) }
                run(.capture(filter))
            }
        }
    } else if let name = options.shareWindow {
        Task { @MainActor in
            do {
                guard let filter = try await CaptureTarget.window(named: name) else {
                    fail("no on-screen window matches \"\(name)\"")
                }
                run(.capture(filter))
            } catch {
                fail("cannot list windows (\(error.localizedDescription)). Allow Screen Recording for your terminal in "
                     + "System Settings > Privacy & Security, or use --share to pick with the system picker.")
            }
        }
    } else {
        run(source)
    }
}
app.run()
