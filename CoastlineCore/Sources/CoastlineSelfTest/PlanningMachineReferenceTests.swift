import CoastlineCore
import CryptoKit
import Foundation

private var planningPackageURL: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("resources/machines/desktop-cnc", isDirectory: true)
}

private func planningScratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("planning-machine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writePlanningDefinition(_ definition: MachineDefinition, in folder: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(definition).write(to: folder.appendingPathComponent("manifest.json"))
}

let planningMachineReferenceTests: [TestCase] = [
    TestCase(name: "profileSnapshotRoundTripsWithAllAssetFingerprints") {
        let package = try MachineDefinitionPackage.load(from: planningPackageURL)
        let reference = try PlanningMachineReference(definition: package.definition)
        let data = try JSONEncoder().encode(reference)
        let restored = try JSONDecoder().decode(PlanningMachineReference.self, from: data)
        try expectEqual(restored, reference)
        try expectEqual(restored.reference, package.definition.reference)
        try expectEqual(restored.definition?.assets, package.definition.assets)
        try expectEqual(restored.profile, package.definition.profile)
        try expectEqual(try restored.fingerprint(), try reference.fingerprint())
        try expectEqual(try restored.resolve(in: [package])?.rootURL, package.rootURL)
        try expect(!restored.isLegacy)
    },
    TestCase(name: "missingProfileNeverFallsBackToLegacy") {
        let package = try MachineDefinitionPackage.load(from: planningPackageURL)
        let reference = try PlanningMachineReference(definition: package.definition)
        try expectThrows { _ = try reference.resolve(in: []) }
        try expect(try PlanningMachineReference.legacy.resolve(in: []) == nil)
        try expect(reference != .legacy)
    },
    TestCase(name: "sameRevisionChangedLimitsCannotReplaceSavedMachine") {
        let package = try MachineDefinitionPackage.load(from: planningPackageURL)
        let reference = try PlanningMachineReference(definition: package.definition)
        let copy = try planningScratch()
        defer { try? FileManager.default.removeItem(at: copy) }
        let destination = copy.appendingPathComponent("profile")
        try FileManager.default.copyItem(at: planningPackageURL, to: destination)
        var changed = package.definition
        changed.profile.maxRate.x /= 2
        try writePlanningDefinition(changed, in: destination)
        let replacement = try MachineDefinitionPackage.load(from: destination)
        try expectEqual(replacement.definition.reference, reference.reference)
        try expectThrows { _ = try reference.resolve(in: [replacement]) }
        // A conflicting copy must not be accepted merely because the first entry matches.
        try expectThrows { _ = try reference.resolve(in: [package, replacement]) }
        try expect(try reference.fingerprint() != PlanningMachineReference(definition: changed).fingerprint())
    },
    TestCase(name: "sameRevisionChangedAssetsCannotReplaceSavedMachine") {
        let package = try MachineDefinitionPackage.load(from: planningPackageURL)
        let reference = try PlanningMachineReference(definition: package.definition)
        let scratch = try planningScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let destination = scratch.appendingPathComponent("profile")
        try FileManager.default.copyItem(at: planningPackageURL, to: destination)
        var changed = package.definition
        let index = changed.assets.firstIndex { $0.role == .geometry }!
        let geometry = destination.appendingPathComponent(changed.assets[index].path)
        // Whitespace changes the asset identity without changing the represented STEP geometry.
        var data = try Data(contentsOf: geometry)
        data.append(Data("\n".utf8))
        try data.write(to: geometry)
        changed.assets[index].sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try writePlanningDefinition(changed, in: destination)
        let replacement = try MachineDefinitionPackage.load(from: destination)
        try expectThrows { _ = try reference.resolve(in: [replacement]) }
    },
    TestCase(name: "newerRevisionDoesNotUpgradeExistingJob") {
        let original = try MachineDefinitionPackage.load(from: planningPackageURL)
        let reference = try PlanningMachineReference(definition: original.definition)
        let scratch = try planningScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let destination = scratch.appendingPathComponent("newer")
        try FileManager.default.copyItem(at: planningPackageURL, to: destination)
        var changed = original.definition
        changed.revision += 1
        try writePlanningDefinition(changed, in: destination)
        let newer = try MachineDefinitionPackage.load(from: destination)
        try expectThrows { _ = try reference.resolve(in: [newer]) }
        try expectEqual(try reference.resolve(in: [newer, original])?.definition, original.definition)
    },
    TestCase(name: "legacyAssignmentRetainsItsSavedLimits") {
        let original = PlanningMachineReference.legacy
        let data = try JSONEncoder().encode(original)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var profile = object["legacyProfile"] as! [String: Any]
        var rates = profile["maxRate"] as! [String: Any]
        rates["x"] = 1200.0
        profile["maxRate"] = rates
        object["legacyProfile"] = profile
        let saved = try JSONDecoder().decode(PlanningMachineReference.self, from: JSONSerialization.data(withJSONObject: object))
        try expect(saved.isLegacy)
        try expectEqual(saved.profile.maxRate.x, 1200)
        try expectEqual(saved.reference.id, "coastline.legacy-desktop")
        try expect(saved != original)
        try expectEqual(try JSONDecoder().decode(PlanningMachineReference.self, from: JSONEncoder().encode(saved)), saved)
    },
    TestCase(name: "incompleteOrAmbiguousMachineAssignmentsAreRejected") {
        let package = try MachineDefinitionPackage.load(from: planningPackageURL)
        let reference = try PlanningMachineReference(definition: package.definition)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as! [String: Any]
        object["kind"] = "legacy"
        try expectThrows { _ = try JSONDecoder().decode(PlanningMachineReference.self, from: JSONSerialization.data(withJSONObject: object)) }
        object["kind"] = "profile"
        object.removeValue(forKey: "definition")
        try expectThrows { _ = try JSONDecoder().decode(PlanningMachineReference.self, from: JSONSerialization.data(withJSONObject: object)) }
        let legacy = try JSONEncoder().encode(PlanningMachineReference.legacy)
        var badLegacy = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        var profile = badLegacy["legacyProfile"] as! [String: Any]
        profile["maxShankDiameter"] = 0
        badLegacy["legacyProfile"] = profile
        try expectThrows { _ = try JSONDecoder().decode(PlanningMachineReference.self, from: JSONSerialization.data(withJSONObject: badLegacy)) }
    },
    TestCase(name: "sharedProjectRetainsMachineSnapshot") {
        let package = try MachineDefinitionPackage.load(from: planningPackageURL)
        let reference = try PlanningMachineReference(definition: package.definition)
        let scratch = try planningScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let part = scratch.appendingPathComponent("reference.step")
        try "ISO-10303-21;".write(to: part, atomically: true, encoding: .utf8)
        let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference))
        let object: [String: Any] = ["version": 1, "partPath": part.path, "machine": record]
        let project = scratch.appendingPathComponent("Test.coastline")
        try JSONSerialization.data(withJSONObject: object).write(to: project)
        let archive = scratch.appendingPathComponent("Test.zip")
        try ProjectShare.exportProject(project, to: archive)
        guard case .project(let shared)? = try ProjectShare.unpack(archive, into: scratch.appendingPathComponent("imported")) else {
            throw TestFailure(description: "Shared archive did not contain a project.")
        }
        let imported = try JSONSerialization.jsonObject(with: Data(contentsOf: shared)) as! [String: Any]
        let restored = try JSONDecoder().decode(PlanningMachineReference.self,
                                               from: JSONSerialization.data(withJSONObject: imported["machine"]!))
        try expectEqual(restored, reference)
        // The share carries the machine identity, not an implicit substitute for missing model assets.
        try expectThrows { _ = try restored.resolve(in: []) }
    },
]
