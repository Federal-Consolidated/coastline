import CoastlineCore
import Foundation

let triageTests: [TestCase] = [
    TestCase(name: "tooBigNotesAreQuietWhenASmallerToolFollows") {
        func tool(_ d: Double) -> Tool {
            Tool(name: "\(d) flat", kind: .flatEndMill, diameter: d, shankDiameter: 3.175, flutes: 2,
                 fluteLength: 6, stickout: 15, overallLength: 38)
        }
        let al = MaterialLibrary.material(id: "al-6061")!
        func planned(_ kind: OperationKind, _ t: Tool) -> EngineClient.PlannedOperation {
            let op = Operation(kind: kind, toolID: t.id)
            return .init(operation: op, tool: t, data: op.cuttingData(tool: t, material: al))
        }
        let narrow = "58 pockets too narrow to rough with this 3.175 mm tool were left for a smaller one."
        let other = "This strategy found nothing to cut on this part."
        // A 1/16" pocket pass follows the 1/8": the 1/8"'s note is handled.
        let plan = [planned(.adaptive, tool(3.175)), planned(.adaptive, tool(1.5875))]
        let (w, n) = WarningTriage.split([narrow, other], at: 0, in: plan)
        try expectEqual(w, [other])
        try expectEqual(n, [narrow])
        // The last (smallest) tool: nothing smaller follows, so it stays a warning.
        try expectEqual(WarningTriage.split([narrow], at: 1, in: plan).warnings, [narrow])
        // A bigger tool later doesn't help.
        let up = [planned(.adaptive, tool(1.5875)), planned(.adaptive, tool(3.175))]
        try expectEqual(WarningTriage.split([narrow], at: 0, in: up).warnings, [narrow])
    },
]
