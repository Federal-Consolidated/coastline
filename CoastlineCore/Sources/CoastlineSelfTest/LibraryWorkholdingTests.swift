import CoastlineCore
import Foundation
import simd

private let libraryStock = SIMD3<Double>(20, 20, 10)
private let libraryTool = Tool(name: "Test cutter", kind: .flatEndMill, diameter: 1, shankDiameter: 1, flutes: 2,
                               fluteLength: 10, stickout: 20, overallLength: 40)

private func jig(_ number: Int, obstructionX: Double? = nil) -> LibraryWorkholdingPlanner.Candidate {
    var fixture = Fixture(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
                          name: "Jig \(number)", kind: .other, modelPath: "synthetic.step")
    var p = FixturePlanningProfile()
    p.enabled = true; p.stockSize = Vec3(20, 20, 10); p.allowsRoughing = true; p.gripDefinitionReviewed = true
    p.contacts = [.init(point: Vec3(-8, -8, -8), radius: 0.4), .init(point: Vec3(8, 8, -8), radius: 0.4)]
    fixture.planning = p
    var tris = FixtureField.boxTriangles(min: SIMD3(-30, -30, -20), max: SIMD3(-28, -28, -18))
    if let x = obstructionX { tris += FixtureField.boxTriangles(min: SIMD3(x - 1, -1, -10), max: SIMD3(x + 1, 1, 0)) }
    let field = FixtureField(triangles: tris, regionMin: SIMD2(-40, -40), regionMax: SIMD2(40, 40), cell: 1)
    return .init(fixture: fixture, field: field,
                 occupied: DexelGrid(min: SIMD2(-10, -10), max: SIMD2(10, 10), cell: 0.2), modelSignature: "synthetic")
}

private func cut(_ key: String, x: Double, y: Double = 0, depth: Double = -2, side: Int = 0,
                 kind: OperationKind = .contour) -> LibraryWorkholdingPlanner.Cut {
    .init(key: key, side: side, operation: Operation(kind: kind, toolID: libraryTool.id), tool: libraryTool,
          moves: [Move(.rapid, x: x, y: y, z: 3), Move(.plunge, x: x, y: y, z: depth, feed: 100),
                  Move(.cut, x: x + 0.5, y: y, z: depth, feed: 200), Move(.rapid, x: x + 0.5, y: y, z: 3)])
}

let libraryWorkholdingTests: [TestCase] = [
    TestCase(name: "chosenFixtureIDsAndMechanicalSnapshotsRoundTripWithLegacyFallback") {
        var fixture = jig(1).fixture
        fixture.planning?.assemblyState = .init(jointValues: ["fixed-slide": 12, "pressure-extension": 3.5],
                                                mounted: true, lockedComponents: ["fixed-end", "clamp-end"])
        var setup = Setup()
        setup.fixtureAssemblies = [fixture]
        setup.selectedFixtureIDs = [fixture.id, jig(2).fixture.id]
        let data = try JSONEncoder().encode(setup)
        let reopened = try JSONDecoder().decode(Setup.self, from: data)
        try expectEqual(reopened, setup)
        try expectEqual(reopened.fixtureAssemblies?[0].planning?.assemblyState, fixture.planning?.assemblyState)
        var raw = try unwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        raw.removeValue(forKey: "selectedFixtureIDs")
        let legacy = try JSONDecoder().decode(Setup.self, from: JSONSerialization.data(withJSONObject: raw))
        try expect(legacy.selectedFixtureIDs == nil)
        try expectEqual(legacy.fixtureAssemblies, setup.fixtureAssemblies)
        setup.selectedFixtureIDs = []
        try expectEqual(try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(setup)).selectedFixtureIDs, [])
    },
    TestCase(name: "jobFixtureSelectionAllowsOnlyChosenCandidatesAndPreservesOtherResources") {
        let a = jig(1).fixture, b = jig(2).fixture, c = jig(3).fixture
        var inventory = Inventory()
        inventory.fixtures = [a, b, c]
        inventory.stock = [StockItem(materialID: "al-6061", sizeX: 20, sizeY: 20, sizeZ: 10)]
        inventory.tools = [libraryTool]
        inventory.accessories = [Accessory(name: "Shop collet", kind: .collet, size: 3.175)]
        var setup = Setup()
        try expectEqual(inventory.forFixtureSetup(setup), inventory, "legacy nil must preserve automatic library selection")
        setup.selectedFixtureIDs = [c.id, b.id, b.id]
        var expected = inventory; expected.fixtures = [b, c]
        try expectEqual(inventory.forFixtureSetup(setup), expected)
        try expectEqual(inventory.fixtures, [a, b, c], "resolving the job must not edit the library")
        setup.selectedFixtureIDs = []
        expected.fixtures = []
        try expectEqual(inventory.forFixtureSetup(setup), expected, "an empty explicit selection must not fall back to all fixtures")
    },
    TestCase(name: "jobFixtureSnapshotKeepsItsStateButUsesLiveAvailability") {
        var owned = jig(1).fixture
        owned.quantity = 3; owned.name = "Updated library default"
        owned.planning?.datum = Vec3(50, 60, 70)
        var saved = owned
        saved.quantity = 99; saved.name = "Job placement"
        saved.planning?.datum = Vec3(1, 2, 3)
        saved.planning?.assemblyState = .init(jointValues: ["pressure-extension": 4], mounted: true,
                                              lockedComponents: ["fixed-end", "clamp-end"])
        var setup = Setup(); setup.fixtureAssemblies = [saved]; setup.selectedFixtureIDs = [saved.id]
        var inventory = Inventory(); inventory.fixtures = [owned]
        var expected = saved; expected.quantity = 3
        try expectEqual(inventory.forFixtureSetup(setup).fixtures, [expected])
        try expectEqual(inventory.fixtures, [owned])
        inventory.fixtures[0].quantity = 0
        expected.quantity = 0
        let unavailable = inventory.forFixtureSetup(setup)
        try expectEqual(unavailable.fixtures, [expected])
        try expect(!LibraryWorkholdingPlanner.eligibility(unavailable.fixtures[0], stock: libraryStock).isEmpty)
        inventory.fixtures = []
        try expect(inventory.forFixtureSetup(setup).fixtures.isEmpty, "a saved snapshot must not resurrect deleted ownership")
        try expectEqual(setup.fixtureAssemblies, [saved], "availability checks must not rewrite saved mechanical state")
    },
    TestCase(name: "plannerCannotSubstituteAnUnselectedFixture") {
        let blocked = jig(1, obstructionX: 0), clear = jig(2)
        let candidates = [blocked, clear]
        var inventory = Inventory(); inventory.fixtures = candidates.map(\.fixture)
        var setup = Setup(); setup.selectedFixtureIDs = [blocked.fixture.id]
        func plan(_ setup: Setup) -> LibraryWorkholdingPlan {
            let ids = Set(inventory.forFixtureSetup(setup).fixtures.map(\.id))
            return LibraryWorkholdingPlanner.plan(cuts: [cut("centre", x: 0)],
                candidates: candidates.filter { ids.contains($0.fixture.id) }, stock: libraryStock)
        }
        try expect(!plan(setup).complete, "an unavailable path must not silently use another owned fixture")
        setup.selectedFixtureIDs = [clear.fixture.id]
        let selected = plan(setup)
        try expect(selected.complete)
        try expectEqual(selected.steps.map { $0.fixture.id }, [clear.fixture.id])
        setup.selectedFixtureIDs = nil
        try expect(plan(setup).complete, "legacy automatic planning can still choose the clear fixture")
    },
    TestCase(name: "visualFixtureRotationsUseWorkAxesAndKeepTheStockDatumFixed") {
        for facing in Setup.Facing.allCases {
            for spin in 0..<4 {
                var p = FixturePlanningProfile()
                p.facing = facing; p.spin = spin; p.datum = Vec3(12, -3, 7)
                p.gripDefinitionReviewed = true
                let datum = SIMD4<Double>(12, -3, 7, 1)
                let point = SIMD4<Double>(22, 4, 11, 1)
                for axis in 0...2 {
                    for q in [-1, 1] {
                        let next = p.turned(about: axis, quarterTurns: q)
                        let actual = next.modelToWork * point
                        let before = p.modelToWork * point
                        let rotation = Setup().turned(about: axis, quarterTurns: q).partRotation
                        let expected = rotation * SIMD3(before.x, before.y, before.z)
                        try expect(simd_distance(SIMD3(actual.x, actual.y, actual.z), expected) < 1e-7)
                        let origin = next.modelToWork * datum
                        try expect(simd_length(SIMD3(origin.x, origin.y, origin.z)) < 1e-7)
                        try expect(!next.gripDefinitionReviewed)
                    }
                }
            }
        }
    },
    TestCase(name: "fixtureNudgesStayInMachineDirectionsAfterTurningSideways") {
        var p = FixturePlanningProfile()
        p.datum = Vec3(3, 4, 5)
        p = p.turned(about: 2, quarterTurns: 1).turned(about: 1, quarterTurns: -1)
        p.gripDefinitionReviewed = true
        let point = SIMD4<Double>(10, 20, 30, 1)
        for delta in [Vec3(5, 0, 0), Vec3(0, -5, 0), Vec3(0, 0, 10)] {
            let next = p.moved(inWork: delta)
            let before = p.modelToWork * point, after = next.modelToWork * point
            try expect(simd_distance(SIMD3(after.x - before.x, after.y - before.y, after.z - before.z), SIMD3(delta.x, delta.y, delta.z)) < 1e-7)
            try expect(!next.gripDefinitionReviewed)
        }
    },
    TestCase(name: "stockGuideUsesOwnedBlanksAndDoesNotRequireAClampFrame") {
        let exact = StockItem(materialID: "al-6061", sizeX: 20, sizeY: 20, sizeZ: 10)
        var unavailable = exact; unavailable.id = UUID(); unavailable.quantity = 0
        var unknown = exact; unknown.id = UUID(); unknown.materialID = "no-material"
        var inventory = Inventory(); inventory.stock = [unavailable, unknown, exact]
        let choices = JobLibraryGuide.stockChoices(partSize: libraryStock, inventory: inventory)
        try expectEqual(choices.count, 1)
        try expectEqual(choices[0].stock.id, exact.id)
        try expectEqual(choices[0].matchingFixtures, 0, "defining a jig must not be required to select a physically fitting blank")
    },
    TestCase(name: "stockGuidePrefersAnOwnedDefinedJigWithoutDiscardingOtherStock") {
        let small = StockItem(materialID: "al-6061", sizeX: 18, sizeY: 18, sizeZ: 8)
        let matched = StockItem(materialID: "al-6061", sizeX: 20, sizeY: 20, sizeZ: 10)
        var inventory = Inventory(); inventory.stock = [small, matched]; inventory.fixtures = [jig(1).fixture]
        let choices = JobLibraryGuide.stockChoices(partSize: SIMD3(18, 18, 8), inventory: inventory)
        try expectEqual(choices.map(\.stock.id), [matched.id, small.id])
        inventory.fixtures[0].quantity = 0
        let withoutJig = JobLibraryGuide.stockChoices(partSize: SIMD3(18, 18, 8), inventory: inventory)
        try expectEqual(withoutJig.first?.stock.id, small.id)
        try expect(withoutJig.allSatisfy { $0.matchingFixtures == 0 })
    },
    TestCase(name: "stockGuideProposesTheOrientationThatMatchesTheJig") {
        let stock = StockItem(materialID: "al-6061", sizeX: 10, sizeY: 30, sizeZ: 20)
        var fixture = jig(1).fixture
        fixture.planning?.stockSize = Vec3(20, 30, 10)
        var inventory = Inventory(); inventory.stock = [stock]; inventory.fixtures = [fixture]
        let choices = JobLibraryGuide.stockChoices(partSize: SIMD3(18, 28, 8), inventory: inventory)
        try expectEqual(choices.first?.axes, [2, 1, 0])
        try expectEqual(choices.first?.matchingFixtures, 1)
    },
    TestCase(name: "aCutFromTheUpperSideCountsAgainstTheNextSetupsGrip") {
        // The block turned: its upper side (A's +X) toward the spindle. Stock there 10 × 20 × 20.
        var turned = jig(2)
        turned.fixture.planning?.stockSize = Vec3(10, 20, 20)
        turned.fixture.planning?.contacts = [.init(point: Vec3(4, 9, -19), radius: 0.3), .init(point: Vec3(-4, 9, -19), radius: 0.3)]
        // A hole from the upper side, 18 mm in: it reaches A's grip patch at (−8, −8, −8).
        let intoGrip = cut("side hole", x: 3, y: -8, depth: -18, side: 2)
        let bad = LibraryWorkholdingPlanner.plan(cuts: [intoGrip, cut("front", x: 0)], candidates: [jig(1), turned], stock: libraryStock)
        try expect(!bad.complete && bad.issues.joined().contains("grip/support material"), "\(bad.issues)")
        // Elsewhere on that side: both setups hold, each in the fixture fitted that way round.
        let clear = cut("side hole", x: 0, y: 2, depth: -6, side: 2)
        let good = LibraryWorkholdingPlanner.plan(cuts: [clear, cut("front", x: 0)], candidates: [jig(1), turned], stock: libraryStock)
        try expect(good.complete && good.steps.map(\.side) == [2, 0], "\(good.issues)")
        try expect(good.steps[0].instructions.hasPrefix("Turn the stock so its upper side faces the spindle."), good.steps[0].instructions)
        try expectEqual(good.steps.map(\.fixture.id), [turned.fixture.id, jig(1).fixture.id])
    },
    TestCase(name: "sideClampingPatchesAreCheckedInTheirOwnFacePlane") {
        var c = jig(1)
        var left = FixturePlanningProfile.Contact(point: Vec3(-10, 0, -5), radius: 0.5)
        var right = FixturePlanningProfile.Contact(point: Vec3(10, 0, -5), radius: 0.5)
        left.normal = .x; right.normal = .x
        c.fixture.planning?.contacts = [left, right]
        let good = LibraryWorkholdingPlanner.plan(cuts: [cut("front", x: 0)], candidates: [c], stock: libraryStock)
        try expect(good.complete, "\(good.issues)")
        let bad = LibraryWorkholdingPlanner.plan(cuts: [cut("grip", x: -9.7, depth: -8)], candidates: [c], stock: libraryStock)
        try expect(!bad.complete && bad.issues.joined().contains("grip/support material"), "\(bad.issues)")
    },
    TestCase(name: "aLocatingFixtureCanUseAPocketOnlyAfterItIsMachined") {
        let a = jig(1, obstructionX: 5)
        var b = jig(2)
        for row in 49...50 { for col in 49...50 { b.occupied.add(row * b.occupied.cols + col, -2, -1) } }
        let tooSoon = LibraryWorkholdingPlanner.plan(cuts: [cut("finish", x: 5)], candidates: [b], stock: libraryStock)
        try expect(!tooSoon.complete && tooSoon.issues.joined().contains("intersects material"))
        var rough = cut("pocket", x: -2, depth: -3, kind: .adaptive)
        rough.moves = [Move(.rapid, x: -2, y: -0.5, z: 3), Move(.plunge, x: -2, y: -0.5, z: -3, feed: 100)]
        for y in [-0.5, 0, 0.5] {
            rough.moves += [Move(.cut, x: -2, y: y, z: -3, feed: 200), Move(.cut, x: 2, y: y, z: -3, feed: 200)]
        }
        let plan = LibraryWorkholdingPlanner.plan(cuts: [rough, cut("finish", x: 5)], candidates: [a, b], stock: libraryStock)
        try expect(plan.complete && plan.steps.count == 2, "\(plan.issues)")
        try expectEqual(plan.steps.map(\.fixture.id), [a.fixture.id, b.fixture.id])
    },
    TestCase(name: "aSideBLocatingPinUsesTheCavityActuallyCutOnSideA") {
        let a = jig(1, obstructionX: 5)
        var b = jig(2)
        // Side B Y+3, Z−9.5…−8 reflects to side A Y−3, Z−2…−0.5.
        let row = Int(((3 - b.occupied.origin.y) / b.occupied.cell).rounded())
        for col in 49...50 { b.occupied.add(row * b.occupied.cols + col, -9.5, -8) }
        var rough = cut("pocket", x: -2, y: -3, depth: -3, kind: .adaptive)
        rough.moves = [Move(.rapid, x: -2, y: -3.5, z: 3), Move(.plunge, x: -2, y: -3.5, z: -3, feed: 100)]
        for y in [-3.5, -3, -2.5] {
            rough.moves += [Move(.cut, x: -2, y: y, z: -3, feed: 200), Move(.cut, x: 2, y: y, z: -3, feed: 200)]
        }
        let plan = LibraryWorkholdingPlanner.plan(cuts: [rough, cut("B", x: 5, side: 1)], candidates: [a, b], stock: libraryStock)
        try expect(plan.complete && plan.steps.count == 2 && plan.steps[1].side == 1, "\(plan.issues)")
    },
    TestCase(name: "assignsDifferentOwnedJigsToCutsTheyActuallyClear") {
        let a = jig(1, obstructionX: -5), b = jig(2, obstructionX: 5)
        let cuts = [cut("left", x: -5), cut("right", x: 5)]
        let plan = LibraryWorkholdingPlanner.plan(cuts: cuts, candidates: [a, b], stock: libraryStock)
        try expect(plan.complete && plan.steps.count == 2, "\(plan.issues)")
        try expectEqual(plan.steps.map(\.fixture.id), [b.fixture.id, a.fixture.id])
        try expectEqual(plan.steps.flatMap(\.cutKeys), ["left", "right"])
        try expect(!plan.reviewed)
    },
    TestCase(name: "minimizesReclampingsWithoutReorderingCuts") {
        let plan = LibraryWorkholdingPlanner.plan(cuts: [cut("left", x: -5), cut("right", x: 5)],
            candidates: [jig(1, obstructionX: -5), jig(2, obstructionX: 5), jig(3)], stock: libraryStock)
        try expect(plan.complete && plan.steps.count == 1, "\(plan.issues)")
        try expectEqual(plan.steps[0].fixture.name, "Jig 3")
        try expectEqual(plan.steps[0].cutKeys, ["left", "right"])
    },
    TestCase(name: "rejectsARegripOnMaterialRemovedByEarlierCuts") {
        var a = jig(1, obstructionX: 5), b = jig(2)
        a.fixture.planning?.contacts = [.init(point: Vec3(8, -8, -8), radius: 0.4), .init(point: Vec3(8, 8, -8), radius: 0.4)]
        b.fixture.planning?.contacts = [.init(point: Vec3(-8, -8, -8), radius: 0.4), .init(point: Vec3(-8, 8, -8), radius: 0.4)]
        let plan = LibraryWorkholdingPlanner.plan(cuts: [cut("rough", x: -8, y: -8, depth: -9, kind: .adaptive), cut("finish", x: 5)],
            candidates: [a, b], stock: libraryStock)
        try expect(!plan.complete && plan.steps.isEmpty)
        try expect(plan.issues.joined().contains("grip/support material"), "\(plan.issues)")
    },
    TestCase(name: "sideBDoesNotRestoreMaterialRemovedOnSideA") {
        var a = jig(1, obstructionX: 5), b = jig(2)
        a.fixture.planning?.contacts = [.init(point: Vec3(8, -8, -8), radius: 0.4), .init(point: Vec3(8, 8, -8), radius: 0.4)]
        b.fixture.planning?.contacts = [.init(point: Vec3(-8, 8, -2), radius: 0.4), .init(point: Vec3(-8, -8, -2), radius: 0.4)]
        let plan = LibraryWorkholdingPlanner.plan(cuts: [cut("A", x: -8, y: -8, depth: -9), cut("B", x: 5, side: 1)],
            candidates: [a, b], stock: libraryStock)
        try expect(!plan.complete && plan.issues.joined().contains("grip/support material"), "\(plan.issues)")
    },
    TestCase(name: "doesNotPretendAnUndefinedOrUnownedFixtureCanHoldStock") {
        var c = jig(1)
        c.fixture.quantity = 0
        try expect(!LibraryWorkholdingPlanner.eligibility(c.fixture, stock: libraryStock).isEmpty)
        c.fixture.quantity = 1; c.fixture.planning = nil
        try expect(!LibraryWorkholdingPlanner.eligibility(c.fixture, stock: libraryStock).isEmpty)
        c = jig(1); c.fixture.planning?.stockSize = Vec3(30, 20, 10)
        try expect(!LibraryWorkholdingPlanner.eligibility(c.fixture, stock: libraryStock).isEmpty)
        c = jig(1); c.fixture.planning?.allowsRoughing = false
        let plan = LibraryWorkholdingPlanner.plan(cuts: [cut("rough", x: 0, kind: .adaptive)], candidates: [c], stock: libraryStock)
        try expect(!plan.complete && plan.issues.joined().contains("not defined for roughing"))
    },
    TestCase(name: "checksArcExtremaAgainstMachineTravel") {
        var candidate = jig(1)
        let env = MachineProfile.standard.machineEnvelope
        candidate.machineOrigin = SIMD3(env.x.upperBound - 1, (env.y.lowerBound + env.y.upperBound) / 2,
                                        (env.z.lowerBound + env.z.upperBound) / 2 - libraryTool.stickout)
        var op = cut("arc", x: 0)
        op.moves = [Move(.rapid, x: 0, y: -5, z: 3), Move(.plunge, x: 0, y: -5, z: -2, feed: 100),
                    Move(.cut, .arcCCW, x: 0, y: 5, z: -2, i: 0, j: 5, feed: 200)]
        let plan = LibraryWorkholdingPlanner.plan(cuts: [op], candidates: [candidate], stock: libraryStock)
        try expect(!plan.complete && plan.issues.joined().contains("outside machine travel"), "\(plan.issues)")
    },
    TestCase(name: "aLongerToolRaisesTheSpindleInTheTravelCheck") {
        // The origin is for the bare spindle nose at work zero. With the tool out, the spindle
        // sits higher by its stick-out: a cut just under the top of the travel (bare nose) fits.
        var candidate = jig(1)
        let env = MachineProfile.standard.machineEnvelope
        candidate.machineOrigin = SIMD3((env.x.lowerBound + env.x.upperBound) / 2, (env.y.lowerBound + env.y.upperBound) / 2,
                                        env.z.lowerBound + 5)
        let plan = LibraryWorkholdingPlanner.plan(cuts: [cut("deep", x: 0)], candidates: [candidate], stock: libraryStock)
        try expect(!plan.issues.joined().contains("outside machine travel"), "\(plan.issues)")
    },
    TestCase(name: "invalidInputProducesAnIssueInsteadOfCrashing") {
        let plan = LibraryWorkholdingPlanner.plan(cuts: [cut("bad", x: .nan)], candidates: [jig(1)], stock: libraryStock)
        try expect(!plan.complete && plan.issues.joined().contains("Invalid"))
        var fixture = jig(1).fixture
        fixture.planning?.datum.z = .infinity
        try expect(!LibraryWorkholdingPlanner.eligibility(fixture, stock: libraryStock).isEmpty)
    },
    TestCase(name: "fixtureDefinitionsAndPlansRoundTripWithoutBreakingOldInventory") {
        let fixture = jig(1).fixture
        try expectEqual(try JSONDecoder().decode(Fixture.self, from: JSONEncoder().encode(fixture)), fixture)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as! [String: Any]
        json.removeValue(forKey: "planning")
        let legacy = try JSONDecoder().decode(Fixture.self, from: JSONSerialization.data(withJSONObject: json))
        try expect(legacy.planning == nil)
        let plan = LibraryWorkholdingPlanner.plan(cuts: [cut("first", x: -5)], candidates: [jig(1)], stock: libraryStock)
        try expectEqual(try JSONDecoder().decode(LibraryWorkholdingPlan.self, from: JSONEncoder().encode(plan)), plan)
    },
    TestCase(name: "guidedJobsStopForFixtureChangesAndRequireReviewedSetups") {
        var plan = LibraryWorkholdingPlanner.plan(cuts: [cut("left", x: -5), cut("right", x: 5)],
            candidates: [jig(1, obstructionX: -5), jig(2, obstructionX: 5)], stock: libraryStock)
        var programs = plan.steps.map { step -> GuidedJobBuilder.Program in
            var p = GuidedJobBuilder.Program(tool: libraryTool, gcode: "G21 G90\nM5\n", operationNames: step.operations, minutes: 1)
            p.workholding = step
            return p
        }
        var input = GuidedJobBuilder.Input(partName: "Test", material: MaterialLibrary.material(id: "al-6061")!,
            stock: StockItem(materialID: "al-6061", sizeX: 20, sizeY: 20, sizeZ: 10), stockSize: libraryStock,
            setupName: "Library", programs: programs, checkpoints: [], measuring: [], setupImage: nil, squareStockFirst: false)
        try expectThrows { try GuidedJobBuilder.validateWorkholding(input) }
        for i in plan.steps.indices { plan.steps[i].reviewed = true; programs[i].workholding = plan.steps[i] }
        input.programs = programs
        var custom = Setup.CustomFixture(); custom.name = plan.steps[0].fixture.name; input.customHolding = custom
        try GuidedJobBuilder.validateWorkholding(input)
        let built = GuidedJobBuilder.build(input)
        let steps = try unwrap(built.jobs.last).steps
        try expectEqual(steps.filter { $0.title.hasPrefix("Change Workholding") }.count, 1)
        try expectEqual(steps.filter { $0.title.hasPrefix("Establish Work Zero") }.count, 2)
        try expect(steps.contains { $0.markdown.contains("Do not substitute a fresh blank") })
        try expect(!steps.contains { $0.gcodePath.contains("edge_") })
    },
]
