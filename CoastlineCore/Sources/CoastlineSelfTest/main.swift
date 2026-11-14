import CoastlineCore
import Foundation

let suites: [(String, [TestCase])] = [
    ("Machine", machineTests),
    ("MachineDefinition", machineDefinitionTests),
    ("MachinePlanningGeometry", machinePlanningGeometryTests),
    ("PlanningMachineReference", planningMachineReferenceTests),
    ("Units", unitsTests),
    ("Engine", engineTests),
    ("Materials", materialTests),
    ("Inventory", inventoryTests),
    ("ToolCatalog", toolCatalogTests),
    ("StockCatalog", stockCatalogTests),
    ("MaterialResource", materialResourceTests),
    ("ResourceLibrary", resourceLibraryTests),
    ("JobResourceSnapshot", jobResourceSnapshotTests),
    ("Setup", setupTests),
    ("SideB", sideBTests),
    ("CAM", camTests),
    ("Viewer", viewerTests),
    ("Guided", guidedTests),
    ("Probing", probingMethodTests),
    ("GeneratedJob", generatedJobTests),
    ("Feasibility", feasibilityTests),
    ("DFM", dfmTests),
    ("DFMEngine", dfmEngineTests),
    ("Fixture", fixtureTests),
    ("LibraryWorkholding", libraryWorkholdingTests),
    ("FixtureAssembly", fixtureAssemblyTests),
    ("VettedFixtureAssembly", vettedFixtureAssemblyTests),
    ("BookendSetup", bookendSetupTests),
    ("FixtureMechanism", fixtureMechanismTests),
    ("SetupSide", setupSideTests),
    ("FixtureSnap", fixtureSnapTests),
    ("Tuner", tunerTests),
    ("Journal", journalTests),
    ("Triage", triageTests),
    ("PrepGeometry", prepGeometryTests),
    ("Program", programTests),
    ("Dexel", dexelTests),
    ("Share", shareTests),
]

setvbuf(stdout, nil, _IONBF, 0)
Length.locale = Locale(identifier: "en_US_POSIX")
let filter = CommandLine.arguments.dropFirst().first
var passed = 0, failed = 0, skipped = 0
for (suite, tests) in suites {
    for test in tests {
        let name = "\(suite).\(test.name)"
        if let filter, !name.localizedCaseInsensitiveContains(filter) { continue }
        print("  … \(name)", terminator: "\r")
        do {
            try test.body()
            passed += 1
            print("  ✓ \(name)")
        } catch let skip as Skip {
            skipped += 1
            print("  – \(name) (skipped: \(skip.reason))")
        } catch {
            failed += 1
            print("  ✗ \(name): \(error)")
        }
    }
}
print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
exit(failed == 0 ? 0 : 1)
