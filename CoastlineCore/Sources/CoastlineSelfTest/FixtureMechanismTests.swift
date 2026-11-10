import CoastlineCore
import CryptoKit
import Foundation
import simd

private let resources = repoRoot.appendingPathComponent("resources")
private func bundled(_ name: String) throws -> FixtureAssemblyDefinition {
    try JSONDecoder().decode(FixtureAssemblyDefinition.self, from: Data(contentsOf: resources.appendingPathComponent("fixtures/\(name)")))
}
private let table = BookendSetup.Table(topX: 15.8651364, slotZ: [78.7585941251, 118.7635941251], slotY: -429 ... -44,
                                       frontZ: 129.8435941251, centreY: -241.4)
private func fixture(_ kind: Fixture.Kind, _ definition: String, model: String) throws -> Fixture {
    var f = Fixture(name: "\(kind)", kind: kind, quantity: 2, modelPath: model)
    f.assembly = try bundled(definition)
    return f
}

let fixtureMechanismTests: [TestCase] = [
    TestCase(name: "reviewedClampAndViseModelsMatchTheirDefinitions") {
        for (model, definition) in [("bookends/assembly.step", "bookends/definition.json"), ("c-clamps/assembly.step", "c-clamps/definition.json"), ("vise/assembly.step", "vise/definition.json"),
                                    ("quick-release/assembly.step", "quick-release/assembly-definition.json")] {
            let d = try bundled(definition)
            try d.validate()
            let data = try Data(contentsOf: resources.appendingPathComponent("fixtures/\(model)"))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try expectEqual(d.modelSHA256, digest)
            try expect(d.isAssembled && d.planningIssues.isEmpty)
            var f = Fixture(name: model, kind: .other, modelPath: "fixtures/\(model)")
            f = try VettedFixtureLibrary.prepared(f, resources: resources)
            try expectEqual(f.assembly, d)
        }
    },
    TestCase(name: "cClampsFitAStockBarAndPressItsTopOntoTheTable") {
        let a = try bundled("c-clamps/definition.json")
        let bar = SIMD3(50.8, 203.2, 50.8)
        let c = try ClampPairSetup(assembly: a, table: table, stock: bar)
        let p = try c.seat(FixturePlanningProfile())
        // Authored in the CAD on this very bar: nothing moves.
        for id in ClampPairSetup.slides + ClampPairSetup.advances { try expect(abs(p.assemblyState!.jointValues[id]!) < 1e-6, id) }
        try expect(simd_distance(SIMD3(p.datum.x, p.datum.y, p.datum.z), SIMD3(15.865 + 25.4, -241.4, 129.8436)) < 1e-6)
        try expectEqual(p.contacts.count, 4)
        try expect(p.contacts.allSatisfy { $0.normal == .x && abs(abs($0.point.x) - 25.4) < 1e-9 && abs($0.point.z + 25.3996) < 1e-3 })
        try expect(c.planningIssues(p).isEmpty)
        // A smaller bar: both pads tighten down onto it and stay on it.
        let small = try ClampPairSetup(assembly: a, table: table, stock: SIMD3(25, 120, 40)).seat(FixturePlanningProfile())
        try expect(abs(small.assemblyState!.jointValues[ClampPairSetup.advances[0]]! - 25.8) < 1e-6)
        let pads = small.contacts.filter { $0.point.x > 0 }.map(\.point.y)
        try expect(pads.allSatisfy { abs($0) + 11.112 <= 60 + 1e-6 } && abs(pads[1] - pads[0]) >= 31.2)
        // Loosening a screw leaves it unready; the slide keeps the pad on the stock.
        var loose = try c.setting(p, joint: ClampPairSetup.advances[1], to: -5)
        try expect(!c.planningIssues(loose).isEmpty)
        loose = try c.setting(p, joint: ClampPairSetup.slides[0], to: -500)
        try expect(loose.contacts[0].point.y - 11.112 >= -101.6 - 1e-6)
        // Too tall, too shallow and too short for two clamps.
        try expectThrows { _ = try ClampPairSetup(assembly: a, table: table, stock: SIMD3(70, 203.2, 50.8)) }
        try expectThrows { _ = try ClampPairSetup(assembly: a, table: table, stock: SIMD3(50.8, 203.2, 30)) }
        try expectThrows { _ = try ClampPairSetup(assembly: a, table: table, stock: SIMD3(50.8, 40, 50.8)) }
    },
    TestCase(name: "viseHoldsStockBetweenItsJawsWithTheFaceOut") {
        let a = try bundled("vise/definition.json")
        let v = try ViseSetup(assembly: a, table: table, stock: SIMD3(30, 40, 20))
        try expect(abs(v.height - 12) < 1e-3)
        let p = try v.seat(FixturePlanningProfile())
        try expect(abs(p.assemblyState!.jointValues[ViseSetup.jawAdvance]! - -15) < 1e-6)
        // Two-thirds of a 20 mm deep block in the jaws: its face 6.7 mm past them.
        try expect(abs(p.datum.z - (128.764 + 20.0 / 3)) < 1e-6)
        try expect(abs(p.facePastTable - (p.datum.z - 0.0004 - 129.8435941251)) < 1e-3)
        try expect(v.planningIssues(p).isEmpty)
        let jaws = p.contacts.filter { $0.normal == .y }
        try expectEqual(jaws.count, 2)
        try expect(jaws.allSatisfy { abs(abs($0.point.y) - 20) < 1e-9 && $0.point.z - $0.radius >= -20 - 1e-9 && $0.point.z + $0.radius <= 1e-9 })
        let open = try v.setting(p, joint: ViseSetup.jawAdvance, to: -20)
        try expectEqual(v.planningIssues(open), ["Close the vise on the stock."])
        try expect(abs((try v.setting(p, joint: ViseSetup.jawAdvance, to: 10)).assemblyState!.jointValues[ViseSetup.jawAdvance]! - -15) < 1e-6)
        // Outside the jaw opening.
        try expectThrows { _ = try ViseSetup(assembly: a, table: table, stock: SIMD3(30, 50, 20)) }
        try expectThrows { _ = try ViseSetup(assembly: a, table: table, stock: SIMD3(30, 15, 20)) }
        // The nuts must stay in the slot.
        let short = BookendSetup.Table(topX: table.topX, slotZ: table.slotZ, slotY: -280 ... -230, frontZ: table.frontZ, centreY: -241.4)
        try expectThrows { _ = try ViseSetup(assembly: a, table: short, stock: SIMD3(30, 40, 20)).seat(FixturePlanningProfile()) }
    },
    TestCase(name: "automaticWorkholdingFitsEachMechanismToTheStock") {
        let clamps = try fixture(.cClamp, "c-clamps/definition.json", model: "fixtures/c-clamps/assembly.step")
        let vise = try fixture(.vise, "vise/definition.json", model: "fixtures/vise/assembly.step")
        let bar = SIMD3(50.8, 203.2, 50.8)
        let fitted = try unwrap(FixtureMechanism.automatic(clamps, table: table, stock: bar))
        try expect(LibraryWorkholdingPlanner.eligibility(fitted, stock: bar).isEmpty, "\(LibraryWorkholdingPlanner.eligibility(fitted, stock: bar))")
        try expect(fitted.planning?.allowsRoughing == true && fitted.height == 0)
        try expectEqual(try FixtureMechanism.automatic(clamps, table: table, stock: bar), fitted)
        try expectThrows { _ = try FixtureMechanism.automatic(vise, table: table, stock: bar) }
        let block = SIMD3<Double>(30, 40, 20)
        let held = try unwrap(FixtureMechanism.automatic(vise, table: table, stock: block))
        try expect(LibraryWorkholdingPlanner.eligibility(held, stock: block).isEmpty)
        try expect(abs(held.height - 12) < 1e-3)
        try expect(try FixtureMechanism.automatic(Fixture(name: "Plate", kind: .jigPlate), table: table, stock: block) == nil)
    },
    TestCase(name: "libraryCClampsAndTheExplodedJigPlateGetTheirReviewedModels") {
        var exploded = Fixture(name: "Quick Release Jig Plate", kind: .jigPlate, modelPath: "fixtures/quick-release/fixture.step")
        exploded.assembly = try bundled("quick-release/definition.json")
        let clamps = Fixture(name: "3\" C-clamp", kind: .cClamp, quantity: 2)
        let single = Fixture(name: "Other C-clamp", kind: .cClamp, quantity: 1)
        var inventory = Inventory(); inventory.fixtures = [exploded, clamps, single]
        try expect(VettedFixtureLibrary.migrate(&inventory, resources: resources))
        try expectEqual(inventory.fixtures[0].assembly, try bundled("quick-release/assembly-definition.json"))
        try expectEqual(inventory.fixtures[1].assembly, try bundled("c-clamps/definition.json"))
        try expect(inventory.fixtures[2].modelPath == nil)
        // A newer reviewed revision of the vise replaces the one a library holds.
        var vise = try fixture(.vise, "vise/definition.json", model: "fixtures/vise/assembly.step")
        vise.assembly?.revision = 1; vise.assembly?.modelSHA256 = String(repeating: "0", count: 64)
        var p = FixturePlanningProfile(); p.gripDefinitionReviewed = true; vise.planning = p
        let rebound = try VettedFixtureLibrary.prepared(vise, resources: resources)
        try expectEqual(rebound.assembly, try bundled("vise/definition.json"))
        try expect(rebound.planning?.gripDefinitionReviewed == false)
        var edited = vise; edited.assembly?.revision = 5
        try expectThrows { _ = try VettedFixtureLibrary.prepared(edited, resources: resources) }
        // The M5 Bookends a library holds move to the M4 revision.
        var bookends = try fixture(.other, "bookends/definition.json", model: "fixtures/bookends/assembly.step")
        bookends.assembly?.revision = 1
        bookends.assembly?.modelSHA256 = "341115f76ac3ede6f85058c05886872df52cf926588ceb9a20dee3b28acaf78b"
        let m4 = try VettedFixtureLibrary.prepared(bookends, resources: resources)
        try expectEqual(m4.assembly, try bundled("bookends/definition.json"))
        try expectEqual(m4.assembly?.components.first { $0.id == "pressure-screw" }?.joint?.pitch, 0.7)
        try expectEqual(inventory.fixtures.map(\.name), [exploded.name, clamps.name, single.name])
    },
]
