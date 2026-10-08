import Foundation

public enum Projection: String, CaseIterable {
    case equirect360 = "360", equirect180 = "180", flat
    /// Mesh from the file (YouTube VR180); only available when the video carries one.
    case mesh

    var shaderValue: Float {
        switch self {
        case .equirect360: return 0
        case .equirect180: return 1
        case .flat: return 2
        case .mesh: return 3
        }
    }
}

public enum StereoLayout: String, CaseIterable {
    case mono, sbs, tb
}

extension CaseIterable where Self: Equatable {
    var next: Self {
        let all = Array(Self.allCases)
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Format guessing. The player uses, in order: command-line flags, the file's spherical metadata,
/// file-name tokens (e.g. "_360_TB", "180_LR", "3dh"), and finally the aspect ratio (`complete`).
enum FormatGuess {
    static func fromName(_ name: String) -> (Projection?, StereoLayout?) {
        let tokens = Set(name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        var projection: Projection?
        if tokens.contains("180") || tokens.contains("vr180") { projection = .equirect180 }
        else if tokens.contains("360") || tokens.contains("vr360") { projection = .equirect360 }
        else if tokens.contains("flat") { projection = .flat }

        var layout: StereoLayout?
        if !tokens.isDisjoint(with: ["sbs", "lr", "3dh", "hsbs", "fsbs"]) { layout = .sbs }
        else if !tokens.isDisjoint(with: ["tb", "ou", "tab", "3dv", "htb", "hou"]) { layout = .tb }
        else if !tokens.isDisjoint(with: ["mono", "2d"]) { layout = .mono }
        return (projection, layout)
    }

    static func complete(projection: Projection?, layout: StereoLayout?, width: Int, height: Int) -> (Projection, StereoLayout) {
        let aspect = Double(width) / Double(max(height, 1))
        let near = { (x: Double) in abs(aspect - x) < 0.12 }
        switch (projection, layout) {
        case let (p?, l?): return (p, l)
        case let (p?, nil):
            switch p {
            case .equirect360: return (p, near(1) ? .tb : .mono)
            case .equirect180: return (p, near(2) ? .sbs : (near(0.5) ? .tb : .mono))
            case .flat: return (p, aspect > 3 ? .sbs : (aspect < 1.1 ? .tb : .mono))
            case .mesh: return (p, aspect > 1.5 ? .sbs : .mono)   // YouTube VR180 is side-by-side
            }
        case let (nil, l?):
            switch l {
            case .mono: return (near(2) ? .equirect360 : .flat, l)
            case .sbs: return (near(2) ? .equirect180 : (near(4) ? .equirect360 : .flat), l)
            case .tb: return (near(1) ? .equirect360 : (near(0.5) ? .equirect180 : .flat), l)
            }
        case (nil, nil):
            if near(2) { return (.equirect360, .mono) }
            if near(1) { return (.equirect360, .tb) }
            if aspect > 3 { return (.flat, .sbs) }
            return (.flat, .mono)
        }
    }
}

/// What the file itself says about its projection and 3D layout.
public struct SphericalInfo {
    public var projection: Projection?
    public var layout: StereoLayout?
    /// Matroska StereoMode can put the right eye first.
    public var rightEyeFirst = false
    /// Spherical Video V2 mesh payload (`mshp`/`ytmp`), when the projection is a mesh.
    public var meshPayload: Data?
    /// Video size from the MP4 header (0 if unknown); lets callers guess the format like the player does.
    public var width = 0
    public var height = 0

    /// Projection and layout as the player will show them: metadata first, then file-name tokens
    /// (e.g. "_180_sbs"), then the frame's shape.
    public func resolved(fileName: String) -> (Projection, StereoLayout)? {
        guard width > 0, height > 0 else { return nil }
        let name = FormatGuess.fromName(fileName)
        return FormatGuess.complete(projection: projection ?? name.0, layout: layout ?? name.1,
                                    width: width, height: height)
    }

    /// Sidecar that keeps a mesh with a saved video (ffmpeg drops mesh projections when remuxing).
    public static func meshSidecar(for video: URL) -> URL { video.appendingPathExtension("mesh") }
}

/// Reads Google's Spherical Video V2 metadata, which most VR cameras and tools write:
/// MP4 `st3d` + `sv3d/proj` (`equi`, `mshp`, YouTube's `ytmp`), or the Matroska/WebM equivalents.
public enum SphericalMetadata {
    public static func read(_ url: URL) -> SphericalInfo {
        var info = ["webm", "mkv"].contains(url.pathExtension.lowercased()) ? matroska(url) : mp4(url)
        if info.meshPayload == nil, let sidecar = try? Data(contentsOf: SphericalInfo.meshSidecar(for: url)) {
            info.meshPayload = sidecar
            info.projection = .mesh
        }
        return info
    }

    // MARK: MP4

    private static func mp4(_ url: URL) -> SphericalInfo {
        var info = SphericalInfo()
        guard let moov = moovBox(url) else { return info }

        // Track header: width and height (16.16 fixed point) are its last 8 bytes; first video track wins.
        var search = 0
        while let i = find("tkhd", in: Array(moov[search...])).map({ $0 + search }), i >= 4 {
            let size = Int(moov[i - 4 ..< i].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let end = i - 4 + size
            if size > 16, end <= moov.count {
                let w = Int(moov[end - 8 ..< end - 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } >> 16)
                let h = Int(moov[end - 4 ..< end].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } >> 16)
                if w > 0 && h > 0 {
                    info.width = w
                    info.height = h
                    break
                }
            }
            search = i + 4
        }

        if let i = find("st3d", in: moov), i + 8 < moov.count {
            switch moov[i + 8] {   // after type + version/flags
            case 0: info.layout = .mono
            case 1: info.layout = .tb
            case 2: info.layout = .sbs
            default: break
            }
        }

        if let i = find("equi", in: moov), i + 24 <= moov.count {
            func bound(_ o: Int) -> Double {
                Double(moov[i + o ..< i + o + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) / 4_294_967_296
            }
            let horizontalCrop = bound(16) + bound(20)   // left + right
            info.projection = horizontalCrop > 0.4 ? .equirect180 : .equirect360
        } else if let payload = boxPayload(["mshp", "ytmp"], in: moov) {
            info.projection = .mesh
            info.meshPayload = payload
        } else if find("sv3d", in: moov) != nil {
            info.projection = .equirect360
        }
        return info
    }

    /// Payload (after size + type) of the first box of one of `types`.
    private static func boxPayload(_ types: [String], in bytes: [UInt8]) -> Data? {
        for type in types {
            guard let i = find(type, in: bytes), i >= 4 else { continue }
            let size = Int(bytes[i - 4 ..< i].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard size > 8, i - 4 + size <= bytes.count else { continue }
            return Data(bytes[i + 4 ..< i - 4 + size])
        }
        return nil
    }

    /// Payload of the top-level `moov` box (it can sit after gigabytes of media data).
    private static func moovBox(_ url: URL) -> [UInt8]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        var offset: UInt64 = 0
        while let header = try? file.read(upToCount: 16), header.count >= 8 {
            let h = [UInt8](header)
            var size = UInt64(h[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            var headerSize: UInt64 = 8
            if size == 1, h.count == 16 {
                size = h[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                headerSize = 16
            }
            let type = String(bytes: h[4..<8], encoding: .ascii)
            if type == "moov" {
                guard size > headerSize, size < 256 << 20 else { return nil }
                try? file.seek(toOffset: offset + headerSize)
                return (try? file.read(upToCount: Int(size - headerSize))).map { [UInt8]($0) }
            }
            guard size >= headerSize else { return nil }   // size 0 (to end of file) or corrupt
            offset += size
            try? file.seek(toOffset: offset)
        }
        return nil
    }

    private static func find(_ type: String, in bytes: [UInt8]) -> Int? {
        let t = Array(type.utf8)
        guard bytes.count >= 4 else { return nil }
        return (0...(bytes.count - 4)).first { bytes[$0] == t[0] && bytes[$0 + 1] == t[1] && bytes[$0 + 2] == t[2] && bytes[$0 + 3] == t[3] }
    }

    // MARK: Matroska / WebM

    private static let masters: Set<UInt32> = [
        0x1853_8067,   // Segment
        0x1654_AE6B,   // Tracks
        0xAE,          // TrackEntry
        0xE0,          // Video
        0x7670,        // Projection
    ]

    private static func matroska(_ url: URL) -> SphericalInfo {
        var info = SphericalInfo()
        guard let file = try? FileHandle(forReadingFrom: url),
              let head = try? file.read(upToCount: 8 << 20) else { return info }
        try? file.close()
        let b = [UInt8](head)

        // Walks EBML elements, descending only into the masters on the path to the video track.
        func walk(_ start: Int, _ end: Int) {
            var i = start
            while i < end, let (id, idLength) = readID(b, i), let (size, sizeLength) = readSize(b, i + idLength) {
                let dataStart = i + idLength + sizeLength
                let dataEnd = size.map { min(dataStart + $0, end) } ?? end   // unknown size: to the end
                if id == 0x1F43_B675 { return }                              // Cluster: media data begins
                if masters.contains(id) {
                    walk(dataStart, dataEnd)
                } else if dataEnd <= b.count {
                    let payload = Array(b[dataStart ..< dataEnd])
                    let value = payload.reduce(0) { $0 << 8 | Int($1) }
                    switch id {
                    case 0x53B8:   // StereoMode
                        switch value {
                        case 1: info.layout = .sbs
                        case 11: info.layout = .sbs; info.rightEyeFirst = true
                        case 3: info.layout = .tb
                        case 2: info.layout = .tb; info.rightEyeFirst = true
                        case 0: info.layout = .mono
                        default: break
                        }
                    case 0x7671:   // ProjectionType: 1 equirectangular, 3 mesh
                        if value == 1 { info.projection = info.projection ?? .equirect360 }
                        if value == 3 { info.projection = .mesh }
                    case 0x7672:   // ProjectionPrivate
                        if info.projection == .mesh || payload.count > 64 {
                            info.meshPayload = Data(payload)
                        } else if payload.count >= 20 {
                            // equi bounds after version/flags: top, bottom, left, right (0.32 fixed point)
                            let left = Double(payload[12..<16].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) / 4_294_967_296
                            let right = Double(payload[16..<20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) / 4_294_967_296
                            info.projection = left + right > 0.4 ? .equirect180 : .equirect360
                        }
                    default: break
                    }
                }
                guard dataEnd > i else { return }
                i = dataEnd
            }
        }
        walk(0, b.count)
        if info.meshPayload != nil { info.projection = .mesh }
        return info
    }

    private static func readID(_ b: [UInt8], _ i: Int) -> (UInt32, Int)? {
        guard i < b.count, b[i] != 0 else { return nil }
        let length = b[i].leadingZeroBitCount + 1
        guard length <= 4, i + length <= b.count else { return nil }
        return (b[i ..< i + length].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, length)
    }

    /// Element size; nil means "unknown" (all value bits set).
    private static func readSize(_ b: [UInt8], _ i: Int) -> (Int?, Int)? {
        guard i < b.count, b[i] != 0 else { return nil }
        let length = b[i].leadingZeroBitCount + 1
        guard length <= 8, i + length <= b.count else { return nil }
        var value = UInt64(b[i] & (0xFF >> length))
        for k in 1..<length { value = value << 8 | UInt64(b[i + k]) }
        let unknown = value == (UInt64(1) << (7 * length)) - 1
        return (unknown ? nil : Int(value), length)
    }
}
