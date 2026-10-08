import AppKit
import PSVRKit
import PSVRPlayerCore
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Which part of the library is shown.
enum CategoryTab: Hashable {
    case all
    /// Videos directly in the library folder (not in any category).
    case unsorted
    case named(String)
}

@MainActor
final class PlayerModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double?)
        case starting
        case playing(sharing: Bool)
    }

    @Published var phase: Phase = .idle
    @Published var headsetConnected = false
    @Published var status = ""
    @Published var link = ""
    @Published var saveDownloads = false
    /// Show the headset view on this Mac too. Confirmed when switched on, applies to the next
    /// playback only, and switches itself off when that playback ends.
    @Published var previewOnMac = false
    /// Headset tracking lights off while the app is open (remembered; on by default). Changing it
    /// applies immediately; quitting the app switches them back on.
    @Published var lightsOff: Bool = {
        UserDefaults.standard.register(defaults: ["lightsOffWhileOpen": true])
        return UserDefaults.standard.bool(forKey: "lightsOffWhileOpen")
    }() {
        didSet {
            UserDefaults.standard.set(lightsOff, forKey: "lightsOffWhileOpen")
            applyLights()
        }
    }

    /// Pause and go black while the headset is taken off (remembered; on by default). Applies from
    /// the next video.
    @Published var pauseWhenRemoved: Bool = {
        UserDefaults.standard.register(defaults: ["pauseWhenRemoved": true])
        return UserDefaults.standard.bool(forKey: "pauseWhenRemoved")
    }() {
        didSet { UserDefaults.standard.set(pauseWhenRemoved, forKey: "pauseWhenRemoved") }
    }
    /// Paused because the headset is off (shown on the playing screen).
    @Published private(set) var headsetOff = false

    /// Sends the current lights choice to the headset (if connected).
    private func applyLights() {
        guard headsetConnected else { return }
        if let session, session.isRunning {
            session.setLights(on: !lightsOff)
        } else {
            headset.send(.lights(lightsOff ? 0 : 100))
        }
    }

    // Sound: a chosen device (remembered), or nil for the Mac's current output.
    @Published private(set) var outputDevices: [AudioOutput.Device] = AudioOutput.devices()
    @Published var soundDeviceUID: String? = UserDefaults.standard.string(forKey: "soundDeviceUID") {
        didSet {
            soundDeviceName = soundDeviceUID.flatMap { uid in outputDevices.first { $0.uid == uid }?.name } ?? soundDeviceName
            UserDefaults.standard.set(soundDeviceUID, forKey: "soundDeviceUID")
            UserDefaults.standard.set(soundDeviceUID == nil ? nil : soundDeviceName, forKey: "soundDeviceName")
        }
    }
    private(set) var soundDeviceName: String? = UserDefaults.standard.string(forKey: "soundDeviceName")
    /// Shown while playing, e.g. "No sound: AirPods isn't connected".
    @Published private(set) var soundNote: String?
    private var deviceObserver: AnyObject?

    var soundDeviceConnected: Bool { soundDeviceUID.map { uid in outputDevices.contains { $0.uid == uid } } ?? true }

    // Library
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var categories: [String] = []
    @Published var tab: CategoryTab = .all
    @Published var search = ""
    @Published var kindFilter: KindFilter = .all

    let queue = DownloadQueue()
    static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]

    private let headset = Headset()
    private var session: PlaybackSession?
    /// While playing, keys pressed in any of the app's windows (this one, Controls, Settings) go to the
    /// player too, so clicking a button here doesn't take the keyboard away from it.
    private var keyMonitor: Any?
    private var downloadCache: URL?
    private var store = LibraryStore()

    init() {
        headset.onMessage = { [weak self] in self?.status = $0 }
        headsetConnected = headset.start()
        applyLights()
        status = headsetConnected ? "PSVR connected" : "PSVR not found on USB. Check the processor unit's power and USB cable."
        // The headset can be plugged in later; USB hot-plug is handled by the driver.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.headsetConnected != self.headset.isConnected {
                    self.headsetConnected = self.headset.isConnected
                    if self.headsetConnected { self.applyLights() }   // plugged in later
                }
            }
        }
        queue.onAdded = { [weak self] in self?.refreshLibrary() }
        deviceObserver = AudioOutput.observeDevices { [weak self] in self?.outputDevices = AudioOutput.devices() }
        refreshLibrary()
    }

    var isBusy: Bool { phase != .idle }

    // MARK: Library

    @Published private(set) var libraryFolder = Settings.libraryFolder
    var libraryFolderName: String { (libraryFolder.path as NSString).abbreviatingWithTildeInPath }

    /// nil: back to ~/Movies/psvr-samples. Videos already in the old folder stay there.
    func setLibraryFolder(_ folder: URL?) {
        Settings.setLibraryFolder(folder)
        libraryFolder = Settings.libraryFolder
        try? FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
        store = LibraryStore()
        tab = .all
        refreshLibrary()
    }

    /// Download quality limit from Settings (nil: best available).
    nonisolated static var downloadMaxHeight: Int? {
        let height = UserDefaults.standard.integer(forKey: "downloadMaxHeight")
        return height > 0 ? height : nil
    }

    func refreshLibrary() {
        items = store.scan()
        categories = store.categories()
        if case .named(let c) = tab, !categories.contains(c) { tab = .all }
    }

    var hasUnsorted: Bool { items.contains { $0.category == nil } }

    /// Items for the current tab, type filter and search text.
    var visibleItems: [LibraryItem] {
        let words = search.split(separator: " ").map(String.init)
        return items.filter { item in
            switch tab {
            case .all: break
            case .unsorted: guard item.category == nil else { return false }
            case .named(let c): guard item.category == c else { return false }
            }
            guard kindFilter.matches(item.kind) else { return false }
            return words.allSatisfy { item.name.localizedStandardContains($0) }
        }
    }

    /// The category new downloads go to: the one being viewed.
    var currentCategory: String? {
        if case .named(let c) = tab { return c }
        return nil
    }

    func loops(_ category: String) -> Bool { LibraryStore.settings(for: category).loop }

    func setLoops(_ category: String, _ loop: Bool) {
        var settings = LibraryStore.settings(for: category)
        settings.loop = loop
        LibraryStore.save(settings, for: category)
        objectWillChange.send()
    }

    func newCategory(_ name: String) {
        do {
            let created = try LibraryStore.createCategory(name)
            refreshLibrary()
            tab = .named(created)
        } catch {
            status = "\(error)"
        }
    }

    func move(_ item: LibraryItem, to category: String?) {
        do { try LibraryStore.move(item, to: category) } catch { status = "\(error)" }
        refreshLibrary()
    }

    func removeCategory(_ category: String) {
        do { try LibraryStore.removeCategory(category, items: items) } catch { status = "\(error)" }
        refreshLibrary()
    }

    func reveal(_ item: LibraryItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func trash(_ item: LibraryItem) {
        LibraryStore.trash(item)
        refreshLibrary()
    }

    func addLinks(_ text: String, to category: String?) {
        let count = queue.add(text: text, to: category)
        status = count == 0 ? "No links found in that text" : "Adding \(count) video\(count == 1 ? "" : "s") to the library…"
    }

    // MARK: Actions

    func openPanel() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.videoTypes
        panel.directoryURL = LibraryStore.root
        panel.message = "Choose a video to play in the headset"
        if panel.runModal() == .OK, let url = panel.url { play(url) }
    }

    func play(_ item: LibraryItem) {
        guard !isBusy else { return }
        run(.file(item.url), loop: item.category.map(loops) ?? false)
    }

    /// A file from outside the library list (Open, drag and drop, Finder's Open With).
    func play(_ url: URL) {
        guard !isBusy else { return }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let category = parent.deletingLastPathComponent().standardizedFileURL == LibraryStore.root.standardizedFileURL
            ? parent.lastPathComponent : nil
        run(.file(url), loop: category.map(loops) ?? false)
    }

    func share() {
        guard !isBusy else { return }
        status = "Choose a window, app or screen to share…"
        CaptureTarget.pick { [weak self] filter in
            guard let self else { return }
            guard let filter else { self.status = "Nothing chosen"; return }
            self.run(.capture(filter))
        }
    }

    func testGrid() {
        guard !isBusy else { return }
        run(.testGrid)
    }

    /// Plays a link now (downloading it first).
    func playLink() {
        let link = self.link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy else { return }
        guard Downloader.isLink(link) else {
            status = "Paste a link that starts with https://"
            return
        }
        phase = .downloading(nil)
        let saveFolder = saveDownloads ? LibraryStore.folder(for: currentCategory) : nil
        let loop = currentCategory.map(loops) ?? false
        let model = self   // lives as long as the app
        Task.detached {
            do {
                let result = try Downloader.fetch(link, maxHeight: PlayerModel.downloadMaxHeight, keepIn: saveFolder,
                    log: { message in Task { @MainActor in model.status = message } },
                    progress: { value in Task { @MainActor in
                        if case .downloading = model.phase { model.phase = .downloading(value) }
                    } })
                await MainActor.run {
                    model.downloadCache = result.cacheDir
                    model.link = ""
                    model.phase = .idle
                    if saveFolder != nil { model.refreshLibrary() }
                    model.run(.file(result.file, info: result.info), loop: saveFolder != nil && loop)
                }
            } catch {
                await MainActor.run {
                    model.status = "\(error)"
                    model.phase = .idle
                }
            }
        }
    }

    func stop() { session?.stop(.quit) }

    /// Quitting the app: restore the headset, stop downloads, remove temporary files.
    func shutdown() {
        queue.cancelAll()
        session?.stop(.quit, waitForRestore: true)   // the app is about to exit
        removeDownload()
        // Back to normal when the app isn't running.
        if headsetConnected && lightsOff { headset.send(.lights(100)) }
    }

    // MARK: Sessions

    private func run(_ source: PlaybackSource, loop: Bool = false) {
        let sharing: Bool
        if case .capture = source { sharing = true } else { sharing = false }
        if headsetConnected { headset.send(.headsetPower(true)) }
        var options = PlaybackOptions()
        options.mirrorOnMac = previewOnMac
        options.lightsOff = lightsOff
        options.restoreLights = false   // the app keeps its own choice between videos
        options.soundDeviceUID = soundDeviceUID
        options.soundDeviceName = soundDeviceName
        outputDevices = AudioOutput.devices()
        if case .file = source, let name = soundDeviceName, soundDeviceUID != nil {
            soundNote = soundDeviceConnected ? "Sound: \(name)" : "No sound: \(name) isn't connected"
        } else {
            soundNote = nil
        }
        options.loop = loop
        options.pauseWhenRemoved = pauseWhenRemoved
        headsetOff = false
        let session = PlaybackSession(source: source, options: options,
                                      headset: headsetConnected ? headset : nil)
        session.onMessage = { [weak self] in self?.status = $0 }
        session.onStopping = { [weak self] reason in
            // Quick exit: close everything, including this window.
            if case .quickExit = reason {
                NSApp.windows.forEach { $0.orderOut(nil) }
                self?.queue.cancelAll()
            }
        }
        session.onEnded = { [weak self] reason in self?.ended(reason) }
        session.onHeadsetWorn = { [weak self] worn in self?.headsetOff = !worn }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak session] event in
            guard let session, session.isRunning, !(event.window?.firstResponder is NSText),
                  let key = Key(event: event) else { return event }
            session.handle(key)
            return nil
        }
        self.session = session
        phase = .starting
        // Let the window show "Starting…" before the display is prepared (can take a few seconds).
        DispatchQueue.main.async {
            do {
                try session.start()
                self.phase = .playing(sharing: sharing)
            } catch {
                self.status = "\(error)"
                self.phase = .idle
                self.session = nil
                self.removeDownload()
            }
        }
    }

    private func ended(_ reason: PlaybackSession.EndReason) {
        session = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        headsetOff = false
        previewOnMac = false   // never carries over to the next video
        removeDownload()
        if case .quickExit = reason {
            NSApp.terminate(nil)
            return
        }
        phase = .idle
        refreshLibrary()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "PSVR Player" }?.makeKeyAndOrderFront(nil)
    }

    private func removeDownload() {
        if let downloadCache { try? FileManager.default.removeItem(at: downloadCache) }
        downloadCache = nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = PlayerModel()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Killed from outside (Activity Monitor, logout): restore the headset like a normal quit.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.model.shutdown() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in model.play(url) }   // Finder "Open With" and Dock drops
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.shutdown() }
    }
}

@main
struct PSVRPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("PSVR Player", id: "main") {
            ContentView(model: delegate.model, queue: delegate.model.queue)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { delegate.model.openPanel() }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView(model: delegate.model)
        }

        Window("PSVR Player Controls", id: "controls") {
            ControlsView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .help) { ControlsMenuItem() }
        }
    }
}
