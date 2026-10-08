import Foundation
import PSVRPlayerCore

/// Links being added to the library, downloaded one after another in the background (playback
/// and browsing keep working meanwhile).
@MainActor
final class DownloadQueue: ObservableObject {
    struct Item: Identifiable {
        enum State: Equatable {
            case waiting
            case downloading(Double?)
            case added
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let link: String
        let category: String?
        var title: String?
        var state: State = .waiting
        fileprivate let token = DownloadToken()

        var isFinished: Bool {
            switch state {
            case .added, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    @Published private(set) var items: [Item] = [] {
        didSet { keepAwake(isBusy) }
    }
    /// Keeps the Mac from idle-sleeping while downloads run (the display may still sleep).
    private var awake: NSObjectProtocol?

    private func keepAwake(_ busy: Bool) {
        if busy, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Downloading videos")
        } else if !busy, let awake {
            ProcessInfo.processInfo.endActivity(awake)
            self.awake = nil
        }
    }
    /// Called after each video is added (to refresh the library).
    var onAdded: (() -> Void)?
    private var running = false

    var isBusy: Bool { items.contains { !$0.isFinished } }

    /// Accepts any text: one link per line (or separated by spaces); anything else is ignored.
    /// Returns how many links were queued.
    @discardableResult
    func add(text: String, to category: String?) -> Int {
        let links = text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'")) }
            .filter(Downloader.isLink)
        var seen = Set(items.filter { !$0.isFinished }.map(\.link))
        for link in links where seen.insert(link).inserted {
            items.append(Item(link: link, category: category))
        }
        runNext()
        return links.count
    }

    func cancel(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].token.cancel()
        if items[i].state == .waiting { items[i].state = .cancelled }
    }

    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[i]
        items[i] = Item(link: old.link, category: old.category, title: old.title)
        runNext()
    }

    func clearFinished() { items.removeAll(where: \.isFinished) }

    /// Stops everything (app quitting, quick exit).
    func cancelAll() {
        for i in items.indices where !items[i].isFinished {
            items[i].token.cancel()
            items[i].state = .cancelled
        }
    }

    private func runNext() {
        guard !running, let index = items.firstIndex(where: { $0.state == .waiting }) else { return }
        running = true
        items[index].state = .downloading(nil)
        let item = items[index]
        let folder = LibraryStore.folder(for: item.category)
        let id = item.id
        let queue = self   // lives as long as the app
        Task.detached {
            let outcome: Item.State
            do {
                _ = try Downloader.fetch(
                    item.link, maxHeight: PlayerModel.downloadMaxHeight, keepIn: folder,
                    log: { line in
                        // The title is the line in quotes.
                        guard line.hasPrefix("\""), line.hasSuffix("\"") else { return }
                        Task { @MainActor in queue.update(id) { $0.title = String(line.dropFirst().dropLast()) } }
                    },
                    progress: { value in
                        Task { @MainActor in
                            queue.update(id) { if case .downloading = $0.state { $0.state = .downloading(value) } }
                        }
                    },
                    token: item.token)
                outcome = .added
            } catch {
                outcome = item.token.isCancelled ? .cancelled : .failed("\(error)")
            }
            await MainActor.run {
                queue.update(id) { $0.state = outcome }
                if outcome == .added { queue.onAdded?() }
                queue.running = false
                queue.runNext()
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }
}
