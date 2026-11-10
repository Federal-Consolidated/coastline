import Foundation

/// Talks to the Python geometry/CAM engine (`engine/`, `python -m coastline_engine.server`).
///
/// Frame layout, both directions (see `engine/coastline_engine/rpc.py`):
///   u32 big-endian JSON length · JSON header · blobs (lengths listed in header["blobs"])
/// Blobs carry little-endian float32/uint32 arrays (meshes, toolpaths).
public actor EngineClient {
    public struct EngineError: Error, CustomStringConvertible {
        public let type: String
        public let message: String
        public var description: String { "\(type): \(message)" }
        public init(type: String, message: String) { (self.type, self.message) = (type, message) }
    }

    public struct Response: @unchecked Sendable {
        public let result: [String: Any]
        public let blobs: [Data]
    }

    private let process = Process()
    private let toEngine = Pipe()
    private let fromEngine = Pipe()
    private let errors = Pipe()
    private var nextID = 1
    /// The engine's stderr, drained continuously: an unread pipe fills up (64 KB) and blocks
    /// the engine mid-computation. The last 64 KB are kept for error messages.
    private let log = LogTail()

    /// - Parameters:
    ///   - python: the engine's interpreter (`engine/.venv/bin/python`, or the bundled one).
    ///   - engineDir: the `engine/` folder (working directory, so `coastline_engine` imports).
    public init(python: URL, engineDir: URL) throws {
        process.executableURL = python
        process.arguments = ["-m", "coastline_engine.server"]
        process.currentDirectoryURL = engineDir
        process.standardInput = toEngine
        process.standardOutput = fromEngine
        process.standardError = errors
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        let tail = log
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Empty at end of file (the engine stopped): stop reading, or this is called
            // again at once, forever (a whole core per stopped engine).
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
        try process.run()
    }

    /// Finds the engine next to the repo during development: `<root>/engine/.venv/bin/python`.
    /// A standalone app's root has its own interpreter instead: `<root>/python/bin/python3.11`.
    public static func development(repoRoot: URL) throws -> EngineClient {
        let engine = repoRoot.appendingPathComponent("engine")
        let bundled = repoRoot.appendingPathComponent("python/bin/python3.11")
        let python = FileManager.default.fileExists(atPath: bundled.path) ? bundled : engine.appendingPathComponent(".venv/bin/python")
        return try EngineClient(python: python, engineDir: engine)
    }

    deinit { process.terminate() }

    /// False once the engine process has exited (a crash in a native library ends it).
    public func isRunning() -> Bool { process.isRunning }

    /// Stops the engine at once, even in the middle of a long call (which then throws
    /// EngineExited). Not actor-isolated: the actor is busy waiting for that call.
    public nonisolated func terminate() {
        process.terminate()
    }

    /// Sends one request and waits for its response. Requests are serialised: the engine is
    /// single-threaded and answers in order.
    public func call(_ method: String, _ params: [String: Any] = [:], blobs: [Data] = []) throws -> Response {
        let id = nextID
        nextID += 1
        let header: [String: Any] = ["id": id, "method": method, "params": params, "blobs": blobs.map(\.count)]
        let json = try JSONSerialization.data(withJSONObject: header)
        var frame = Data()
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(json.count).bigEndian, Array.init))
        frame.append(json)
        blobs.forEach { frame.append($0) }
        try toEngine.fileHandleForWriting.write(contentsOf: frame)

        let input = fromEngine.fileHandleForReading
        let lengthBytes = try readExactly(input, 4)
        let length = lengthBytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        let responseHeader = try JSONSerialization.jsonObject(with: try readExactly(input, Int(length))) as? [String: Any] ?? [:]
        let blobLengths = responseHeader["blobs"] as? [Int] ?? []
        let outBlobs = try blobLengths.map { try readExactly(input, $0) }
        if let error = responseHeader["error"] as? [String: Any] {
            throw EngineError(type: error["type"] as? String ?? "Error", message: error["message"] as? String ?? "")
        }
        return Response(result: responseHeader["result"] as? [String: Any] ?? [:], blobs: outBlobs)
    }

    private func readExactly(_ handle: FileHandle, _ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw EngineError(type: "EngineExited", message: "The engine stopped responding.\n\(log.text.suffix(2000))")
            }
            data.append(chunk)
        }
        return data
    }

    public func shutdown() {
        try? toEngine.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

/// Thread-safe ring of the engine's recent log output.
final class LogTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) {
        lock.lock()
        data.append(d)
        if data.count > 65_536 { data.removeFirst(data.count - 65_536) }
        lock.unlock()
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// An indexed triangle mesh (mm) as sent by the engine.
public struct MeshData: Sendable {
    public var vertices: [Float]  // xyz xyz …
    public var normals: [Float]
    public var indices: [UInt32]
    public var boundsMin: Vec3
    public var boundsMax: Vec3
    public var exact: Bool
    public var faceCount: Int
    /// The engine's handle for exact queries (measuring, CAM). Empty for non-part meshes.
    public var partID: String = ""
    public var warnings: [String] = []

    public init(vertices: [Float], normals: [Float], indices: [UInt32], boundsMin: Vec3, boundsMax: Vec3,
                exact: Bool, faceCount: Int, partID: String = "", warnings: [String] = []) {
        self.vertices = vertices; self.normals = normals; self.indices = indices
        self.boundsMin = boundsMin; self.boundsMax = boundsMax; self.exact = exact
        self.faceCount = faceCount; self.partID = partID; self.warnings = warnings
    }

    public var vertexCount: Int { vertices.count / 3 }
    public var triangleCount: Int { indices.count / 3 }
    public var size: Vec3 { Vec3(boundsMax.x - boundsMin.x, boundsMax.y - boundsMin.y, boundsMax.z - boundsMin.z) }
}

extension EngineClient {
    /// Import exact STEP occurrences using an audited mechanical definition. Unlike the
    /// legacy solid list, these IDs never depend on flattened solid traversal order.
    public func fixtureAssembly(partID: String, definition: FixtureAssemblyDefinition) throws -> [FixtureAssemblyPart] {
        try definition.validate()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition))
        let response = try call("fixture_assembly", ["part_id": partID, "definition": object])
        guard let metadata = response.result["parts"] as? [[String: Any]], !metadata.isEmpty,
              response.blobs.count == metadata.count * 3 else {
            throw EngineError(type: "Fixture", message: "The vetted fixture did not return its exact CAD bodies.")
        }
        return try metadata.enumerated().map { index, item in
            guard let component = item["component_id"] as? String, let path = item["entity_path"] as? String,
                  let solidIndex = item["solid_index"] as? Int, solidIndex >= 0,
                  let lo = item["bounds_min"] as? [Double], lo.count == 3,
                  let hi = item["bounds_max"] as? [Double], hi.count == 3,
                  (lo + hi).allSatisfy(\.isFinite),
                  let faces = item["face_count"] as? Int, faces > 0,
                  (0..<3).allSatisfy({ response.blobs[index * 3 + $0].count % 4 == 0 }) else {
                throw EngineError(type: "Fixture", message: "The fixture engine returned invalid CAD body metadata.")
            }
            let mesh = MeshData(vertices: response.blobs[index * 3].littleEndianArray(of: Float.self),
                                normals: response.blobs[index * 3 + 1].littleEndianArray(of: Float.self),
                                indices: response.blobs[index * 3 + 2].littleEndianArray(of: UInt32.self),
                                boundsMin: Vec3(lo[0], lo[1], lo[2]), boundsMax: Vec3(hi[0], hi[1], hi[2]),
                                exact: true, faceCount: faces, partID: partID)
            return FixtureAssemblyPart(componentID: component, entityPath: path, solidIndex: solidIndex, mesh: mesh)
        }
    }

    public func fixtureSolids(partID: String) throws -> [MeshData] {
        let response = try call("fixture_solids", ["part_id": partID])
        let metadata = response.result["solids"] as? [[String: Any]] ?? []
        guard !metadata.isEmpty, response.blobs.count == 3 * metadata.count else {
            throw EngineError(type: "Fixture", message: "The fixture does not contain valid closed solids.")
        }
        return metadata.enumerated().map { index, item in
            let lo = item["bounds_min"] as? [Double] ?? [0, 0, 0], hi = item["bounds_max"] as? [Double] ?? [0, 0, 0]
            return MeshData(vertices: response.blobs[index * 3].littleEndianArray(of: Float.self),
                            normals: response.blobs[index * 3 + 1].littleEndianArray(of: Float.self),
                            indices: response.blobs[index * 3 + 2].littleEndianArray(of: UInt32.self),
                            boundsMin: Vec3(lo[0], lo[1], lo[2]), boundsMax: Vec3(hi[0], hi[1], hi[2]), exact: true,
                            faceCount: item["face_count"] as? Int ?? 0, partID: partID, warnings: [])
        }
    }

    /// Imports STEP / IGES / 3DM. Units are converted to mm by the engine.
    public func importPart(_ url: URL, linearDeflection: Double = 0.01) throws -> MeshData {
        let r = try call("import_part", ["path": url.path, "linear_deflection": linearDeflection])
        func vec(_ key: String) -> Vec3 {
            let a = r.result[key] as? [Double] ?? [0, 0, 0]
            return Vec3(a[0], a[1], a[2])
        }
        return MeshData(
            vertices: r.blobs[0].littleEndianArray(of: Float.self),
            normals: r.blobs[1].littleEndianArray(of: Float.self),
            indices: r.blobs[2].littleEndianArray(of: UInt32.self),
            boundsMin: vec("bounds_min"),
            boundsMax: vec("bounds_max"),
            exact: r.result["exact"] as? Bool ?? false,
            faceCount: r.result["face_count"] as? Int ?? 0,
            partID: r.result["part_id"] as? String ?? "",
            warnings: r.result["warnings"] as? [String] ?? []
        )
    }

    /// The machine assembly as display meshes grouped by motion axis (cached by the engine).
    public func machineModel(_ step: URL) throws -> MachineModel {
        let r = try call("machine_model", ["path": step.path])
        let meta = r.result["parts"] as? [[String: Any]] ?? []
        var parts: [MachineModel.Part] = []
        for (i, m) in meta.enumerated() {
            let v = r.blobs[3 * i].littleEndianArray(of: Float.self)
            let n = r.blobs[3 * i + 1].littleEndianArray(of: Float.self)
            let t = r.blobs[3 * i + 2].littleEndianArray(of: UInt32.self)
            let c = m["color"] as? [Double] ?? [0.3, 0.3, 0.3]
            parts.append(.init(group: m["group"] as? String ?? "static", role: m["role"] as? String ?? "",
                               color: SIMD3(Float(c[0]), Float(c[1]), Float(c[2])),
                               mesh: MeshData(vertices: v, normals: n, indices: t, boundsMin: .zero, boundsMax: .zero,
                                              exact: false, faceCount: 0)))
        }
        let nose = r.result["spindle_nose"] as? [Double] ?? [0, 0, 0]
        let pose = r.result["model_pose"] as? [Double] ?? [-1.25, -146.5, -54.0]
        return MachineModel(parts: parts, spindleNose: Vec3(nose[0], nose[1], nose[2]),
                            tableTopX: r.result["table_top_x"] as? Double ?? 0, modelPose: Vec3(pose[0], pose[1], pose[2]),
                            tSlotZ: r.result["tslot_z"] as? [Double] ?? [-53.5, -13.4])
    }

    /// Geometry for a reviewed package, kept at its authored reference pose. Component IDs
    /// are motion groups; the caller applies MachineDefinition.worldTranslation to each.
    /// This does not select a machine or send controller commands.
    public func machineProfileParts(_ manifest: URL, cacheDirectory: URL? = nil) throws -> [MachineModel.Part] {
        var parameters: [String: Any] = ["manifestPath": manifest.path]
        if let cacheDirectory { parameters["cache_dir"] = cacheDirectory.path }
        let r = try call("machine_model", parameters)
        guard let meta = r.result["parts"] as? [[String: Any]], !meta.isEmpty,
              r.blobs.count == meta.count * 3, r.blobs.allSatisfy({ $0.count % 4 == 0 }) else {
            throw MachineDefinitionError("The machine profile returned incomplete model geometry.")
        }
        return try meta.enumerated().map { i, m in
            let v = r.blobs[3 * i].littleEndianArray(of: Float.self)
            let n = r.blobs[3 * i + 1].littleEndianArray(of: Float.self)
            let t = r.blobs[3 * i + 2].littleEndianArray(of: UInt32.self)
            guard let group = m["group"] as? String, !group.isEmpty,
                  let c = m["color"] as? [Double], c.count == 3, c.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  !v.isEmpty, v.count % 3 == 0, n.count == v.count,
                  !t.isEmpty, t.count % 3 == 0, t.allSatisfy({ Int($0) < v.count / 3 }),
                  v.allSatisfy(\.isFinite), n.allSatisfy(\.isFinite) else {
                throw MachineDefinitionError("The machine profile returned invalid mesh data.")
            }
            return MachineModel.Part(group: group, role: m["role"] as? String ?? "",
                                     color: SIMD3(Float(c[0]), Float(c[1]), Float(c[2])),
                                     mesh: MeshData(vertices: v, normals: n, indices: t,
                                                    boundsMin: .zero, boundsMax: .zero, exact: false, faceCount: 0))
        }
    }

    /// Describes the exact surface nearest `point` (part coordinates).
    public func faceInfo(partID: String, point: Vec3) throws -> FaceInfo {
        let r = try call("face_info", ["part_id": partID, "point": [point.x, point.y, point.z]])
        return FaceInfo(r.result)
    }
}

/// The machine assembly for the viewport. Coordinates are the machine axes (see `Setup`).
public struct MachineModel: Sendable {
    public struct Part: Sendable {
        /// Authored component ID; legacy models use "static", "x", "y" or "z".
        public var group: String
        /// "enclosure", "aluminium", "steel", "motor", …
        public var role: String
        /// Linear RGB.
        public var color: SIMD3<Float>
        public var mesh: MeshData
        public init(group: String, role: String, color: SIMD3<Float>, mesh: MeshData) {
            self.group = group; self.role = role; self.color = color; self.mesh = mesh
        }
    }
    public var parts: [Part]
    /// The collet nut face on the spindle axis, in model coordinates (mm).
    public var spindleNose: Vec3
    /// The table's top face (model X), mm.
    public var tableTopX: Double
    /// Machine coordinates (X, Y, Z) the assembly is modelled at.
    public var modelPose: Vec3
    /// T-slot centres in the table (model Z), rear first.
    public var tSlotZ: [Double] = [-53.5, -13.4]
}

/// One part of a fixture kit (kit-local frame).
public struct FixturePart: Sendable {
    /// "clamp", "spacer_u", "spacer_cube", "brick" or "eccentric".
    public var kit: String
    public var name: String
    public var role: String
    /// Linear RGB.
    public var color: SIMD3<Float>
    public var mesh: MeshData
}

/// What the engine found under a measuring click.
public struct FaceInfo: Sendable, Equatable {
    public var type: String           // plane, cylinder, cone, sphere, torus, freeform, edge, none
    public var distance: Double?
    public var normal: Vec3?
    public var radius: Double?
    public var axis: Vec3?
    public var minRadiusOfCurvature: Double?
    public var recognisedFromNURBS: Bool

    init(_ d: [String: Any]) {
        func v(_ k: String) -> Vec3? { (d[k] as? [Double]).map { Vec3($0[0], $0[1], $0[2]) } }
        type = d["type"] as? String ?? "none"
        distance = d["distance"] as? Double
        normal = v("normal")
        radius = d["radius"] as? Double ?? d["major_radius"] as? Double
        axis = v("axis")
        minRadiusOfCurvature = d["min_radius_of_curvature"] as? Double
        recognisedFromNURBS = d["recognised_from_nurbs"] as? Bool ?? false
    }

    /// "Cylinder · R 3.175 mm" style description.
    public var summary: String {
        switch type {
        case "plane": "Flat face"
        case "cylinder": "Cylinder · R \(Length.mm(radius ?? 0)) mm (⌀ \(Length.mm(2 * (radius ?? 0))))"
        case "cone": "Cone · R \(Length.mm(radius ?? 0)) mm"
        case "sphere": "Sphere · R \(Length.mm(radius ?? 0)) mm"
        case "torus": "Torus · R \(Length.mm(radius ?? 0)) mm"
        case "freeform": minRadiusOfCurvature.map { "Freeform · tightest curve R \(Length.mm($0)) mm" } ?? "Freeform surface"
        case "edge": "Edge"
        default: "No exact surface"
        }
    }
}

extension Data {
    /// Reinterprets little-endian bytes as an array (Apple Silicon is little-endian).
    /// Copies rather than binds, because blob bytes aren't guaranteed to be aligned.
    func littleEndianArray<T>(of _: T.Type) -> [T] {
        let n = count / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: n) { buffer, initialized in
            _ = copyBytes(to: buffer)
            initialized = n
        }
    }
}
