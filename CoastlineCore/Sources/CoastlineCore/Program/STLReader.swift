import Foundation

/// Reads STL meshes (binary or ASCII) for display: jig parts and other models that only exist as
/// meshes. Each triangle gets its own three vertices and its facet normal (flat shading, which
/// suits machined and printed parts). No units in STL: the numbers are taken as mm.
public enum STLReader {
    public enum ReadError: Error, CustomStringConvertible {
        case empty(String)
        public var description: String {
            switch self { case .empty(let file): "\(file) has no triangles." }
        }
    }

    public static func read(_ url: URL) throws -> MeshData {
        let data = try Data(contentsOf: url)
        let triangles = isBinary(data) ? binary(data) : ascii(String(decoding: data, as: UTF8.self))
        guard !triangles.isEmpty else { throw ReadError.empty(url.lastPathComponent) }
        var vertices: [Float] = [], normals: [Float] = [], indices: [UInt32] = []
        vertices.reserveCapacity(triangles.count * 9)
        normals.reserveCapacity(triangles.count * 9)
        indices.reserveCapacity(triangles.count * 3)
        var lo = [Float](repeating: .greatestFiniteMagnitude, count: 3), hi = [Float](repeating: -.greatestFiniteMagnitude, count: 3)
        for t in triangles {
            // The facet normal from the winding (files often carry zero normals).
            let a = t[0], b = t[1], c = t[2]
            let u = (b.0 - a.0, b.1 - a.1, b.2 - a.2), v = (c.0 - a.0, c.1 - a.1, c.2 - a.2)
            var n = (u.1 * v.2 - u.2 * v.1, u.2 * v.0 - u.0 * v.2, u.0 * v.1 - u.1 * v.0)
            let length = (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).squareRoot()
            if length > 0 { n = (n.0 / length, n.1 / length, n.2 / length) }
            for p in t {
                indices.append(UInt32(vertices.count / 3))
                vertices += [p.0, p.1, p.2]
                normals += [n.0, n.1, n.2]
                lo = [min(lo[0], p.0), min(lo[1], p.1), min(lo[2], p.2)]
                hi = [max(hi[0], p.0), max(hi[1], p.1), max(hi[2], p.2)]
            }
        }
        return MeshData(vertices: vertices, normals: normals, indices: indices,
                        boundsMin: Vec3(Double(lo[0]), Double(lo[1]), Double(lo[2])),
                        boundsMax: Vec3(Double(hi[0]), Double(hi[1]), Double(hi[2])),
                        exact: false, faceCount: triangles.count)
    }

    typealias Point = (Float, Float, Float)

    /// Binary STL: an 80-byte header, a triangle count, then 50 bytes per triangle. (Some binary
    /// files start with "solid" too, so the size decides.)
    static func isBinary(_ data: Data) -> Bool {
        guard data.count >= 84 else { return false }
        let count = data.subdata(in: 80..<84).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        return 84 + Int(count) * 50 == data.count
    }

    static func binary(_ data: Data) -> [[Point]] {
        let count = Int(data.subdata(in: 80..<84).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        return data.withUnsafeBytes { raw -> [[Point]] in
            (0..<count).map { k in
                let base = 84 + k * 50 + 12  // skip the stored normal
                return (0..<3).map { v -> Point in
                    let o = base + v * 12
                    func f(_ i: Int) -> Float { Float(bitPattern: raw.loadUnaligned(fromByteOffset: o + i * 4, as: UInt32.self).littleEndian) }
                    return (f(0), f(1), f(2))
                }
            }
        }
    }

    static func ascii(_ text: String) -> [[Point]] {
        var triangles: [[Point]] = [], current: [Point] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.first == "vertex", words.count == 4,
                  let x = Float(words[1]), let y = Float(words[2]), let z = Float(words[3]) else { continue }
            current.append((x, y, z))
            if current.count == 3 {
                triangles.append(current)
                current.removeAll()
            }
        }
        return triangles
    }
}
