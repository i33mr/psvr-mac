import Foundation
import os

/// Cancels a running download (kills the tool it is waiting for).
public final class DownloadToken {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false

    public init() {}

    public func cancel() {
        let running: pid_t = lock.withLock {
            cancelled = true
            return pid
        }
        guard running > 0 else { return }
        kill(running, SIGTERM)
        // Safety net: force it if it hasn't exited after 2 s.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.lock.withLock({ self.pid == running }) else { return }
            kill(running, SIGKILL)
        }
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Records the running tool; false if already cancelled (the caller then stops it).
    func started(_ p: pid_t) -> Bool { lock.withLock { pid = p; return !cancelled } }
    func finished() { lock.withLock { pid = 0 } }
}

/// Fetches a web video (YouTube and the other sites yt-dlp supports) into a cache folder as an MP4
/// the player can open. Picks the best stream this Mac decodes in hardware: VP9, HEVC or H.264,
/// never AV1 (no hardware decoder before M3), plus the original-language audio.
public enum Downloader {
    public struct Result {
        public let file: URL
        public let info: SphericalInfo
        /// Delete when done (nil when the video was saved with --keep).
        public let cacheDir: URL?
    }

    enum Failure: Error, CustomStringConvertible {
        case missingTool(String)
        case toolFailed(String)
        /// A reason the site gave, already in plain words.
        case site(String)
        case nothingPlayable
        case live
        case cancelled

        var description: String {
            switch self {
            case .missingTool(let t): return "\(t) not found. Install it with: brew install \(t)"
            case .toolFailed(let what):
                return "\(what)\nIf YouTube changed something, updating usually fixes it: brew upgrade yt-dlp"
            case .site(let why): return why
            case .nothingPlayable: return "no format of this video can be decoded on this Mac (only AV1 is offered)"
            case .live: return "live streams are not supported"
            case .cancelled: return "cancelled"
            }
        }

        /// Worth retrying with a fresh link (YouTube cutting a download off), unlike a block or a private video.
        var isRetryable: Bool {
            if case .toolFailed = self { return true }
            return false
        }

        /// Turns yt-dlp's last error line into a plain explanation where the cause is known.
        static func from(tool: String, exitCode: Int32, errorLine: String?) -> Failure {
            let line = errorLine ?? ""
            let lower = line.lowercased()
            if lower.contains("confirm you") && lower.contains("not a bot") {
                return .site("YouTube is blocking downloads from this internet connection for now (its bot check). "
                             + "This usually lifts within hours; another network (e.g. a phone hotspot) works meanwhile.")
            }
            if lower.contains("private video") { return .site("This video is private.") }
            if lower.contains("unavailable") || lower.contains("has been removed") || lower.contains("does not exist") {
                return .site("This video is unavailable (removed, blocked in your country, or the link is wrong).")
            }
            if lower.contains("sign in to confirm your age") { return .site("YouTube requires signing in to watch this video (age check).") }
            if lower.contains("unsupported url") { return .site("This site or link isn't supported by yt-dlp.") }
            if !line.isEmpty {
                let detail = line.replacingOccurrences(of: "ERROR: ", with: "")
                return .toolFailed("\(tool) failed: \(detail)")
            }
            return .toolFailed("\(tool) failed (exit \(exitCode))")
        }
    }

    public static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("psvr-mac/downloads")

    public static func isLink(_ s: String) -> Bool { s.hasPrefix("https://") || s.hasPrefix("http://") }

    /// `log` gets status lines; with `progress`, download progress (0...1) is reported there instead
    /// of yt-dlp drawing its own progress bar in the terminal.
    /// Video IDs being downloaded right now (in this process): their cache folders must survive.
    private static let active = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    public static func fetch(_ link: String, maxHeight: Int?, keepIn saveFolder: URL?,
                             log: @escaping (String) -> Void = { print($0) },
                             progress: ((Double) -> Void)? = nil,
                             token: DownloadToken? = nil) throws -> Result {
        guard let ytdlp = tool("yt-dlp") else { throw Failure.missingTool("yt-dlp") }
        guard let ffmpeg = tool("ffmpeg") else { throw Failure.missingTool("ffmpeg") }
        // YouTube needs a JavaScript runtime for some formats; Node works if installed.
        var common = ["--no-playlist", "--no-warnings"]
        if let node = tool("node") { common += ["--js-runtimes", "node:\(node)"] }

        log("looking up the video…")
        let json = try run(ytdlp, common + ["-J", link], capture: true, token: token)
        guard let info = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Failure.toolFailed("yt-dlp returned no video information")
        }
        if info["is_live"] as? Bool == true { throw Failure.live }
        let formats = (info["formats"] as? [[String: Any]] ?? []).map(Format.init)
        let title = info["title"] as? String ?? "video"
        let id = (info["id"] as? String ?? UUID().uuidString).filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }

        let (video, audio) = try choose(formats, maxHeight: maxHeight)
        let bytes = (video.bytes ?? 0) + (audio?.bytes ?? 0)
        log("\"\(title)\"")
        log("  \(video.width)x\(video.height) \(video.fps.map { "\(Int($0.rounded())) fps " } ?? "")\(video.codecName)"
              + (bytes > 0 ? String(format: ", about %.1f GB", Double(bytes) / 1e9) : ""))

        // Leftovers of other videos are from interrupted runs, unless they are downloading right now.
        // A leftover of this same video is kept, so yt-dlp can reuse or resume it.
        let dir = cacheRoot.appendingPathComponent(id)
        active.withLock { _ = $0.insert(id) }
        defer { active.withLock { _ = $0.remove(id) } }
        let busy = active.withLock { $0 }
        for old in (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != id && !busy.contains(old.lastPathComponent) {
            try? FileManager.default.removeItem(at: old)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        log("downloading video…")
        let videoFile = try download(ytdlp, common, link, format: video.id, to: dir, name: "video", log: log,
                                     progress: progress.map { p in { p($0 * (audio == nil ? 1 : 0.95)) } }, token: token)
        var audioFile: URL?
        if let audio {
            log("downloading audio…")
            audioFile = try download(ytdlp, common, link, format: audio.id, to: dir, name: "audio", log: log,
                                     progress: progress.map { p in { p(0.95 + $0 * 0.05) } }, token: token)
        }

        let spherical = SphericalMetadata.read(videoFile)
        log("preparing…")
        let output = dir.appendingPathComponent("play.mp4")
        var args = ["-nostdin", "-v", "error", "-y", "-i", videoFile.path]
        if let audioFile { args += ["-i", audioFile.path] }
        args += ["-map", "0:v:0", "-map", audioFile == nil ? "0:a:0?" : "1:a:0", "-c:v", "copy"]
        // AVFoundation plays AAC; YouTube's alternative is Opus.
        args += ["-c:a", (audio ?? video).audioIsAAC ? "copy" : "aac", "-strict", "unofficial", "-f", "mp4", output.path]
        _ = try run(ffmpeg, args, capture: false, token: token)
        try? FileManager.default.removeItem(at: videoFile)
        if let audioFile { try? FileManager.default.removeItem(at: audioFile) }

        guard let saveFolder else { return Result(file: output, info: spherical, cacheDir: dir) }
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let saved = saveFolder.appendingPathComponent(fileName(title)).appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: saved)
        try FileManager.default.moveItem(at: output, to: saved)
        if let mesh = spherical.meshPayload { try mesh.write(to: SphericalInfo.meshSidecar(for: saved)) }
        try? FileManager.default.removeItem(at: dir)
        log("saved to \(saved.path)")
        return Result(file: saved, info: spherical, cacheDir: nil)
    }

    // MARK: Format choice

    struct Format {
        let id: String
        let vcodec: String
        let acodec: String
        let width: Int
        let height: Int
        let fps: Double?
        let bytes: Int?
        let https: Bool
        let languagePreference: Int
        let abr: Double

        init(_ f: [String: Any]) {
            id = f["format_id"] as? String ?? ""
            vcodec = (f["vcodec"] as? String ?? "none").lowercased()
            acodec = (f["acodec"] as? String ?? "none").lowercased()
            width = f["width"] as? Int ?? 0
            height = f["height"] as? Int ?? 0
            fps = f["fps"] as? Double
            bytes = f["filesize"] as? Int ?? f["filesize_approx"] as? Int
            https = (f["protocol"] as? String ?? "").hasPrefix("http")
            languagePreference = f["language_preference"] as? Int ?? 0
            abr = f["abr"] as? Double ?? f["tbr"] as? Double ?? 0
        }

        var hasVideo: Bool { vcodec != "none" && !vcodec.isEmpty }
        var hasAudio: Bool { acodec != "none" && !acodec.isEmpty }
        var audioIsAAC: Bool { acodec.hasPrefix("mp4a") || acodec == "aac" }

        /// Codecs this Mac decodes in hardware (VP9 via the supplemental decoder). nil = not playable.
        var codecRank: Int? {
            if vcodec.hasPrefix("vp09") || vcodec == "vp9" { return 2 }
            if vcodec.hasPrefix("hev1") || vcodec.hasPrefix("hvc1") || vcodec.hasPrefix("hevc") { return 2 }
            if vcodec.hasPrefix("avc1") || vcodec == "h264" { return 1 }
            return nil
        }

        var codecName: String {
            if vcodec.hasPrefix("vp09") || vcodec == "vp9" { return "VP9" }
            if codecRank == 2 { return "HEVC" }
            return "H.264"
        }
    }

    static func choose(_ formats: [Format], maxHeight: Int?) throws -> (video: Format, audio: Format?) {
        let candidates = formats.filter { $0.hasVideo && $0.codecRank != nil && $0.height <= (maxHeight ?? .max) }
        func score(_ f: Format) -> (Int, Int, Int, Int) {
            (f.height, Int((f.fps ?? 30).rounded()), f.https ? 1 : 0, f.codecRank ?? 0)
        }
        guard let best = candidates.max(by: { score($0) < score($1) }) else { throw Failure.nothingPlayable }
        // A combined stream (video + audio) of the same quality saves a second download.
        if !best.hasAudio, let combined = candidates.filter(\.hasAudio).max(by: { score($0) < score($1) }),
           score(combined) >= score(best) {
            return (combined, nil)
        }
        guard !best.hasAudio else { return (best, nil) }
        let audio = formats.filter { $0.hasAudio && !$0.hasVideo }.max {
            ($0.languagePreference, $0.audioIsAAC ? 1 : 0, $0.abr) < ($1.languagePreference, $1.audioIsAAC ? 1 : 0, $1.abr)
        }
        return (best, audio)
    }

    // MARK: Helpers

    private static func download(_ ytdlp: String, _ common: [String], _ link: String,
                                 format: String, to dir: URL, name: String,
                                 log: (String) -> Void, progress: ((Double) -> Void)?,
                                 token: DownloadToken?) throws -> URL {
        // With a progress handler, yt-dlp prints one parseable line per update instead of a bar.
        let progressArgs = progress == nil ? ["--progress"]
            : ["--progress", "--newline", "--progress-template", "download:%(progress.downloaded_bytes)s/%(progress.total_bytes,progress.total_bytes_estimate)s"]
        let onLine: ((String) -> Void)? = progress.map { report in
            { line in
                let parts = line.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2, parts[1] > 0 { report(min(parts[0] / parts[1], 1)) }
            }
        }
        // YouTube sometimes revokes a download link midway (HTTP 403), mostly because yt-dlp has no
        // "PO token" to prove it is a real player. Each attempt gets a fresh link and resumes the
        // partial file, so retrying loses nothing.
        let attempts = 5
        for attempt in 1...attempts {
            do {
                // Below 2 MB/s YouTube is throttling this link (normal is 20+ MB/s): get a fresh one.
                try run(ytdlp, common + ["-q", "--throttled-rate", "2M", "-f", format] + progressArgs
                                + ["-o", dir.appendingPathComponent("\(name).%(ext)s").path, link],
                        capture: false, onLine: onLine, token: token)
                break
            } catch let failure as Failure where attempt < attempts && failure.isRetryable {
                log("YouTube interrupted the download; resuming with a fresh link (attempt \(attempt + 1) of \(attempts))…")
                Thread.sleep(forTimeInterval: Double(attempt))
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { $0.deletingPathExtension().lastPathComponent == name && $0.pathExtension != "part" }) else {
            throw Failure.toolFailed("yt-dlp did not produce the \(name) file")
        }
        return file
    }

    /// Runs a tool; output goes to the terminal unless captured. Spawned directly (not with
    /// Foundation's Process, which starts a new process group): a tool in a background group gets
    /// stopped by the system as soon as it reads from or writes to the terminal. Input is
    /// /dev/null, and Ctrl-C reaches the tool too.
    @discardableResult
    private static func run(_ path: String, _ args: [String], capture: Bool,
                            onLine: ((String) -> Void)? = nil, token: DownloadToken? = nil) throws -> Data {
        if token?.isCancelled == true { throw Failure.cancelled }
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        let captureOutput = capture || onLine != nil
        var pipeFDs: [Int32] = [-1, -1]
        if captureOutput {
            guard pipe(&pipeFDs) == 0 else { throw Failure.toolFailed("could not create a pipe") }
            posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO)
            posix_spawn_file_actions_addclose(&actions, pipeFDs[0])
            posix_spawn_file_actions_addclose(&actions, pipeFDs[1])
        }

        // Error output: passed through to our stderr live (progress bars, messages) and remembered,
        // so a failure can say why.
        var errFDs: [Int32] = [-1, -1]
        guard pipe(&errFDs) == 0 else { throw Failure.toolFailed("could not create a pipe") }
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, errFDs[0])
        posix_spawn_file_actions_addclose(&actions, errFDs[1])

        // Children inherit ignored signals; the player and app ignore SIGINT/SIGTERM/SIGHUP (they handle
        // them to restore the headset), so reset those to normal or the tool could never be stopped.
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attributes, &noMask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        if captureOutput { close(pipeFDs[1]) }
        close(errFDs[1])
        guard spawned == 0 else {
            if captureOutput { close(pipeFDs[0]) }
            close(errFDs[0])
            throw Failure.toolFailed("could not start \(path) (error \(spawned))")
        }

        if let token, !token.started(pid) { kill(pid, SIGTERM) }
        let errors = ErrorTail()
        let errorsDone = DispatchSemaphore(value: 0)
        let errReader = FileHandle(fileDescriptor: errFDs[0], closeOnDealloc: true)
        Thread {
            while case let chunk = errReader.availableData, !chunk.isEmpty {
                FileHandle.standardError.write(chunk)
                errors.append(chunk)
            }
            errorsDone.signal()
        }.start()

        var output = Data()
        if captureOutput {
            let reader = FileHandle(fileDescriptor: pipeFDs[0], closeOnDealloc: true)
            if let onLine {
                // Stream lines as they arrive (progress updates).
                var pending = Data()
                while case let chunk = reader.availableData, !chunk.isEmpty {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex...newline)
                        onLine(line)
                    }
                }
            } else {
                output = reader.readDataToEndOfFile()
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        errorsDone.wait()
        token?.finished()
        if token?.isCancelled == true { throw Failure.cancelled }
        let exitCode = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        guard exitCode == 0 else {
            throw Failure.from(tool: URL(fileURLWithPath: path).lastPathComponent, exitCode: exitCode,
                               errorLine: errors.lastErrorLine)
        }
        return output
    }

    /// The end of a tool's error output (enough to find its last ERROR line).
    private final class ErrorTail {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.withLock {
                data.append(chunk)
                if data.count > 16_384 { data.removeFirst(data.count - 16_384) }
            }
        }

        var lastErrorLine: String? {
            let text = lock.withLock { String(decoding: data, as: UTF8.self) }
            return text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .last { $0.contains("ERROR") || $0.lowercased().contains("error:") }
                .map { String($0).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// Finds a command-line tool. Apps opened from Finder get a minimal PATH, so the usual install
    /// places are searched too, including Node.js installed with nvm.
    static func tool(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func fileName(_ title: String) -> String {
        let cleaned = title.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }
        return String(String(cleaned).prefix(120)).trimmingCharacters(in: .whitespaces)
    }
}
