import Foundation
import PSVRKit
import PSVRPlayerCore

/// A video in the library.
struct LibraryItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let date: Date
    /// "VR180 3D", "360°", "Flat 3D"… ("" if unknown).
    let kind: String
    /// Sub-folder name, nil for videos directly in the library folder.
    let category: String?
    var id: URL { url }
    /// The file name without trailing format tokens ("Snowy lake_180_sbs" → "Snowy lake").
    var name: String { Self.displayName(url.deletingPathExtension().lastPathComponent) }

    private static let formatTokens: Set<String> = [
        "180", "360", "vr180", "vr360", "flat", "sbs", "lr", "3dh", "hsbs", "fsbs",
        "tb", "ou", "tab", "3dv", "htb", "hou", "mono", "2d",
    ]

    static func displayName(_ fileName: String) -> String {
        var name = Substring(fileName)
        while let cut = name.lastIndex(where: { $0 == "_" || $0 == " " || $0 == "-" || $0 == "." }),
              formatTokens.contains(name[name.index(after: cut)...].lowercased()) {
            name = name[..<cut]
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fileName : trimmed
    }
}

/// Type filter for the library.
enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All", vr180 = "VR180", sphere = "360°", flat = "Flat"
    var id: String { rawValue }

    func matches(_ kind: String) -> Bool {
        switch self {
        case .all: return true
        case .vr180: return kind.hasPrefix("VR180") || kind.hasPrefix("180")
        case .sphere: return kind.hasPrefix("360")
        case .flat: return kind.hasPrefix("Flat") || kind == "3D" || kind.isEmpty
        }
    }
}

/// The library is a folder of videos; categories are its sub-folders. Nothing is stored anywhere
/// else, so Finder, backups and the terminal tool all see the same thing.
struct LibraryStore {
    /// Set in Settings (shared with the terminal tools); ~/Movies/psvr-samples by default.
    static var root: URL { Settings.libraryFolder }
    static let videoExtensions = ["mp4", "mov", "m4v"]

    /// Format labels need the file's header; cache them by path and modification date.
    private var kindCache: [String: (Date, String)] = [:]

    func categories() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    mutating func scan() -> [LibraryItem] {
        var items: [LibraryItem] = []
        for category in [nil] + categories().map(Optional.some) {
            let folder = category.map { Self.root.appendingPathComponent($0) } ?? Self.root
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for url in files where Self.videoExtensions.contains(url.pathExtension.lowercased()) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = values?.contentModificationDate ?? .distantPast
                let kind: String
                if let cached = kindCache[url.path], cached.0 == date {
                    kind = cached.1
                } else {
                    kind = Self.kind(of: url)
                    kindCache[url.path] = (date, kind)
                }
                items.append(LibraryItem(url: url, size: Int64(values?.fileSize ?? 0), date: date,
                                         kind: kind, category: category))
            }
        }
        return items.sorted { $0.date > $1.date }
    }

    /// A short label from the file's VR metadata and shape (as the player will show it).
    static func kind(of url: URL) -> String {
        let info = SphericalMetadata.read(url)
        let (projection, layout) = info.resolved(fileName: url.deletingPathExtension().lastPathComponent)
            ?? (info.projection ?? .flat, info.layout ?? .mono)
        let stereo = layout == .sbs || layout == .tb
        switch projection {
        case .mesh:
            // A mesh that reaches behind the viewer is a full 360°; one that doesn't is VR180.
            let meshes = info.meshPayload.flatMap { try? SphericalMesh.parse(projectionPayload: $0) } ?? []
            let wraps = meshes.contains { $0.positions.contains { $0.z > 0.5 } }
            return wraps ? (stereo ? "360° 3D" : "360°") : (stereo ? "VR180 3D" : "180°")
        case .equirect180: return stereo ? "VR180 3D" : "180°"
        case .equirect360: return stereo ? "360° 3D" : "360°"
        case .flat: return stereo ? "Flat 3D" : (info.width > 0 ? "Flat" : "")
        }
    }

    // MARK: Changes

    static func folder(for category: String?) -> URL {
        category.map { root.appendingPathComponent($0) } ?? root
    }

    /// Folder names can't contain "/" or ":" and shouldn't start with "." (hidden).
    static func cleanName(_ name: String) -> String? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !cleaned.isEmpty, !cleaned.hasPrefix(".") else { return nil }
        return String(cleaned.prefix(60))
    }

    @discardableResult
    static func createCategory(_ name: String) throws -> String {
        guard let clean = cleanName(name) else { throw LibraryError("That name can't be used for a category.") }
        let url = root.appendingPathComponent(clean)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw LibraryError("“\(clean)” already exists.") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return clean
    }

    /// Moves a video (and its mesh file, if any) into a category (nil: out of all categories).
    static func move(_ item: LibraryItem, to category: String?) throws {
        let folder = folder(for: category)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(item.url.lastPathComponent)
        guard target != item.url else { return }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw LibraryError("A video with this name is already in that category.")
        }
        try FileManager.default.moveItem(at: item.url, to: target)
        let sidecar = SphericalInfo.meshSidecar(for: item.url)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try? FileManager.default.moveItem(at: sidecar, to: SphericalInfo.meshSidecar(for: target))
        }
    }

    static func trash(_ item: LibraryItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        try? FileManager.default.trashItem(at: SphericalInfo.meshSidecar(for: item.url), resultingItemURL: nil)
    }

    /// Removes a category; its videos move back to the main library folder first.
    static func removeCategory(_ category: String, items: [LibraryItem]) throws {
        for item in items where item.category == category { try move(item, to: nil) }
        let folder = root.appendingPathComponent(category)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if left.allSatisfy({ $0.hasPrefix(".") }) {
            try FileManager.default.removeItem(at: folder)
        } else {
            throw LibraryError("“\(category)” still contains other files; remove them in Finder first.")
        }
    }

    // MARK: Category settings

    /// Per-category settings, kept in a hidden file inside the category folder.
    struct CategorySettings: Codable {
        var loop = false
    }

    static func settings(for category: String) -> CategorySettings {
        let url = root.appendingPathComponent(category).appendingPathComponent(".psvr-category.json")
        guard let data = try? Data(contentsOf: url) else { return CategorySettings() }
        return (try? JSONDecoder().decode(CategorySettings.self, from: data)) ?? CategorySettings()
    }

    static func save(_ settings: CategorySettings, for category: String) {
        let url = root.appendingPathComponent(category).appendingPathComponent(".psvr-category.json")
        try? JSONEncoder().encode(settings).write(to: url, options: .atomic)
    }
}

struct LibraryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
