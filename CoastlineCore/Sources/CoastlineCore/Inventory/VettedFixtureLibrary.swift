import CryptoKit
import Foundation

/// Only exact reviewed source files receive mechanical definitions. Display names do
/// not identify an assembly, and an edited CAD file cannot inherit reviewed joints.
public enum VettedFixtureLibrary {
    private struct Entry {
        var source: String
        var model: String
        var definition: String
    }
    private static let entries = [
        Entry(source: "cc141eb5ee58f00fb420ab2272d84bb448de1758a691a8f1dcd6947a87dca9e3",
              model: "fixtures/bookends/assembly.step", definition: "fixtures/bookends/definition.json"),
        Entry(source: "06df20ac25bc5ab5268f1cc4cf124da6e7e32c7f25f91cd8525b316a0bdc83c1",
              model: "fixtures/quick-release/fixture.step", definition: "fixtures/quick-release/definition.json"),
        Entry(source: "95144b1255821d8162ce28efeecd827796a4694456376d21365980d67f7ceea6",
              model: "fixtures/quick-release/assembly.step", definition: "fixtures/quick-release/assembly-definition.json"),
        Entry(source: "bc10325376db711475497a27841e29a87b710c57317697a112febb32528e4ace",
              model: "fixtures/c-clamps/assembly.step", definition: "fixtures/c-clamps/definition.json"),
        Entry(source: "202b461426c21c267684533de27d34a8c0b1014423cdd4d1d9a286019350a87c",
              model: "fixtures/vise/assembly.step", definition: "fixtures/vise/definition.json"),
    ]
    /// Reviewed models that replace an earlier one: the exploded jig plate gets its assembled
    /// model, and C-clamps without a model get the reviewed pair.
    static let assembledQuickRelease = "fixtures/quick-release/assembly.step"
    static let clampPair = "fixtures/c-clamps/assembly.step"

    public static func prepared(_ fixture: Fixture, resources: URL) throws -> Fixture {
        guard let path = fixture.modelPath else { return fixture }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : resources.appendingPathComponent(path)
        let digest = try sha(url)
        let entry = entries.first(where: { $0.source == digest })
        if let definition = fixture.assembly, definition.modelSHA256.lowercased() != digest {
            // A newer reviewed revision of the same bundled fixture replaces the old one.
            guard let entry, let newer = try? JSONDecoder().decode(FixtureAssemblyDefinition.self,
                      from: Data(contentsOf: resources.appendingPathComponent(entry.definition))),
                  newer.id == definition.id, newer.revision > definition.revision else {
                throw FixtureAssemblyDefinition.AssemblyError.invalid(["The CAD for \(fixture.name) changed. Rebind its mechanical definition before using it."])
            }
        } else if let definition = fixture.assembly {
            // Early development inventories lack the lip and pressure-tip measurements.
            // They still load their stock/tools; only this exact reviewed asset may be
            // rebound automatically. Unknown CAD must retain its incomplete status.
            if definition.bookends?.contactMetadataComplete != false || entry == nil {
                try definition.validate(state: fixture.planning?.assemblyState ?? .init())
                return fixture
            }
        }
        guard let entry else { return fixture }
        let definition = try JSONDecoder().decode(FixtureAssemblyDefinition.self,
            from: Data(contentsOf: resources.appendingPathComponent(entry.definition)))
        try definition.validate()
        if let previous = fixture.assembly, previous.id != definition.id {
            throw FixtureAssemblyDefinition.AssemblyError.invalid(["The incomplete fixture definition does not match the reviewed assembly."])
        }
        guard try sha(resources.appendingPathComponent(entry.model)) == definition.modelSHA256.lowercased() else {
            throw FixtureAssemblyDefinition.AssemblyError.invalid(["The bundled fixture model does not match its mechanical definition."])
        }
        var copy = fixture
        copy.modelPath = entry.model
        copy.assembly = definition
        if var p = copy.planning {
            p.assemblyState = .init()
            p.componentPlacements = nil; p.componentLayoutID = nil; p.componentModelSignature = nil
            p.workspacePlaced = false; p.gripDefinitionReviewed = false
            copy.planning = p
        }
        return copy
    }

    public static func migrate(_ inventory: inout Inventory, resources: URL) -> Bool {
        var changed = false
        for index in inventory.fixtures.indices {
            var fixture = inventory.fixtures[index]
            if fixture.name == "CR-1 Universal Clamp", fixture.kind == .universalClamp {
                fixture.name = "Universal Clamp"
            }
            if fixture.assembly?.id == "quick-release-jig-plate", (fixture.assembly?.revision ?? 2) < 2 {
                fixture.modelPath = assembledQuickRelease; fixture.assembly = nil; fixture.planning = nil
            }
            if fixture.kind == .tSlotNuts, fixture.modelPath == nil, fixture.name.contains("M4") {
                fixture.modelPath = "fixtures/hardware/t-slot-nut-m4.step"
            }
            if fixture.kind == .cClamp, fixture.modelPath == nil, fixture.quantity >= 2 {
                fixture.modelPath = clampPair; fixture.assembly = nil; fixture.planning = nil
            }
            if let prepared = try? prepared(fixture, resources: resources) { fixture = prepared }
            if fixture != inventory.fixtures[index] { inventory.fixtures[index] = fixture; changed = true }
        }
        return changed
    }

    private static func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

