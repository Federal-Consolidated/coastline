import CoastlineCore
import Foundation
import simd

private func engine() throws -> EngineClient {
    let python = repoRoot.appendingPathComponent("engine/.venv/bin/python")
    guard FileManager.default.fileExists(atPath: python.path) else {
        throw Skip(reason: "engine venv missing; run `cd engine && uv sync`")
    }
    return try EngineClient.development(repoRoot: repoRoot)
}

/// Runs an async body from the synchronous test harness.
private func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}

private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

let engineTests: [TestCase] = [
    TestCase(name: "vettedFixtureAssemblyIdentityAndJointEndpointsAgreeAcrossRPC") {
        let bundle = repoRoot.appendingPathComponent("resources/fixtures/bookends")
        let definition = try JSONDecoder().decode(FixtureAssemblyDefinition.self,
            from: Data(contentsOf: bundle.appendingPathComponent("definition.json")))
        let e = try engine()
        let parts = try blocking {
            let mesh = try await e.importPart(bundle.appendingPathComponent("assembly.step"))
            return try await e.fixtureAssembly(partID: mesh.partID, definition: definition)
        }
        try expectEqual(parts.count, 15)
        try expectEqual(parts.filter { $0.componentID == "fixed-end" }.count, 7)
        try expectEqual(parts.filter { $0.componentID == "clamp-end" }.count, 7)
        try expectEqual(parts.filter { $0.componentID == "pressure-screw" }.map(\.entityPath), ["10/0"])
        let geometry = try LibraryFixtureGeometry(parts: parts, definition: definition)
        let source = try unwrap(parts.first { $0.componentID == "pressure-screw" })
        for extensionMM in [0.0, 4.0, 15.0] {
            var profile = FixturePlanningProfile()
            profile.assemblyState = .init(jointValues: ["fixed-slide": -3, "clamp-slide": 6, "pressure-extension": extensionMM])
            try geometry.validate(profile: profile)
            let bounds = geometry.bounds(profile: profile, componentID: "pressure-screw")
            let translationY = 6 - (extensionMM - 4)
            try expect(abs(bounds.min.y - source.mesh.boundsMin.y - translationY) < 1e-7)
            try expect(abs(bounds.max.y - source.mesh.boundsMax.y - translationY) < 1e-7)
            for (index, part) in parts.enumerated() where part.componentID != "pressure-screw" {
                let point = geometry.solidTransform(index, profile: profile) * SIMD4<Double>(0, 0, 0, 1)
                try expect(abs(point.y - (part.componentID == "fixed-end" ? -3 : 6)) < 1e-9)
            }
        }
    },
    TestCase(name: "pingReportsVersions") {
        let e = try engine()
        let r = try blocking { try await e.call("ping") }
        try expectEqual(r.result["engine"] as? String, "0.1.0")
    },
    TestCase(name: "machineProfileGeometryAndMotionAgreeAcrossRPC") {
        let package = try MachineDefinitionPackage.load(from: repoRoot.appendingPathComponent("resources/machines/desktop-cnc"))
        let definition = package.definition, manifest = package.manifestURL
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("coastline-machine-rpc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let e = try engine()
        let parts = try blocking { try await e.machineProfileParts(manifest, cacheDirectory: cache) }
        try expectEqual(Set(parts.map(\.group)), Set(["base", "table", "y", "z", "head", "cover"]))
        // The renderer merges solids sharing a material; source coverage is checked by the CAD audit.
        try expect(parts.contains { $0.group == "cover" && $0.mesh.triangleCount > 0 })
        let componentIDs = Set(definition.components.map(\.id))
        try expect(parts.allSatisfy { componentIDs.contains($0.group) })
        let planning = try MachinePlanningGeometry(definition: definition, parts: parts)
        try expect(abs(planning.supportBounds.minimum.x - 15.865) < 0.001)
        try expect(abs(planning.supportBounds.minimum.y - (-389.422758)) < 0.01,
                   "Actual support bounds: \(planning.supportBounds)")
        try expect(abs(planning.supportBounds.maximum.y - (-84.422758)) < 0.01)
        try expect(abs(planning.supportBounds.minimum.z - 54.913594) < 0.01)
        try expect(abs(planning.supportBounds.maximum.z - 129.843594) < 0.01)
        try expect(abs(planning.tableBounds.size.y - 385) < 0.01)
        try expect(abs(planning.model.tableTopX - planning.tableBounds.minimum.x - 14.604864) < 0.01)
        try expectEqual(planning.model.modelPose, Vec3(0, -69, -79.9))
        try expectEqual(planning.model.spindleNose, Vec3(105.43, -176.8, 112.26))
        // Stock past the far edge of the 74.9 mm table, swept over the travel: the enclosure's
        // panel 57 mm behind it stops any size of stock; without the enclosure nothing does.
        let centre = (planning.supportBounds.minimum.y + planning.supportBounds.maximum.y) / 2
        for (h, w) in [(50.8, 50.8), (20.0, 80.0), (80.0, 150.0)] {
            let room = try planning.roomBehindTable(height: h, width: w, centreY: centre)
            try expect(abs(room.distance - 56.96) < 0.1 && room.by == "cover", "\(h) x \(w): \(room)")
            let open = try planning.roomBehindTable(height: h, width: w, centreY: centre, skip: ["cover"])
            try expect(open.distance == 1000 && open.by == nil, "\(h) x \(w) without the enclosure: \(open)")
        }
        try expect(planning.isEnclosure(componentID: "cover"))
        guard let table = parts.first(where: { $0.group == "table" && $0.role == "aluminium" }) else {
            throw TestFailure(description: "The profile table geometry is missing.")
        }
        let vertices = table.mesh.vertices
        let xs = stride(from: 0, to: vertices.count, by: 3).map { vertices[$0] }
        let ys = stride(from: 1, to: vertices.count, by: 3).map { vertices[$0] }
        // The source STEP is in cm. Its known table dimensions must reach Swift as mm exactly once.
        try expect(abs(Double(xs.max()!) - 15.865) < 0.01)
        try expect(abs(Double(ys.max()! - ys.min()!) - 385) < 0.01)
        for position in [definition.controllerHomePosition, Vec3(0, -69, -79.9), Vec3(-42, -103, -38)] {
            let coordinates = [position.x, position.y, position.z]
            let response = try blocking {
                try await e.call("machine_model", ["manifestPath": manifest.path, "machinePosition": coordinates, "cache_dir": cache.path])
            }
            guard let translations = response.result["group_translations"] as? [String: [Double]],
                  let metadata = response.result["profile"] as? [String: Any] else {
                throw TestFailure(description: "The machine RPC omitted its profile or transforms.")
            }
            try expectEqual(metadata["id"] as? String, definition.id)
            try expectEqual(metadata["revision"] as? Int, definition.revision)
            try expectEqual(metadata["verification"] as? String, "digital")
            for component in definition.components {
                guard let actual = translations[component.id], actual.count == 3 else {
                    throw TestFailure(description: "The machine RPC omitted component \(component.id).")
                }
                let expected = try definition.worldTranslation(for: component.id, at: position)
                try expect(abs(actual[0] - expected.x) < 1e-9 && abs(actual[1] - expected.y) < 1e-9
                           && abs(actual[2] - expected.z) < 1e-9, "Swift/Python transform disagreement for \(component.id)")
            }
        }
    },
    TestCase(name: "importStepReturnsMeshInMillimetres") {
        let e = try engine()
        let url = repoRoot.appendingPathComponent("resources/fixtures/universal_clamp_v96.step")
        let mesh = try blocking { try await e.importPart(url) }
        try expect(mesh.exact && mesh.triangleCount > 1000)
        try expectEqual(mesh.normals.count, mesh.vertices.count)
        try expect(mesh.indices.allSatisfy { Int($0) < mesh.vertexCount })
        let size = [mesh.size.x, mesh.size.y, mesh.size.z].sorted()
        try expect(abs(size[0] - 19.1) < 0.5 && abs(size[2] - 80.6) < 0.5, "clamp size \(size)")
        let solids = try blocking { try await e.fixtureSolids(partID: mesh.partID) }
        try expect(!solids.isEmpty, "fixture solids must travel through the engine RPC")
        for solid in solids {
            try expect(solid.exact && solid.faceCount > 0 && solid.triangleCount > 0)
            try expectEqual(solid.normals.count, solid.vertices.count)
            try expect(solid.indices.allSatisfy { Int($0) < solid.vertexCount })
        }
    },
    TestCase(name: "engineErrorsAreThrownAndEngineSurvives") {
        let e = try engine()
        try expectThrows { _ = try blocking { try await e.importPart(URL(fileURLWithPath: "/nope.obj")) } }
        let r = try blocking { try await e.call("ping") }
        try expect(r.result["engine"] != nil)
    },
    TestCase(name: "exactMeasuringThroughTheClient") {
        let e = try engine()
        let url = repoRoot.appendingPathComponent("resources/samples/pendant.step")
        let mesh = try blocking { try await e.importPart(url) }
        try expect(!mesh.partID.isEmpty)
        // Just outside the pendant's rim (R 15) and on the bail hole (R 1.2).
        let rim = try blocking { try await e.faceInfo(partID: mesh.partID, point: Vec3(0, -15.2, 2)) }
        try expectEqual(rim.type, "cylinder")
        try expect(abs((rim.radius ?? 0) - 15) < 1e-6, "rim radius \(String(describing: rim.radius))")
        let hole = try blocking { try await e.faceInfo(partID: mesh.partID, point: Vec3(0, 12.69, 2)) }
        try expect(abs((hole.radius ?? 0) - 1.2) < 1e-6)
        try expect(hole.summary.contains("2.4") || hole.summary.contains("2,4"))
    },
    TestCase(name: "rhinoFileImportsExactly") {
        let e = try engine()
        let mesh = try blocking { try await e.importPart(repoRoot.appendingPathComponent("resources/samples/ring_blank.3dm")) }
        try expect(mesh.exact, "3dm should be exact NURBS")
        try expect(abs(mesh.size.x - 21) < 1e-3 && abs(mesh.size.z - 13) < 1e-3, "\(mesh.size)")
    },
]
