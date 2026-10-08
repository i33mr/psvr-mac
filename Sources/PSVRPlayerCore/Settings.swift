import Foundation

/// Saved to ~/.config/psvr-mac/settings.json, shared by the app and the terminal tools: per-viewer
/// tuning (saved whenever it changes during playback) and the library folder.
public struct Settings: Codable {
    var fovDegrees: Float = 85
    var stereoSeparationDegrees: Float = 0
    /// Width of the flat/virtual screen; optional so older settings files still load.
    var flatScreenDegrees: Float?
    /// The video library (nil: ~/Movies/psvr-samples).
    var libraryPath: String?

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/psvr-mac/settings.json")

    public static let defaultLibraryFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/psvr-samples")

    /// Where library videos (and kept downloads) go.
    public static var libraryFolder: URL {
        load().libraryPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? defaultLibraryFolder
    }

    /// nil goes back to the default folder. Existing videos are not moved.
    public static func setLibraryFolder(_ folder: URL?) {
        update { $0.libraryPath = folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } }
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: url) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    /// Re-reads the file before changing it, so the app and a running player don't undo each other's changes.
    static func update(_ change: (inout Settings) -> Void) {
        var settings = load()
        change(&settings)
        settings.save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Self.url, options: .atomic)
        } catch {
            print("warning: could not save settings: \(error.localizedDescription)")
        }
    }
}
