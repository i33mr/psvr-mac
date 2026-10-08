import PSVRPlayerCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var queue: DownloadQueue
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false
    @State private var confirmPreview = false
    @State private var showAddLinks = false
    @State private var newCategoryName: String?
    @State private var removingCategory: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch model.phase {
            case .playing(let sharing): playing(sharing: sharing)
            case .starting: busy("Starting… switching the headset to VR mode")
            case .downloading(let progress): downloading(progress)
            case .idle: idle
            }
            Divider()
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 640)
        .onDrop(of: [.fileURL, .url], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
        .sheet(isPresented: $showAddLinks) {
            AddLinksSheet(categories: model.categories, initialCategory: model.currentCategory) { text, category in
                model.addLinks(text, to: category)
            }
        }
        .alert("New Category", isPresented: Binding(get: { newCategoryName != nil }, set: { if !$0 { newCategoryName = nil } })) {
            TextField("Name, e.g. Relax", text: Binding(get: { newCategoryName ?? "" }, set: { newCategoryName = $0 }))
            Button("Create") { if let name = newCategoryName { model.newCategory(name) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Categories are folders inside \(model.libraryFolderName).")
        }
        .alert("Remove “\(removingCategory ?? "")”?", isPresented: Binding(get: { removingCategory != nil }, set: { if !$0 { removingCategory = nil } })) {
            Button("Remove Category") { if let c = removingCategory { model.removeCategory(c) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its videos stay in the library (they move back to Unsorted); only the category goes.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "visionpro").font(.system(size: 28))
            Text("PSVR Player").font(.title.bold())
            Spacer()
            Label(model.headsetConnected ? "Headset connected" : "Headset not connected",
                  systemImage: model.headsetConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.headsetConnected ? .green : .orange)
            Button { openWindow(id: "controls") } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.borderless)
                .font(.title2)
                .help("Controls")
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .font(.title2)
                .help("Settings (⌘,)")
        }
    }

    // MARK: Start screen

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { model.openPanel() } label: { Label("Open Video…", systemImage: "film") }
                Button { showAddLinks = true } label: { Label("Add Links…", systemImage: "square.and.arrow.down.on.square") }
                Button { model.share() } label: { Label("Share a Window or Screen…", systemImage: "macwindow") }
                Button { model.testGrid() } label: { Label("Calibration Grid", systemImage: "grid") }
            }
            .controlSize(.large)

            HStack(spacing: 10) {
                Image(systemName: "link")
                TextField("Paste a YouTube or other link to play now", text: $model.link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.playLink() }
                Toggle("Save to library", isOn: $model.saveDownloads)
                Button("Play") { model.playLink() }
                    .disabled(model.link.isEmpty)
            }

            categoryBar
            searchBar
            libraryList
            if !queue.items.isEmpty { downloadsPanel }

            HStack {
                if !model.soundDeviceConnected {
                    Label("\(model.soundDeviceName ?? "The chosen sound device") isn't connected: videos will play without sound",
                          systemImage: "speaker.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    SettingsLink { Text("Change…").font(.caption) }
                }
                Spacer()
                // Deliberately small and confirmed: shows the content on this Mac's screen.
                Toggle(isOn: Binding(get: { model.previewOnMac },
                                     set: { on in if on { confirmPreview = true } else { model.previewOnMac = false } })) {
                    Text("Preview on this Mac").font(.caption)
                }
                .toggleStyle(.checkbox)
                .help("Also show what the headset shows in a small window on this Mac, for the next video only")
            }
            .alert("Show what you're watching on this Mac's screen?", isPresented: $confirmPreview) {
                Button("Show Preview") { model.previewOnMac = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A small window on this Mac will show the headset view during the next video or share. "
                     + "It switches off again when that ends, and the quick exit closes it instantly.")
            }
        }
    }

    private var categoryBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", tab: .all, count: model.items.count)
                    if model.hasUnsorted && !model.categories.isEmpty {
                        chip("Unsorted", tab: .unsorted, count: model.items.filter { $0.category == nil }.count)
                    }
                    ForEach(model.categories, id: \.self) { category in
                        chip(category, tab: .named(category), count: model.items.filter { $0.category == category }.count,
                             loops: model.loops(category))
                            .contextMenu {
                                Toggle("Loop Videos in “\(category)”", isOn: Binding(
                                    get: { model.loops(category) }, set: { model.setLoops(category, $0) }))
                                Button("Show in Finder") {
                                    NSWorkspace.shared.open(LibraryStore.folder(for: category))
                                }
                                Divider()
                                Button("Remove Category…") { removingCategory = category }
                            }
                    }
                }
            }
            Button { newCategoryName = "" } label: { Image(systemName: "plus") }
                .help("New category")
            Button { model.refreshLibrary() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
    }

    private func chip(_ title: String, tab: CategoryTab, count: Int, loops: Bool = false) -> some View {
        let selected = model.tab == tab
        return Button { model.tab = tab } label: {
            HStack(spacing: 4) {
                if loops { Image(systemName: "repeat").font(.caption2) }
                Text(title)
                Text("\(count)").foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by title", text: $model.search).textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            Picker("Type", selection: $model.kindFilter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            if case .named(let category) = model.tab {
                Toggle(isOn: Binding(get: { model.loops(category) }, set: { model.setLoops(category, $0) })) {
                    Label("Loop", systemImage: "repeat")
                }
                .toggleStyle(.button)
                .help("Videos in “\(category)” repeat until you stop them")
            }
        }
    }

    @ViewBuilder
    private var libraryList: some View {
        let visible = model.visibleItems
        if model.items.isEmpty {
            Text("Videos in \(model.libraryFolderName) show up here. Use Add Links… or drag videos onto this window.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if visible.isEmpty {
            Text("Nothing matches.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            List(visible) { item in
                row(item)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func row(_ item: LibraryItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    if model.tab == .all, let category = item.category {
                        Text("· \(category)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !item.kind.isEmpty {
                Text(item.kind)
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Button { model.play(item) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.play(item) }
        .contextMenu {
            Button("Play in Headset") { model.play(item) }
            Menu("Move to") {
                Button("No Category") { model.move(item, to: nil) }.disabled(item.category == nil)
                Divider()
                ForEach(model.categories, id: \.self) { category in
                    Button(category) { model.move(item, to: category) }.disabled(item.category == category)
                }
            }
            Button("Show in Finder") { model.reveal(item) }
            Divider()
            Button("Move to Trash") { model.trash(item) }
        }
    }

    private var downloadsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                if queue.items.contains(where: \.isFinished) {
                    Button("Clear Finished") { queue.clearFinished() }.buttonStyle(.borderless)
                }
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(queue.items) { item in downloadRow(item) }
                }
            }
            .frame(maxHeight: 140)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func downloadRow(_ item: DownloadQueue.Item) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? item.link).lineLimit(1)
                switch item.state {
                case .waiting:
                    Text("Waiting\(item.category.map { " · to \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                case .downloading(let p):
                    if let p {
                        ProgressView(value: p).controlSize(.small)
                    } else {
                        Text("Looking up…").font(.caption).foregroundStyle(.secondary)
                    }
                case .added:
                    Label("Added\(item.category.map { " to \($0)" } ?? "")", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .failed(let why):
                    Text(why).font(.caption).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch item.state {
            case .waiting, .downloading:
                Button { queue.cancel(item.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Cancel")
            case .failed, .cancelled:
                Button { queue.retry(item.id) } label: { Image(systemName: "arrow.clockwise.circle") }
                    .buttonStyle(.borderless).help("Try again")
            case .added:
                EmptyView()
            }
        }
    }

    // MARK: Other phases

    private func playing(sharing: Bool) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: sharing ? "macwindow.on.rectangle" : "visionpro").font(.system(size: 48))
            Text(sharing ? "Sharing to the headset" : "Playing in the headset").font(.title2.bold())
            if model.headsetOff {
                Label("Headset off: paused. Put it on to continue.", systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let note = model.soundNote {
                Label(note, systemImage: note.hasPrefix("No sound") ? "speaker.slash" : "speaker.wave.2")
                    .font(.callout)
                    .foregroundStyle(note.hasPrefix("No sound") ? .orange : .secondary)
            }
            if model.previewOnMac {
                Label("Preview on this Mac is on for this session", systemImage: "eye")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text(sharing
                 ? "Keep using the shared window as usual. Headset remote: mic-mute recenters, double-tap exits."
                 : "Space pauses · ←/→ seek · R recenters · Esc stops\nHeadset remote: mic-mute recenters · double-tap mic-mute exits")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("All Controls…") { openWindow(id: "controls") }
                .buttonStyle(.link)
            if queue.isBusy {
                Text("Downloads continue in the background.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if model.headsetConnected {
                    Button { model.lightsOff.toggle() } label: {
                        Label(model.lightsOff ? "Turn Headset Lights On" : "Turn Headset Lights Off",
                              systemImage: model.lightsOff ? "lightbulb" : "lightbulb.slash")
                    }
                    .help("The headset's blue tracking lights (only used by the PlayStation Camera)")
                }
                Button(role: .destructive) { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            }
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func busy(_ text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func downloading(_ progress: Double?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            if let progress {
                ProgressView(value: progress) { Text("Downloading…") } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
            } else {
                ProgressView("Looking up the video…")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                if url.isFileURL {
                    model.play(url)
                } else {
                    model.link = url.absoluteString
                    model.playLink()
                }
            }
        }
        return true
    }
}

/// Paste several links (one per line) and pick where they go.
struct AddLinksSheet: View {
    let categories: [String]
    let initialCategory: String?
    let onAdd: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var category: String?

    init(categories: [String], initialCategory: String?, onAdd: @escaping (String, String?) -> Void) {
        self.categories = categories
        self.initialCategory = initialCategory
        self.onAdd = onAdd
        _category = State(initialValue: initialCategory)
    }

    private var linkCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).filter { Downloader.isLink(String($0)) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Links to the Library").font(.title3.bold())
            Text("Paste YouTube (or other) links, one per line. They download one after another in the background; nothing plays.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Picker("Add to", selection: $category) {
                Text("No category").tag(String?.none)
                ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .frame(maxWidth: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(linkCount > 0 ? "Add \(linkCount) Link\(linkCount == 1 ? "" : "s")" : "Add") {
                    onAdd(text, category)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(linkCount == 0)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// The sound device choice (also in Settings).
struct SoundPicker: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        Picker("Sound", selection: $model.soundDeviceUID) {
            Text("Mac's current output").tag(String?.none)
            Divider()
            ForEach(model.outputDevices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
            if let uid = model.soundDeviceUID, !model.soundDeviceConnected {
                Text("\(model.soundDeviceName ?? "Saved device") (not connected)").tag(Optional(uid))
            }
        }
    }
}

/// Settings… (⌘,)
struct SettingsView: View {
    @ObservedObject var model: PlayerModel
    @AppStorage("downloadMaxHeight") private var downloadMaxHeight = 0

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Folder") {
                    Text(model.libraryFolderName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…", action: chooseFolder)
                    Button("Show in Finder") { NSWorkspace.shared.open(model.libraryFolder) }
                    if model.libraryFolder != Settings.defaultLibraryFolder {
                        Button("Use Default") { model.setLibraryFolder(nil) }
                    }
                }
                Text("Categories are sub-folders. Changing the folder doesn't move existing videos. The terminal player uses the same folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Downloads") {
                Picker("Quality", selection: $downloadMaxHeight) {
                    Text("Best available").tag(0)
                    Text("Up to 4K (2160p)").tag(2160)
                    Text("Up to 1440p").tag(1440)
                    Text("Up to 1080p").tag(1080)
                }
                Text("Lower is smaller and faster to download. The headset shows 960×1080 per eye, but 360° and 180° videos spread their pixels around you, so higher resolutions still look sharper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Headset") {
                SoundPicker(model: model)
                Toggle("Pause when the headset is taken off", isOn: $model.pauseWhenRemoved)
                Toggle("Keep the headset's tracking lights off", isOn: $model.lightsOff)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.libraryFolder
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url { model.setLibraryFolder(url) }
    }
}

/// Help → PSVR Player Controls (also the ? button). ⌘? is kept by macOS for the Help menu's search.
struct ControlsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("PSVR Player Controls") { openWindow(id: "controls") }
    }
}

/// Every control in one place: the headset's inline remote and the keyboard.
struct ControlsView: View {
    private let sections: [(String, [(String, String)])] = [
        ("Headset remote", [
            ("Mic-mute", "Recenter: where you're facing becomes forward"),
            ("Double-tap mic-mute", "Quick exit: headset screen off, stop, and quit"),
            ("Vol+ / Vol−", "Seek forward / back 10 s"),
            ("Hold vol+ or vol−", "Play / pause"),
        ]),
        ("Keyboard, while a video plays", [
            ("Space", "Play / pause"),
            ("← / →", "Seek back / forward 10 s"),
            ("↓ / ↑", "Seek back / forward 60 s"),
            ("R", "Recenter"),
            ("Esc or Q", "Stop"),
            ("[ / ]", "Field of view (saved)"),
            (", / .", "3D separation, i.e. eye distance / IPD (saved)"),
            ("− / =", "Screen size for flat videos (saved)"),
            ("P / L", "Projection / 3D layout, if a video looks wrong"),
            ("S", "Swap eyes, if 3D looks inside-out"),
            ("D", "Lens correction on / off"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 7) {
                ForEach(sections, id: \.0) { title, rows in
                    GridRow {
                        Text(title).font(.headline).padding(.top, title == sections[0].0 ? 0 : 10)
                            .gridCellColumns(2)
                    }
                    ForEach(rows, id: \.0) { key, action in
                        GridRow {
                            Text(key).fontWeight(.medium)
                            Text(action).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("Keys work in any PSVR Player window. When sharing a window or screen, the keyboard and mouse stay "
                 + "with what you're sharing; the headset remote still recenters and exits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 480)
    }
}
