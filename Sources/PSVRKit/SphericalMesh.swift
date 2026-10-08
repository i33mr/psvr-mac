import Compression
import Foundation
import simd

/// Mesh projection from Google's Spherical Video V2 spec: the `mshp` box payload (also found in
/// YouTube's `ytmp` box and in Matroska's ProjectionPrivate for ProjectionType 3). YouTube serves
/// VR180 this way: a grid of points on the sphere, each with a texture coordinate in the frame.
public struct SphericalMesh {
    /// Points on the unit sphere (x right, y up, -z forward).
    public var positions: [SIMD3<Float>]
    /// Texture coordinates within the (eye's part of the) frame, origin at the top-left.
    public var uvs: [SIMD2<Float>]
    /// Triangle list (strips and fans are expanded).
    public var triangles: [UInt32]
}

public enum SphericalMeshError: Error, CustomStringConvertible {
    case truncated
    case unsupportedEncoding(String)
    case badMesh(String)

    public var description: String {
        switch self {
        case .truncated: return "mesh projection data is truncated"
        case .unsupportedEncoding(let e): return "unsupported mesh encoding '\(e)'"
        case .badMesh(let why): return "invalid mesh projection (\(why))"
        }
    }
}

extension SphericalMesh {
    /// Parses an `mshp`/`ytmp` payload: version+flags, CRC32, encoding ('dfl8' or 'raw '),
    /// then one `mesh` box (mono, or shared by both eyes) or two (left eye, right eye).
    public static func parse(projectionPayload p: Data) throws -> [SphericalMesh] {
        let bytes = [UInt8](p)
        guard bytes.count > 12 else { throw SphericalMeshError.truncated }
        let encoding = String(bytes: bytes[8..<12], encoding: .ascii) ?? "?"
        let body: [UInt8]
        switch encoding {
        case "dfl8": body = try inflate(Array(bytes[12...]))
        case "raw ": body = Array(bytes[12...])
        default: throw SphericalMeshError.unsupportedEncoding(encoding)
        }

        var meshes: [SphericalMesh] = []
        var offset = 0
        while offset + 8 <= body.count {
            let size = Int(UInt32(body[offset]) << 24 | UInt32(body[offset + 1]) << 16
                           | UInt32(body[offset + 2]) << 8 | UInt32(body[offset + 3]))
            guard size >= 8, offset + size <= body.count else { throw SphericalMeshError.truncated }
            if String(bytes: body[offset + 4 ..< offset + 8], encoding: .ascii) == "mesh" {
                meshes.append(try parseMeshBox(Array(body[offset + 8 ..< offset + size])))
            }
            offset += size
        }
        guard !meshes.isEmpty else { throw SphericalMeshError.badMesh("no mesh box") }
        return meshes
    }

    private static func parseMeshBox(_ data: [UInt8]) throws -> SphericalMesh {
        var bits = BitReader(data)
        _ = try bits.read(1)
        let coordinateCount = try bits.read(31)
        guard coordinateCount > 0 else { throw SphericalMeshError.badMesh("no coordinates") }
        var coordinates: [Float] = []
        coordinates.reserveCapacity(coordinateCount)
        for _ in 0..<coordinateCount {
            coordinates.append(Float(bitPattern: UInt32(try bits.read(32))))
        }

        _ = try bits.read(1)
        let vertexCount = try bits.read(31)
        let coordinateBits = bitsNeeded(coordinateCount * 2)
        var index = [Int](repeating: 0, count: 5)   // x, y, z, u, v (delta + zigzag coded)
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        for _ in 0..<vertexCount {
            for k in 0..<5 {
                index[k] += zigzag(try bits.read(coordinateBits))
                guard coordinates.indices.contains(index[k]) else { throw SphericalMeshError.badMesh("coordinate index") }
            }
            positions.append(SIMD3(coordinates[index[0]], coordinates[index[1]], coordinates[index[2]]))
            // Spec texture coordinates start at the bottom-left; flip to top-left.
            uvs.append(SIMD2(coordinates[index[3]], 1 - coordinates[index[4]]))
        }
        bits.alignToByte()

        _ = try bits.read(1)
        let listCount = try bits.read(31)
        let vertexBits = bitsNeeded(vertexCount * 2)
        var triangles: [UInt32] = []
        for _ in 0..<listCount {
            _ = try bits.read(8)                     // texture id (one texture per eye)
            let indexType = try bits.read(8)          // 0 triangles, 1 strip, 2 fan
            _ = try bits.read(1)
            let indexCount = try bits.read(31)
            var current = 0
            var list: [UInt32] = []
            for _ in 0..<indexCount {
                current += zigzag(try bits.read(vertexBits))
                guard current >= 0, current < vertexCount else { throw SphericalMeshError.badMesh("vertex index") }
                list.append(UInt32(current))
            }
            bits.alignToByte()
            switch indexType {
            case 0: triangles += list
            case 1 where list.count >= 3:
                for i in 0..<(list.count - 2) { triangles += [list[i], list[i + 1], list[i + 2]] }
            case 2 where list.count >= 3:
                for i in 1..<(list.count - 1) { triangles += [list[0], list[i], list[i + 1]] }
            default: break
            }
        }
        guard !triangles.isEmpty else { throw SphericalMeshError.badMesh("no triangles") }
        return SphericalMesh(positions: positions, uvs: uvs, triangles: triangles)
    }

    private static func bitsNeeded(_ n: Int) -> Int { max(1, Int(ceil(log2(Double(n))))) }
    private static func zigzag(_ v: Int) -> Int { (v >> 1) ^ -(v & 1) }

    /// Raw deflate (Apple's COMPRESSION_ZLIB has no zlib header, which is what 'dfl8' holds).
    private static func inflate(_ input: [UInt8]) throws -> [UInt8] {
        var capacity = max(input.count * 8, 64 << 10)
        while capacity <= 64 << 20 {
            var output = [UInt8](repeating: 0, count: capacity)
            let n = compression_decode_buffer(&output, capacity, input, input.count, nil, COMPRESSION_ZLIB)
            if n > 0 && n < capacity { return Array(output[0..<n]) }
            if n == 0 { throw SphericalMeshError.badMesh("deflate") }
            capacity *= 4
        }
        throw SphericalMeshError.badMesh("too large")
    }
}

private struct BitReader {
    let data: [UInt8]
    var position = 0   // in bits

    init(_ data: [UInt8]) { self.data = data }

    mutating func read(_ count: Int) throws -> Int {
        guard position + count <= data.count * 8 else { throw SphericalMeshError.truncated }
        var value = 0
        for _ in 0..<count {
            let bit = (data[position >> 3] >> (7 - UInt8(position & 7))) & 1
            value = value << 1 | Int(bit)
            position += 1
        }
        return value
    }

    mutating func alignToByte() { position = (position + 7) & ~7 }
}
