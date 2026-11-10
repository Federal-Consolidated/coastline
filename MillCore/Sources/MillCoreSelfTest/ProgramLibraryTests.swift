import Foundation
@testable import MillCore

let programLibraryTests: [TestCase] = [
    TestCase(name: "editsFavoritesAndDeletionSurvivePersistence") {
        var library = TestProgramLibrary()
        let builtIn = try library.programs.first.unwrapped()
        var custom = SavedTestProgram(title: "Check Y", detail: "Move down and back", code: "G91\nG1 Y-1 F100\nG1 Y1 F100")
        library.save(custom)
        library.toggleFavorite(id: custom.id)
        try expectEqual(library.ordered.first?.id, custom.id)
        custom.title = "Y setup check"
        custom.isFavorite = true
        library.save(custom)
        try expectEqual(library.programs.count, 2)
        library.remove(id: builtIn.id)
        let restored = try JSONDecoder().decode(TestProgramLibrary.self, from: JSONEncoder().encode(library))
        try expectEqual(restored.programs, [custom])
        try expectEqual(restored.ordered.first?.title, "Y setup check")
    },
    TestCase(name: "emptyLibraryRemainsEmpty") {
        var library = TestProgramLibrary()
        for program in library.programs { library.remove(id: program.id) }
        let restored = try JSONDecoder().decode(TestProgramLibrary.self, from: JSONEncoder().encode(library))
        try expect(restored.programs.isEmpty)
    },
    TestCase(name: "customProgramsKeepMotionChecks") {
        let envelope = try MillEnvelope.from(realSettings).unwrapped()
        let start = Point3(x: -40, y: -10, z: -10)
        let good = SavedTestProgram(title: "Relative Y", code: "G91\nG1 Y-1 F100\nG1 Y1 F100")
        let checked = try ProgramCheck.clean(good.lines, start: start, envelope: envelope).get()
        try expectEqual(Array(checked.prefix(3)), ["G21", "G90", "M5"])
        for code in ["M3 S1000", "G20", "G91\nG1 Y-999 F100", "G1 X-30 F100", "G38.2 Z-2 F100",
                     "G999999999999999999999999", "G91\nG1 X999999999999999999999999 F100"] {
            let bad = SavedTestProgram(title: "Unsafe", code: code)
            if case .success = ProgramCheck.clean(bad.lines, start: start, envelope: envelope) {
                throw TestFailure(description: "accepted custom program: \(code)")
            }
        }
    },
    TestCase(name: "emptyNameAndCommentsOnlyCodeAreInvalid") {
        try expect(SavedTestProgram(title: " \n").validationMessage != nil)
        try expect(SavedTestProgram(title: "Empty", code: "(only a comment)\n; nothing to send\n").validationMessage != nil)
        try expect(SavedTestProgram(title: "Dwell", code: "G4 P1").validationMessage == nil)
    },
    TestCase(name: "oldSavedProgramsDefaultToMotionChecks") {
        let program = SavedTestProgram(title: "Old check", code: "G4 P1")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(program)) as! [String: Any]
        json.removeValue(forKey: "kind")
        let restored = try JSONDecoder().decode(SavedTestProgram.self, from: JSONSerialization.data(withJSONObject: json))
        try expectEqual(restored.kind, .motionCheck)
        try expectEqual(restored.id, program.id)
    },
    TestCase(name: "setupProgramsUseGuidedCodeChecks") {
        let envelope = try MillEnvelope.from(realSettings).unwrapped()
        let setup = SavedTestProgram(title: "Probe Z", code: "G91\nG38.2 Z-2 F100\nG90\nG10 L20 P1 Z0", kind: .setup)
        let checked = try JobProgramCheck.clean(setup.lines, settings: realSettings, envelope: envelope).get()
        try expect(checked.lines.contains("G38.2Z-2F100"))
        try expect(checked.lines.contains("G10L20P1Z0"))
        for code in ["G20", "$RST=*", "G53 G0 Z-9999", "M3 S999999", "G10 L3 P1 X0",
                     "M3 S999999999999999999999999", "G10 L2 P999999999999999999999999 X0", "G10 L20 P1.5 X0"] {
            let bad = SavedTestProgram(title: "Bad setup", code: code, kind: .setup)
            if case .success = JobProgramCheck.clean(bad.lines, settings: realSettings, envelope: envelope) {
                throw TestFailure(description: "accepted setup: \(code)")
            }
        }
    },
    TestCase(name: "setupHomingRemainsFirstBeforeInjectedStartup") {
        let envelope = try MillEnvelope.from(realSettings).unwrapped()
        let setup = SavedTestProgram(title: "Home", code: "; Home first\n $H (home)\nG53 G0 X-40", kind: .setup)
        try expect(setup.homesFirst)
        let checked = try JobProgramCheck.clean(setup.lines, settings: realSettings, envelope: envelope).get()
        try expect(checked.startsWithHome)
        try expectEqual(Array(checked.lines.prefix(4)), ["$H", "G21", "G90", "M5"])
        var checksOnly = setup
        checksOnly.kind = .motionCheck
        try expect(!checksOnly.homesFirst)
        if case .success = ProgramCheck.clean(checksOnly.lines, start: Point3(x: -40, y: -10, z: -10), envelope: envelope) {
            throw TestFailure(description: "motion check accepted homing")
        }
    },
]
