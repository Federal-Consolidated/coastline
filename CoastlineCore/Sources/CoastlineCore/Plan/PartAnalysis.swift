import Foundation
import simd

/// What limits machining a part from one side, as measured by the engine.
public struct PartAnalysis: Sendable, Equatable {
    public var minCornerRadius: Double?
    public var minConcaveRadius: Double?
    public var undercutArea: Double
    public var thinnestWall: Double?
    public var depth: Double
    /// Where the part's cross-section is largest (work Z): the split for two-sided jobs.
    public var partingZ: Double?
    /// Area of faces 2.5D operations can't finish (domes, fillets, freeform), mm².
    public var freeformArea: Double = 0
    /// Flat floors (square to the tool), walls (along it) and steep (> 45°) freeform area, mm².
    public var flatArea: Double = 0
    public var wallArea: Double = 0
    public var steepArea: Double = 0
    /// Part volume (mm³) and how round its silhouette is (1 = a disc).
    public var volume: Double = 0
    public var circularity: Double = 0
    /// Undercut faces (work frame), xyz per vertex, 3 vertices per triangle.
    public var undercutTriangles: [Float]
    /// Line of sight per face and the reach measurements (floors, holes), when asked for.
    /// nil: not requested, or the part is a mesh without exact faces.
    public var access: PartAccess? = nil

    public init(minCornerRadius: Double? = nil, minConcaveRadius: Double? = nil, undercutArea: Double = 0,
                thinnestWall: Double? = nil, depth: Double = 0, partingZ: Double? = nil, undercutTriangles: [Float] = [],
                freeformArea: Double = 0, flatArea: Double = 0, wallArea: Double = 0, steepArea: Double = 0,
                volume: Double = 0, circularity: Double = 0, access: PartAccess? = nil) {
        self.access = access
        self.partingZ = partingZ
        self.freeformArea = freeformArea
        self.flatArea = flatArea
        self.wallArea = wallArea
        self.steepArea = steepArea
        self.volume = volume
        self.circularity = circularity
        self.minCornerRadius = minCornerRadius
        self.minConcaveRadius = minConcaveRadius
        self.undercutArea = undercutArea
        self.thinnestWall = thinnestWall
        self.depth = depth
        self.undercutTriangles = undercutTriangles
    }
}


extension EngineClient {
    /// - Parameters:
    ///   - access: also measure line of sight per face, floors, holes and the holder depth
    ///     (slower; the DFM check needs it).
    ///   - nutRadius: collet nut radius for the holder depth, mm.
    public func analyse(partID: String, transform: simd_double4x4, access: Bool = false,
                        nutRadius: Double = FixtureClearance.nutRadius) throws -> PartAnalysis {
        var params: [String: Any] = ["part_id": partID, "transform": Self.rowMajor(transform)]
        if access {
            params["access"] = true
            params["nut_radius"] = nutRadius
        }
        let r = try call("analyse", params)
        guard r.result["exact"] as? Bool == true else { return PartAnalysis() }
        let triangles = r.blobs.count > 1 ? r.blobs[1].littleEndianArray(of: Float.self) : []
        return PartAnalysis(minCornerRadius: r.result["min_corner_radius"] as? Double,
                            minConcaveRadius: r.result["min_concave_radius"] as? Double,
                            undercutArea: r.result["undercut_area"] as? Double ?? 0,
                            thinnestWall: r.result["thinnest_wall"] as? Double,
                            depth: r.result["depth"] as? Double ?? 0,
                            partingZ: r.result["parting_z"] as? Double,
                            undercutTriangles: r.blobs.first?.littleEndianArray(of: Float.self) ?? [],
                            freeformArea: r.result["freeform_area"] as? Double ?? 0,
                            flatArea: r.result["flat_area"] as? Double ?? 0, wallArea: r.result["wall_area"] as? Double ?? 0,
                            steepArea: r.result["steep_area"] as? Double ?? 0, volume: r.result["volume"] as? Double ?? 0,
                            circularity: r.result["circularity"] as? Double ?? 0,
                            access: (r.result["access"] as? [String: Any]).map { PartAccess(json: $0, triangles: triangles) })
    }
}

/// Which way a tool can see each face of the finished part (work frame, tool from +Z), and the
/// measurements reach depends on. Line of sight is necessary for tool access, not sufficient:
/// the cutter, shank and collet nut still have to fit (see `DFM.reach`).
public struct PartAccess: Sendable, Equatable {
    public enum Access: String, Sendable, Equatable {
        case thisSide = "this", oppositeSide = "opposite", otherDirection = "other", noAccess = "none"
    }

    public struct Face: Sendable, Equatable {
        /// B-rep face index (TopExp_Explorer order on the transformed shape).
        public var index: Int
        public var area: Double
        /// "plane", "cylinder" or "other".
        public var kind: String
        /// "+x" … "-z": a planar face on the part's own bounding-box plane, facing out along that axis.
        public var boundary: String?
        /// That plane's work-frame coordinate along its axis.
        public var planeOffset: Double?
        public var access: Access
        /// Fraction of the face's samples with a straight line of sight, per direction ("+z", "-x", …).
        public var visible: [String: Double]
        public init(index: Int, area: Double = 0, kind: String = "plane", boundary: String? = nil,
                    planeOffset: Double? = nil, access: Access = .thisSide, visible: [String: Double] = [:]) {
            (self.index, self.area, self.kind, self.boundary) = (index, area, kind, boundary)
            (self.planeOffset, self.access, self.visible) = (planeOffset, access, visible)
        }
    }

    /// Connected faces (not on the bounding box) the tool can't see from +Z.
    public struct Region: Sendable, Equatable {
        public var faces: [Int]
        public var area: Double
        public var access: Access
        /// Axis directions that see every sample of the region (empty for `.noAccess`).
        public var directions: [String]
        public var min: SIMD3<Double>
        public var max: SIMD3<Double>
        /// The sides a tool must come from for what +Z doesn't see, in the order that covers
        /// most first, each with its share of the region and how deep that share lies from the
        /// part's outside on that side, mm. Empty: nothing seen from any side (or not measured).
        public var sides: [Side]
        /// The same when both sides are machined: the back (side B) first.
        public var sidesTwo: [Side]
        /// The region is a modelled thread (it reads blocked: its crests hide each other).
        public var thread: Thread?

        public struct Side: Sendable, Equatable {
            /// "+x", "-z", ...: the direction the tool comes from.
            public var side: String
            public var share: Double
            public var depth: Double
            public init(side: String, share: Double = 1, depth: Double) { (self.side, self.share, self.depth) = (side, share, depth) }
        }

        public struct Thread: Sendable, Equatable {
            /// The two ends along its axis, open ones (reaching the outside) first, then the
            /// shallower: how deep its far end is from that side, mm.
            public var sides: [End]
            public var major: Double
            public var minor: Double
            public var length: Double
            public struct End: Sendable, Equatable {
                public var side: String
                public var depth: Double
                public var open: Bool
                public init(side: String, depth: Double, open: Bool) { (self.side, self.depth, self.open) = (side, depth, open) }
            }
            public init(sides: [End], major: Double, minor: Double, length: Double) {
                (self.sides, self.major, self.minor, self.length) = (sides, major, minor, length)
            }
        }

        public init(faces: [Int], area: Double = 0, access: Access, directions: [String] = [],
                    min: SIMD3<Double> = .zero, max: SIMD3<Double> = .zero, sides: [Side] = [], sidesTwo: [Side]? = nil,
                    thread: Thread? = nil) {
            (self.faces, self.area, self.access, self.directions, self.min, self.max) = (faces, area, access, directions, min, max)
            (self.sides, self.sidesTwo, self.thread) = (sides, sidesTwo ?? sides, thread)
        }
    }

    /// An up-facing flat floor below the part top that the tool sees from +Z.
    public struct Floor: Sendable, Equatable {
        public var face: Int
        public var z: Double
        public var area: Double
        /// Largest circle that fits in the floor, mm (the widest cutter that reaches all of it).
        public var width: Double
        /// Highest finished material within 1 mm around the floor, above it, mm.
        public var wallDepth: Double
        /// Shortest stick-out that keeps the collet nut 1 mm above the part with the tip on this floor.
        public var holderDepth: Double
        public var min: SIMD3<Double>
        public var max: SIMD3<Double>
        /// Share of the ring round the floor where a wall rises (1: closed pocket, 0: open
        /// step); nil from an engine that doesn't measure it.
        public var enclosed: Double?
        public init(face: Int, z: Double, area: Double = 0, width: Double, wallDepth: Double, holderDepth: Double,
                    min: SIMD3<Double> = .zero, max: SIMD3<Double> = .zero, enclosed: Double? = nil) {
            (self.face, self.z, self.area, self.width) = (face, z, area, width)
            (self.wallDepth, self.holderDepth, self.min, self.max, self.enclosed) = (wallDepth, holderDepth, min, max, enclosed)
        }
    }

    public struct Hole: Sendable, Equatable {
        public var faces: [Int]
        public var x: Double
        public var y: Double
        public var diameter: Double
        public var zTop: Double
        public var zBottom: Double
        public var through: Bool
        public var access: Access
        public var holderDepth: Double
        public var length: Double { zTop - zBottom }
        public init(faces: [Int], x: Double = 0, y: Double = 0, diameter: Double, zTop: Double, zBottom: Double,
                    through: Bool = false, access: Access = .thisSide, holderDepth: Double) {
            (self.faces, self.x, self.y, self.diameter, self.zTop) = (faces, x, y, diameter, zTop)
            (self.zBottom, self.through, self.access, self.holderDepth) = (zBottom, through, access, holderDepth)
        }
    }

    public var faces: [Face]
    public var regions: [Region]
    public var floors: [Floor]
    public var holes: [Hole]
    /// The finished part's bounds, work frame.
    public var partMin: SIMD3<Double>
    public var partMax: SIMD3<Double>
    /// Face triangles, work frame: xyz per vertex, 9 floats per triangle.
    public var triangles: [Float]
    /// Face index → its triangles (triangle indices into `triangles`).
    public var faceTriangles: [Int: Range<Int>]

    public init(faces: [Face] = [], regions: [Region] = [], floors: [Floor] = [], holes: [Hole] = [],
                partMin: SIMD3<Double> = .zero, partMax: SIMD3<Double> = .zero,
                triangles: [Float] = [], faceTriangles: [Int: Range<Int>] = [:]) {
        (self.faces, self.regions, self.floors, self.holes) = (faces, regions, floors, holes)
        (self.partMin, self.partMax, self.triangles, self.faceTriangles) = (partMin, partMax, triangles, faceTriangles)
    }

    /// The engine's "access" result; missing keys decode as empty.
    public init(json j: [String: Any], triangles: [Float] = []) {
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? -1 }
        func vec(_ v: Any?) -> SIMD3<Double> {
            let a = (v as? [Any])?.compactMap(num) ?? []
            return a.count == 3 ? SIMD3(a[0], a[1], a[2]) : .zero
        }
        func ints(_ v: Any?) -> [Int] { (v as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? [] }
        func access(_ v: Any?) -> Access { (v as? String).flatMap(Access.init(rawValue:)) ?? .noAccess }
        func list(_ key: String) -> [[String: Any]] { j[key] as? [[String: Any]] ?? [] }
        faces = list("faces").map { f in
            Face(index: int(f["index"]), area: num(f["area"]) ?? 0, kind: f["kind"] as? String ?? "other",
                 boundary: f["boundary"] as? String, planeOffset: num(f["plane_offset"]), access: access(f["access"]),
                 visible: (f["visible"] as? [String: Any] ?? [:]).compactMapValues(num))
        }
        regions = list("regions").map { r in
            func sides(_ v: Any?) -> [Region.Side] {
                (v as? [[String: Any]] ?? []).compactMap { s -> Region.Side? in
                    guard let side = s["side"] as? String, let depth = num(s["depth"]) else { return nil }
                    return Region.Side(side: side, share: num(s["share"]) ?? 0, depth: depth)
                }
            }
            let thread = (r["thread"] as? [String: Any]).map { t in
                Region.Thread(sides: (t["sides"] as? [[String: Any]] ?? []).compactMap { e in
                    guard let side = e["side"] as? String, let depth = num(e["depth"]) else { return nil }
                    return Region.Thread.End(side: side, depth: depth, open: e["open"] as? Bool ?? false)
                }, major: num(t["major"]) ?? 0, minor: num(t["minor"]) ?? 0, length: num(t["length"]) ?? 0)
            }
            return Region(faces: ints(r["faces"]), area: num(r["area"]) ?? 0, access: access(r["access"]),
                          directions: r["directions"] as? [String] ?? [], min: vec(r["min"]), max: vec(r["max"]),
                          sides: sides(r["sides"]), sidesTwo: r["sides_two"] == nil ? nil : sides(r["sides_two"]), thread: thread)
        }
        floors = list("floors").map { f in
            Floor(face: int(f["face"]), z: num(f["z"]) ?? 0, area: num(f["area"]) ?? 0, width: num(f["width"]) ?? 0,
                  wallDepth: num(f["wall_depth"]) ?? 0, holderDepth: num(f["holder_depth"]) ?? 0,
                  min: vec(f["min"]), max: vec(f["max"]), enclosed: num(f["enclosed"]))
        }
        holes = list("holes").map { h in
            Hole(faces: ints(h["faces"]), x: num(h["x"]) ?? 0, y: num(h["y"]) ?? 0, diameter: num(h["diameter"]) ?? 0,
                 zTop: num(h["z_top"]) ?? 0, zBottom: num(h["z_bottom"]) ?? 0, through: h["through"] as? Bool ?? false,
                 access: access(h["access"]), holderDepth: num(h["holder_depth"]) ?? 0)
        }
        partMin = vec(j["part_min"])
        partMax = vec(j["part_max"])
        self.triangles = triangles
        var ranges: [Int: Range<Int>] = [:]
        for row in j["face_triangles"] as? [Any] ?? [] {
            let v = ints(row)
            guard v.count == 3, v[1] >= 0, v[2] >= 0 else { continue }
            ranges[v[0]] = v[1] ..< v[1] + v[2]
        }
        faceTriangles = ranges
    }

    /// The triangles of these faces (work frame, 9 floats each), for highlighting.
    public func triangles(forFaces ids: [Int]) -> [Float] {
        var out: [Float] = []
        var seen = Set<Int>()
        for id in ids where seen.insert(id).inserted {
            guard let r = faceTriangles[id] else { continue }
            let lo = Swift.min(r.lowerBound * 9, triangles.count), hi = Swift.min(r.upperBound * 9, triangles.count)
            out += triangles[lo ..< hi]
        }
        return out
    }

    /// Work-frame bounds of these faces' triangles; nil when none are known.
    public func bounds(forFaces ids: [Int]) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        let t = triangles(forFaces: ids)
        guard t.count >= 3 else { return nil }
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for k in stride(from: 0, to: t.count - 2, by: 3) {
            let p = SIMD3(Double(t[k]), Double(t[k + 1]), Double(t[k + 2]))
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    public func face(_ index: Int) -> Face? { faces.first { $0.index == index } }
    /// Faces on the part's bounding box, by side ("+x" … "-z").
    public func boundaryFaces(_ side: String) -> [Face] { faces.filter { $0.boundary == side } }
}
