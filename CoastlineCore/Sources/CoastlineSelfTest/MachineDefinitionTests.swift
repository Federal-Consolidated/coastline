import CoastlineCore
import Foundation

private var desktopMachinePackage: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("resources/machines/desktop-cnc", isDirectory: true)
}

private func machineScratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("machine-definition-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func copiedMachinePackage(in folder: URL) throws -> URL {
    let copy = folder.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.copyItem(at: desktopMachinePackage, to: copy)
    return copy
}

private func writeDefinition(_ definition: MachineDefinition, in folder: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(definition).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
}

let machineDefinitionTests: [TestCase] = [
    TestCase(name: "desktopPackageProvesDigitalSetupAndPreservesPhysicalCalibrationTask") {
        let package = try MachineDefinitionPackage.load(from: desktopMachinePackage)
        let d = package.definition
        try expectEqual(d.id, "desktop-cnc")
        try expectEqual(d.revision, 2)
        try expectEqual(d.verification, .digital)
        try expect(d.supportsDigitalSetup)
        try expectEqual(d.validationStatus(for: .hardware), .pending)
        try expectEqual(d.validationChecks.filter { $0.status == .pending }.map(\.id), ["physical-calibration"])
        try expectEqual(d.blockingFindings.map(\.id), ["physical-calibration"])
        try expectEqual(d.postProcessorID, GRBLPost.adapterID)
        try expectEqual(d.profile.maxToolLength, 75)
        try expectEqual(d.profile.spindleRPM, 1500...8000)
        try expectEqual(d.controllerHomePosition, Vec3(-86, -0.5, -0.5))
        try expectEqual(d.controllerEnvelope.y, -241.5...0)
        try expect(package.fusionDefinitionURL != nil)
        try expect(d.evidence.contains { $0.status == .inferred })
        try expectEqual(d.components.filter { $0.isEnclosure == true }.map(\.id), ["cover"])
        try expectEqual(try d.worldTranslation(for: "cover", at: d.controllerHomePosition), .zero)
        try expectEqual(try MachineDefinitionPackage.load(from: package.manifestURL).definition, d)
    },
    TestCase(name: "tableAndNestedHeadMoveInTheirDefinedDirections") {
        let d = try MachineDefinitionPackage.load(from: desktopMachinePackage).definition
        let home = d.controllerHomePosition
        let tableID = d.components.first { $0.role == .table }!.id
        let headID = d.components.first { $0.role == .head }!.id
        let table = try d.worldTranslation(for: tableID, at: home)
        let head = try d.worldTranslation(for: headID, at: home)
        try expectEqual(table, Vec3(86, 0, 0))
        try expectEqual(head, Vec3(0, 68.5, 79.4))
        var moved = home; moved.x += 1
        try expectEqual(try d.worldTranslation(for: tableID, at: moved), Vec3(85, 0, 0))
        try expectEqual(try d.worldTranslation(for: headID, at: moved), head)
        moved = home; moved.y += 1; moved.z -= 2
        try expectEqual(try d.worldTranslation(for: headID, at: moved), Vec3(0, 69.5, 77.4))
        try expectEqual(try d.worldTranslation(for: tableID, at: moved), table)
        let frame = d.frames.first { $0.componentID == tableID }!
        let origin = try d.worldOrigin(for: frame.id, at: home)
        try expectEqual(origin.x, frame.origin.x + 86)
    },
    TestCase(name: "seatingFramePlacesAsymmetricStockWithoutPermutingItsDimensions") {
        var d = try MachineDefinitionPackage.load(from: desktopMachinePackage).definition
        let seating = d.frames.first { $0.id == "table-surface" }!
        try expectEqual(d.referenceStock?.frameID, seating.id)
        try expectEqual(d.referenceStock?.size, Vec3(203.2, 37, 50.8))
        try d.validate()
        let corners = try d.referenceStockCorners()
        try expectEqual(corners.count, 8)
        // The seating plane is world X; the long stock edge follows the slots along Y.
        try expect(abs((corners.map(\.x).max()! - corners.map(\.x).min()!) - 50.8) < 0.000001)
        try expect(abs((corners.map(\.y).max()! - corners.map(\.y).min()!) - 203.2) < 0.000001)
        try expect(abs((corners.map(\.z).max()! - corners.map(\.z).min()!) - 37) < 0.000001)
        try expectEqual(corners[0], seating.origin)
        try expectEqual(try d.worldDirection(Vec3(0, 0, 1), in: seating.id), Vec3(1, 0, 0))
        try expectEqual(try d.worldDirection(Vec3(0, 0, 1), in: "tool"), Vec3(0, 0, 1))
        let home = try d.referenceStockCorners(at: d.controllerHomePosition)
        for i in corners.indices {
            try expect(abs(home[i].x - corners[i].x - 86) < 0.000001)
            try expectEqual(home[i].y, corners[i].y)
            try expectEqual(home[i].z, corners[i].z)
        }
        var moved = d.controllerHomePosition; moved.y -= 10
        try expectEqual(try d.referenceStockCorners(at: moved), home, "Head motion must not move table-mounted stock")
        d.referenceStock!.frameID = "tool"
        try expectThrows { try d.validate() }
    },
    TestCase(name: "revisionOneWithoutCapabilityMetadataStillLoadsWithoutClaimingDigitalSetup") {
        let data = try Data(contentsOf: desktopMachinePackage.appendingPathComponent("manifest.json"))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for field in ["postProcessorID", "checks", "referenceStock"] { object.removeValue(forKey: field) }
        var components = object["components"] as! [[String: Any]]
        for i in components.indices { components[i].removeValue(forKey: "isEnclosure") }
        object["components"] = components
        object["verification"] = "draft"; object["revision"] = 1
        let d = try JSONDecoder().decode(MachineDefinition.self, from: JSONSerialization.data(withJSONObject: object))
        try d.validate()
        try expect(!d.supportsDigitalSetup)
        try expect(d.referenceStock == nil && d.postProcessorID == nil)
        try expect(d.components.allSatisfy { $0.isEnclosure == nil })
    },
    TestCase(name: "digitalReadinessDoesNotClearPhysicalCalibration") {
        var d = try MachineDefinitionPackage.load(from: desktopMachinePackage).definition
        let source = d.sources[0].id
        d.checks = [.geometry, .kinematics, .setupPlacement].map { scope in
            MachineValidationCheck(id: scope.rawValue, title: scope.rawValue, scope: scope, status: .passed,
                                   detail: "Checked against the referenced source.", sourceIDs: [source])
        }
        d.checks!.append(MachineValidationCheck(id: "calibration", title: "Measure the installed machine", scope: .hardware,
                                               status: .pending, detail: "No physical measurements have been recorded.",
                                               sourceIDs: [source], action: "Record table and spindle references after homing."))
        try d.validate()
        try expect(d.supportsDigitalSetup)
        try expectEqual(d.validationStatus(for: .hardware), .pending)
        d.checks![1].status = .failed; d.checks![1].action = "Correct the axis direction."
        try expect(!d.supportsDigitalSetup)
        try expectEqual(d.validationStatus(for: .kinematics), .failed)
        d.checks![3].action = nil
        try expectThrows { try d.validate() }
    },
    TestCase(name: "contrastingVerticalMachineNeedsNoDesktopMotionAssumptions") {
        var d = try MachineDefinitionPackage.load(from: desktopMachinePackage).definition
        d.id = "vertical-test"; d.name = "Vertical test machine"
        let x = d.components.firstIndex { $0.axis?.coordinate == .x }!
        let y = d.components.firstIndex { $0.axis?.coordinate == .y }!
        let z = d.components.firstIndex { $0.axis?.coordinate == .z }!
        let table = d.components.firstIndex { $0.role == .table }!
        let head = d.components.firstIndex { $0.role == .head }!
        d.components[x].parentID = nil; d.components[x].axis!.direction = Vec3(1, 0, 0)
        d.components[y].parentID = d.components[x].id
        d.components[z].parentID = d.components[y].id
        d.components[table].parentID = nil
        d.components[head].parentID = d.components[z].id
        try d.validate()
        let position = Vec3(-10, -50, -30)
        try expectEqual(try d.worldTranslation(for: d.components[table].id, at: position), .zero)
        let translation = try d.worldTranslation(for: d.components[head].id, at: position)
        try expectEqual(translation.x, -10)
        try expectEqual(translation.y, 19)
        try expect(abs(translation.z - 49.9) < 0.00001)
    },
    TestCase(name: "invalidKinematicsCannotBecomeAValidPackage") {
        let valid = try MachineDefinitionPackage.load(from: desktopMachinePackage).definition
        var d = valid; d.schemaVersion = 2
        try expectThrows { try d.validate() }
        d = valid; d.controller = "unsupported"
        try expectThrows { try d.validate() }
        d = valid; d.components[0].parentID = d.components[0].id
        try expectThrows { try d.validate() }
        let x = valid.components.firstIndex { $0.axis?.coordinate == .x }!
        d = valid; d.components[x].axis!.controllerScale = 0
        try expectThrows { try d.validate() }
        d = valid; d.components[x].axis!.modelHome = 10000
        try expectThrows { try d.validate() }
        d = valid; d.components[x].axis!.direction = Vec3(.nan, 0, 0)
        try expectThrows { try d.validate() }
        d = valid; d.profile.homePosition = Vec3(-0.5, -0.5, -0.5)
        try expectThrows { try d.validate() }
        d = valid; d.frames[0].zDirection = d.frames[0].xDirection
        try expectThrows { try d.validate() }
    },
    TestCase(name: "installCopiesAssetsAndRejectsChangedRevision") {
        let scratch = try machineScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = try copiedMachinePackage(in: scratch)
        let library = scratch.appendingPathComponent("library")
        let installed = try MachineDefinitionPackage.install(from: source, into: library)
        try expect(installed.rootURL.path.hasPrefix(library.path + "/"))
        try expectEqual(try MachineDefinitionPackage.install(from: source, into: library).rootURL, installed.rootURL)
        var changed = installed.definition; changed.name = "Different machine, same revision"
        try writeDefinition(changed, in: source)
        try expectThrows { _ = try MachineDefinitionPackage.install(from: source, into: library) }
        try FileManager.default.removeItem(at: source)
        try expectEqual(try MachineDefinitionPackage.load(from: installed.rootURL).definition, installed.definition)
    },
    TestCase(name: "numericHeadroomRejectsFiniteValuesThatBreakTheRenderer") {
        let valid = try MachineDefinitionPackage.load(from: desktopMachinePackage).definition
        let excessive = MachineDefinition.maximumCoordinateMagnitude * 2
        var d = valid; d.frames[0].origin.x = excessive
        try expectThrows { try d.validate() }
        let x = valid.components.firstIndex { $0.axis?.coordinate == .x }!
        d = valid; d.components[x].axis!.controllerOffset = excessive
        try expectThrows { try d.validate() }
        d = valid; d.mountingInterfaces[0].slots[0].length = excessive
        try expectThrows { try d.validate() }
        let head = valid.components.first { $0.role == .head }!.id
        try expectThrows { _ = try valid.worldTranslation(for: head, at: Vec3(0, 1e100, 0)) }
        // The limit is numerical, not a plausible physical working envelope.
        d = valid; d.frames[0].origin.x = 1e9
        try d.validate()
        d = valid; d.components[0].modelEntities = ["00/1"]
        try expectThrows { try d.validate() }
    },
    TestCase(name: "hashMismatchAndPathEscapesAreRejected") {
        let scratch = try machineScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = try copiedMachinePackage(in: scratch)
        let valid = try MachineDefinitionPackage.load(from: source).definition
        var d = valid; d.assets[0].sha256 = String(repeating: "0", count: 64)
        try writeDefinition(d, in: source)
        try expectThrows { _ = try MachineDefinitionPackage.load(from: source) }
        for path in ["../machine.step", "/tmp/machine.step", "models/../../machine.step", "models\\machine.step"] {
            d = valid; d.assets[d.assets.firstIndex { $0.role == .geometry }!].path = path
            try writeDefinition(d, in: source)
            try expectThrows { _ = try MachineDefinitionPackage.load(from: source) }
        }
    },
    TestCase(name: "symlinkAssetsAndOversizedFilesAreRejected") {
        let scratch = try machineScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = try copiedMachinePackage(in: scratch)
        let package = try MachineDefinitionPackage.load(from: source)
        let original = scratch.appendingPathComponent("outside.step")
        try FileManager.default.moveItem(at: package.geometryURL, to: original)
        try FileManager.default.createSymbolicLink(at: package.geometryURL, withDestinationURL: original)
        try expectThrows { _ = try MachineDefinitionPackage.load(from: source) }
        try FileManager.default.removeItem(at: package.geometryURL)
        try Data("STEP".utf8).write(to: package.geometryURL)
        let handle = try FileHandle(forWritingTo: package.geometryURL)
        try handle.truncate(atOffset: UInt64(MachineDefinitionPackage.maximumAssetBytes + 1))
        try handle.close()
        try expectThrows { _ = try MachineDefinitionPackage.load(from: source) }
    },
    TestCase(name: "homeIsExplicitAndLegacyProfilesStillDecode") {
        let standard = MachineProfile.standard
        try expectEqual(standard.toolChangeWaypoints.first, SIMD3(-86, -0.5, -1))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(standard)) as! [String: Any]
        object.removeValue(forKey: "homePosition")
        let legacy = try JSONDecoder().decode(MachineProfile.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(legacy.homePosition == nil)
        try expectEqual(legacy.travel, standard.travel)
        try expectEqual(legacy.spindleRPM, standard.spindleRPM)
    },
]
