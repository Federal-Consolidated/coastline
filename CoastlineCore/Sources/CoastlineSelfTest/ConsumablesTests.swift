import CoastlineCore
import Foundation

private func flat(_ q: Int = 1, minutes: Double = 0) -> Tool {
    Tool(name: "1/4\" flat end mill", kind: .flatEndMill, diameter: 6.35, shankDiameter: 6.35, flutes: 3,
         fluteLength: 19, stickout: 28, overallLength: 63.5, quantity: q, cuttingMinutes: minutes)
}

let consumablesTests: [TestCase] = [
    TestCase(name: "everyBitGetsAnIDAndOldUsageMovesOntoTheFirst") {
        var inv = Inventory()
        inv.tools = [flat(3, minutes: 450), flat(0)]
        try expect(Consumables.normalize(&inv))
        let u = inv.tools[0].units ?? []
        try expectEqual(u.map(\.label), ["T-001", "T-002", "T-003"])
        try expect(abs(u[0].load - 0.5) < 1e-9 && u[0].minutes == 450 && u[1].load == 0, "450 of 900 aluminium minutes")
        try expect(inv.tools[1].units == nil, "not owned: no bits")
        try expect(!Consumables.normalize(&inv), "stable")
        // One more bit bought: a new label; two thrown away: the unused one goes, then the most worn retires.
        inv.tools[0].quantity = 4
        Consumables.normalize(&inv)
        try expectEqual(inv.tools[0].units?.last?.label, "T-004")
        inv.tools[0].quantity = 2
        Consumables.normalize(&inv)
        try expectEqual(Consumables.activeUnits(inv.tools[0]).map(\.label), ["T-001", "T-002"], "unused bits go first")
        try expectEqual(Consumables.find(label: "t-002", in: inv)?.unit.label, "T-002")
    },
    TestCase(name: "wearFollowsTheMaterialAndThePace") {
        var inv = Inventory()
        inv.tools = [flat(2)]
        Consumables.normalize(&inv)
        let id = inv.tools[0].id
        let al = MaterialLibrary.all.first { $0.family == .aluminium }!
        let steel = MaterialLibrary.all.first { $0.family == .steel }!
        let a = Consumables.addWear(minutes: 30, distance: 0, tool: id, unit: nil, material: al, pace: 1, toolSaver: false, date: Date(), in: &inv)!
        let b = Consumables.addWear(minutes: 30, distance: 0, tool: id, unit: inv.tools[0].units![1].id, material: steel, pace: 1,
                                    toolSaver: false, date: Date(), in: &inv)!
        try expect(b.load > a.load * 5, "steel wears far faster: \(a.load) \(b.load)")
        let brisk = ToolWear.life(tool: inv.tools[0], material: al, pace: 1.2)
        let saver = ToolWear.life(tool: inv.tools[0], material: al, pace: 1, toolSaver: true)
        try expect(brisk < 900 * 0.5 && saver > 900 * 1.8, "\(brisk) \(saver)")
    },
    TestCase(name: "forecastPutsAFreshBitOnTheFinish") {
        var inv = Inventory()
        inv.tools = [flat(2)]
        Consumables.normalize(&inv)
        inv.tools[0].units![0].load = 0.8  // T-001 dulling, T-002 fresh
        let t = inv.tools[0]
        let al = MaterialLibrary.material(id: "al-6061")!
        let f = Consumables.forecast([.init(program: 0, title: "Roughing", tool: t, minutes: 90, finishes: false),
                                      .init(program: 1, title: "Finishing", tool: t, minutes: 60, finishes: true)],
                                     inventory: inv, material: al, pace: 1, toolSaver: false)
        try expectEqual(f[0].unit?.label, "T-001", "roughing uses up the worn bit")
        try expect(f[0].wornMode)
        try expectEqual(f[1].unit?.label, "T-002", "the finish gets the fresh one")
        try expect(f[1].swappedFrom?.label == "T-001" && f[1].advice?.contains("Load T-002") == true, "\(f[1].advice ?? "")")
        // One bit only: no swap, an honest warning.
        var one = inv
        one.tools[0].quantity = 1
        one.tools[0].units!.removeLast()
        let g = Consumables.forecast([.init(program: 1, title: "Finishing", tool: one.tools[0], minutes: 60, finishes: true)],
                                     inventory: one, material: al, pace: 1, toolSaver: false)
        try expect(g[0].advice?.contains("no spare") == true && g[0].stage == .nearEnd, "\(g[0].advice ?? "")")
    },
    TestCase(name: "aWornBitRunsSlowerButKeepsItsChipLoad") {
        let t = flat()
        let al = MaterialLibrary.material(id: "al-6061")!
        var op = Operation(kind: .adaptive, toolID: t.id)
        let sharp = op.cuttingData(tool: t, material: al)
        op.bitWear = 0.95
        let worn = op.cuttingData(tool: t, material: al)
        try expect(worn.rpm < sharp.rpm && worn.stepover < sharp.stepover && worn.stepdown < sharp.stepdown)
        let chip = { (d: CuttingData) in d.feed / (d.rpm * 3) }
        try expect(abs(chip(worn) / chip(sharp) - 1) < 0.01, "chip per tooth kept: \(chip(sharp)) \(chip(worn))")
        op.bitWear = 0.3
        try expectEqual(op.cuttingData(tool: t, material: al).rpm, sharp.rpm, "a bit worn in cuts as planned")
        // Save tools: slower spindle, same chip, deep roughing.
        var saver = Operation(kind: .adaptive, toolID: t.id)
        saver.toolSaver = true
        let s = saver.cuttingData(tool: t, material: al)
        try expect(s.rpm < sharp.rpm && abs(chip(s) / chip(sharp) - 1) < 0.01 && s.stepdown > sharp.stepdown, "\(s.notes)")
        var tune = Tuning.preset(.fine)
        tune.toolSaver = true
        try expectEqual(tune.preset, .fine, "Save tools sits beside the presets")
        try expect(tune.apply(to: [Operation(kind: .contour)])[0].toolSaver == true)
    },
    TestCase(name: "lifeLearnsFromWhatTheUserReports") {
        var inv = Inventory()
        inv.tools = [flat(2)]
        Consumables.normalize(&inv)
        inv.tools[0].units![0].load = 0.5
        let t = inv.tools[0]
        Consumables.retire(unit: t.units![0].id, of: t.id, in: &inv)
        let f = inv.lifeLearning?.factor(for: inv.tools[0]) ?? 1
        try expect(f < 0.8 && f > 0.6, "worn out at half the estimate: shorter life, damped: \(f)")
        try expectEqual(inv.tools[0].quantity, 1)
        try expectEqual(Consumables.activeUnits(inv.tools[0]).map(\.label), ["T-002"])
        try expect(!Consumables.normalize(&inv), "a retired bit stays retired")
        // Wear shown is corrected by the factor.
        inv.tools[0].units![1].load = 0.3
        try expect(abs(Consumables.wear(inv.tools[0].units![1], tool: inv.tools[0], learning: inv.lifeLearning) - 0.3 / f) < 1e-9)
        // A break teaches nothing about wear.
        var b = Inventory()
        b.tools = [flat(1)]
        Consumables.normalize(&b)
        Consumables.retire(unit: b.tools[0].units![0].id, of: b.tools[0].id, broken: true, in: &b)
        try expect(b.lifeLearning == nil)
    },
    TestCase(name: "recordingAJobWearsTheBitThatCut") {
        var inv = Inventory()
        inv.tools = [flat(2)]
        Consumables.normalize(&inv)
        let t = inv.tools[0]
        var e = JournalEntry(partName: "Plate", materialID: "al-6061", stockDescription: "",
                             programs: [.init(title: "Rough", toolID: t.id, toolName: t.name, minutes: 450, distance: 0, unitID: t.units![1].id)],
                             measurements: [])
        e.pace = 1
        let notes = JobJournal.record(e, into: &inv)
        try expect(abs(inv.tools[0].units![1].load - 0.5) < 1e-9 && inv.tools[0].units![0].load == 0)
        try expect(inv.tools[0].cuttingMinutes == 450, "the tool's total still counts")
        try expect(notes.isEmpty, "50 % needs no note: \(notes)")
        try expectEqual(WearStage.of(0.7), .dulling)
        try expect(WearStage.nearEnd.effects(tool: Tool(name: "1 mm", kind: .flatEndMill, diameter: 1, shankDiameter: 3, flutes: 2, fluteLength: 3, stickout: 10, overallLength: 38),
                                             material: MaterialLibrary.material(id: "al-6061")!).contains { $0.contains("snap") })
    },
]
