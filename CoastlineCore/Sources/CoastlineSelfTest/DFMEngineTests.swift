import CoastlineCore
import Foundation
import simd

// The DFM check end to end: the reference coupon (resources/samples/dfm_coupon.step, made by
// scripts/make-dfm-coupon.py, which lists the known answers) through the real engine "analyse"
// RPC with access, then DFM.assess with the user's owned tools, collets and stock on the
// Desktop CNC rev 2 package (75 mm tool length, 8 mm shank). DFMTests covers the rules on
// synthetic values; this checks that the engine's faces, floors and holes produce them.

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

fileprivate func tool(_ name: String, _ kind: Tool.Kind, _ d: Double, _ shank: Double, _ flute: Double,
                      _ stick: Double, _ length: Double, part: String = "") -> Tool {
    var t = Tool(name: name, kind: kind, vendor: part.isEmpty ? "" : "Helical", partNumber: part, diameter: d,
                 shankDiameter: shank, flutes: kind == .drill || kind == .spotDrill ? 2 : 3, fluteLength: flute,
                 stickout: stick, overallLength: length, cornerRadius: kind == .bullNoseEndMill ? 0.5 : 0)
    if kind == .chamferMill { t.angle = 45 }
    return t
}

/// The user's owned tools (quantity 1, new), as listed in the inventory.
fileprivate let ownedTools: [Tool] = [
    tool("3/16\" flat end mill · Helical 48031", .flatEndMill, 4.7625, 4.7625, 9.525, 28.575, 50.8, part: "48031"),
    tool("1/4\" flat end mill · Helical 81400", .flatEndMill, 6.35, 6.35, 12.7, 28.575, 50.8, part: "81400"),
    tool("1/8\" flat end mill · Helical 03017", .flatEndMill, 3.175, 3.175, 6.35, 15.875, 38.1, part: "03017"),
    tool("1/16\" flat end mill · Titan USA TC10804", .flatEndMill, 1.5875, 3.175, 6.35, 15.875, 38.1, part: "TC10804"),
    tool("1/8\" ball end mill · Helical 17032", .ballEndMill, 3.175, 3.175, 9.525, 28.575, 50.8, part: "17032"),
    tool("1/4\" flat end mill · Helical 82720", .flatEndMill, 6.35, 6.35, 19.05, 41.275, 63.5, part: "82720"),
    tool("1/8\" chamfer mill · Helical 06015", .chamferMill, 3.175, 3.175, 1.5748, 28.575, 50.8, part: "06015"),
    tool("1/4\" drill", .drill, 6.35, 6.35, 31.75, 35.56, 76.2),
    tool("1/4\" spot drill", .spotDrill, 6.35, 6.35, 6.35, 30.48, 50.8),
    tool("1/8\" ball end mill · Helical 81674", .ballEndMill, 3.175, 3.175, 9.525, 28.575, 50.8, part: "81674"),
    tool("1/8\" chamfer mill · Titan USA TC87804", .chamferMill, 3.175, 3.175, 1.3462, 15.875, 38.1, part: "TC87804"),
    tool("1/32\" ball end mill", .ballEndMill, 0.79375, 3.175, 1.5875, 15.875, 38.1),
    tool("1/16\" flat end mill · Titan USA TC99504", .flatEndMill, 1.5875, 3.175, 6.35, 15.875, 38.1, part: "TC99504"),
    tool("1/8\" flat end mill · Helical 81635", .flatEndMill, 3.175, 3.175, 9.525, 28.575, 50.8, part: "81635"),
    tool("3/16\" flat end mill · Helical 30077", .flatEndMill, 4.7625, 4.7625, 7.9375, 28.575, 50.8, part: "30077"),
    tool("1/4\" bull nose end mill · Helical 83457", .bullNoseEndMill, 6.35, 6.35, 9.525, 28.575, 50.8, part: "83457"),
    tool("1/4\" flat end mill · Helical 30137", .flatEndMill, 6.35, 6.35, 9.525, 28.575, 50.8, part: "30137"),
]

fileprivate let block = StockItem(materialID: "al-6061", sizeX: 203.2, sizeY: 50.8, sizeZ: 50.8)
fileprivate let plate = StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20)

fileprivate func ownedInventory() -> Inventory {
    var inv = Inventory()
    inv.tools = ownedTools
    inv.accessories = [Accessory(name: "ER-11 1/8\"", kind: .collet, size: 3.175),
                       Accessory(name: "ER-11 1/4\"", kind: .collet, size: 6.35)]
    inv.stock = [block, plate]
    return inv
}

fileprivate func owned(_ part: String) -> Tool { ownedTools.first { $0.partNumber == part }! }

/// The job machine: the Desktop CNC rev 2 package, not the legacy profile (76.2 mm tools).
fileprivate func desktopCNC() throws -> MachineProfile {
    try MachineDefinitionPackage.load(from: repoRoot.appendingPathComponent("resources/machines/desktop-cnc")).definition.profile
}

/// The coupon as the app sets it up: import bounds, a facing and spin, no top allowance, the
/// owned block along the work axes stockChoices picks; then analysed with access.
fileprivate struct CouponRun: Sendable {
    var setup: Setup
    var partMin: SIMD3<Double>
    var partMax: SIMD3<Double>
    var analysis: PartAnalysis
    var seconds: Double

    func input(stock: StockItem? = block, inventory: Inventory = ownedInventory(), machine: MachineProfile) -> DFM.Input {
        var s = setup
        if let stock, stock.id != block.id { s.stockAxes = Setup.defaultStockAxes(stock) }
        return DFM.Input(analysis: analysis, setup: s, partMin: partMin, partMax: partMax, stock: stock,
                         inventory: inventory, machine: machine)
    }
}

/// One engine and one import for every case: the orientation only changes the transform.
fileprivate let couponPart: Result<(EngineClient, MeshData), Error> = Result {
    let e = try engine()
    let url = repoRoot.appendingPathComponent("resources/samples/dfm_coupon.step")
    return (e, try blocking { try await e.importPart(url) })
}

/// nil: the app's default orientation for the import bounds.
fileprivate func analyseCoupon(_ orientation: (Setup.Facing, Int)?) throws -> CouponRun {
    let (e, mesh) = try couponPart.get()
    let lo = SIMD3(mesh.boundsMin.x, mesh.boundsMin.y, mesh.boundsMin.z)
    let hi = SIMD3(mesh.boundsMax.x, mesh.boundsMax.y, mesh.boundsMax.z)
    var s = Setup()
    s.topAllowance = 0
    (s.facing, s.spin) = orientation ?? Setup.defaultOrientation(partMin: lo, partMax: hi)
    let (rlo, rhi) = s.rotatedPartBounds(min: lo, max: hi)
    let choice = JobLibraryGuide.stockChoices(partSize: rhi - rlo, inventory: ownedInventory(), preferredAxes: s.stockAxes)
    s.stockAxes = try unwrap(choice.first { $0.stock.id == block.id }).axes
    let t = s.partToWork(partMin: lo, partMax: hi)
    let id = mesh.partID
    // Not counting time the computer sleeps: a wall clock once read 840 s for a 1.5 s call.
    let clock = SuspendingClock(), start = clock.now
    let a = try blocking { try await e.analyse(partID: id, transform: t, access: true) }
    return CouponRun(setup: s, partMin: lo, partMax: hi, analysis: a, seconds: Double((clock.now - start) / .milliseconds(1)) / 1000)
}

fileprivate let defaultRun = Result { try analyseCoupon(nil) }
/// Turned so the part's own +Z (the side with the F7 groove) faces the spindle, long along Y.
fileprivate let turnedRun = Result { () throws -> CouponRun in
    let spin = (0..<4).first { spin in
        var s = Setup()
        (s.facing, s.spin) = (.plusZ, spin)
        let (lo, hi) = s.rotatedPartBounds(min: .zero, max: SIMD3(203.2, 50.8, 50.8))
        return hi.y - lo.y > hi.x - lo.x
    }!
    return try analyseCoupon((.plusZ, spin))
}

fileprivate func finding(_ id: String, _ all: [DFMFinding], line: UInt = #line) throws -> DFMFinding {
    guard let f = all.first(where: { $0.id == id }) else {
        throw TestFailure(description: "DFMEngineTests.swift:\(line) no finding \"\(id)\" in \(all.map(\.id))")
    }
    return f
}

/// Every word a finding can show.
fileprivate func allText(_ fs: [DFMFinding], _ inv: Inventory) -> String {
    fs.flatMap { [$0.title, $0.summary] + $0.details + $0.remedies.flatMap { [$0.title, $0.title(in: inv)] } }.joined(separator: "\n")
}

fileprivate func dump(_ fs: [DFMFinding]) -> String {
    fs.map { "[\($0.category)] \($0.id): \($0.title) | \($0.summary) | \($0.details.joined(separator: " / ")) | faces \($0.faces) | \($0.remedies)" }
        .joined(separator: "\n")
}

/// Findings about geometry carry faces to light up; the tool list and the shape measures don't.
fileprivate let faceless: Set<String> = ["tools", "tools-info", "corner", "concave", "thin", "exact"]

let dfmEngineTests: [TestCase] = [
    TestCase(name: "couponThroughTheEngineGivesTheKnownAnswers") {
        let run = try defaultRun.get()
        // The first call also loads the engine's CAM libraries; the second is the steady cost.
        let again = try analyseCoupon(nil)
        print("    analyse with access, coupon: \(String(format: "%.2f", run.seconds)) s first, \(String(format: "%.2f", again.seconds)) s again")
        try expect(again.analysis == run.analysis, "the same part and setup give the same analysis")
        let m = try desktopCNC()
        try expectEqual(m.maxToolLength, 75)
        try expectEqual(m.maxShankDiameter, 8)
        // The default orientation turns the coupon's +Y feature face to the spindle (spin 1).
        try expectEqual(run.setup.facing, .plusY)
        let access = try unwrap(run.analysis.access)
        try expect(!access.triangles.isEmpty && !access.faceTriangles.isEmpty)
        let inv = ownedInventory()
        let all = DFM.assess(run.input(machine: m))
        let text = dump(all)
        // Stock: the owned block, zero allowance, the six outer faces stay as supplied.
        let stock = try finding("stock", all)
        try expectEqual(stock.category, .ok, text)
        try expect(stock.summary.contains("Exact size") && stock.summary.contains("6 faces"), stock.summary)
        try expectEqual(stock.faces.count, 6, text)
        try expectEqual(Set(stock.faces.compactMap { access.face($0)?.boundary }), ["+x", "-x", "+y", "-y", "+z", "-z"])
        try expect(stock.details.contains("Kept as supplied: all six faces.") && stock.details.contains("Stock to cut: none."), text)
        try expect(!all.contains { $0.id == "back" || $0.id == "profile" }, text)
        // F1 pocket 20 x 30, 8 deep: the 1/4" flat reaches.
        let floors = access.floors.sorted { $0.width > $1.width }
        try expectEqual(floors.count, 3, "\(access.floors)")
        let f1 = try finding("floor-\(floors[0].face)", all)
        try expectEqual(f1.category, .ok, text)
        try expectEqual(f1.title, "Pocket 20 x 30 mm, 8 deep")
        try expect(f1.summary.contains("1/4\" flat"), f1.summary)
        // F2 stadium 6 x 20, 30 deep: only the 1/8" 81635 at 31 mm stick-out, and its shank rubs.
        let f2 = try finding("floor-\(floors[1].face)", all)
        try expectEqual(f2.category, .missingResource, text)
        try expect(f2.title.hasPrefix("Pocket 6 x 20 mm, 30 deep") || f2.title.hasPrefix("Slot 6 x 20 mm"), f2.title)
        try expect(f2.remedies.contains(.setStickout(toolID: owned("81635").id, minimum: 31)), "\(f2.remedies)")
        try expect(f2.remedies.contains(.addCollet(4.7625)), "\(f2.remedies)")
        try expect(f2.summary.contains("81635") && f2.summary.contains("rubs"), f2.summary)
        try expect(f2.details.contains { $0.contains("03017") && $0.contains("collet nut") }, "\(f2.details)")
        try expect(f2.details.contains { $0.hasPrefix("1/4\" flat") && $0.contains("too wide") }, "\(f2.details)")
        try expect(f2.details.contains { $0.hasPrefix("3/16\" flat") && $0.contains("no collet") }, "\(f2.details)")
        // F3 slot 2 x 15, 8 deep: the 1/16" shanks stop them at 6.35 mm.
        let f3 = try finding("floor-\(floors[2].face)", all)
        try expectEqual(f3.category, .missingResource, text)
        try expect(f3.title.hasPrefix("Slot 2 x 15 mm"), f3.title)
        try expect(f3.details.contains { $0.hasPrefix("1/16\" flat") && $0.contains("shank wider than the cutter stops it at 6.35 mm") }, "\(f3.details)")
        try expect(f3.summary.contains("2 mm wide and 8 mm deep"), f3.summary)
        try expect(f3.remedies.contains { if case .addTool(let t) = $0 { t.diameter < 2 && t.fluteLength >= 8.5 } else { false } }, "\(f3.remedies)")
        // F4 blind hole 6.35, 20 deep: the owned drill is over the 75 mm limit; the 81635 bores it but rubs.
        try expectEqual(access.holes.count, 1, "\(access.holes)")
        let hole = access.holes[0]
        let f4 = try finding("hole-\(hole.faces[0])", all)
        try expectEqual(f4.category, .missingResource, text)
        try expectEqual(f4.title, "Hole 6.35 mm, 20 deep")
        try expect(f4.details.contains { $0.hasPrefix("1/4\" drill") && $0.contains("over the 75 mm limit") }, "\(f4.details)")
        try expect(f4.summary.contains("81635") && f4.summary.contains("rubs"), f4.summary)
        // F5 back recess: the back side, not marked solved.
        let regions = access.regions
        try expectEqual(regions.count, 3, "\(regions)")
        let back = try unwrap(regions.first { $0.access == .oppositeSide })
        let f5 = try finding("region-\(back.faces[0])", all)
        try expectEqual(f5.category, .setupChange, text)
        try expectEqual(f5.title, "Cut from the back")
        try expect(f5.details.contains { $0.contains("not checked") }, "\(f5.details)")
        try expectEqual(back.directions, ["-z"])
        // Reach from the back is measured: 3 mm in from the back face, 20 mm across.
        try expectEqual(back.sides.map(\.side), ["-z"])
        try expectEqual(f5.measure, "From the back: 3 mm deep, 20 mm wide.")
        try expect(f5.summary.contains("only from the back") && f5.summary.contains("reaches it"), f5.summary)
        // F6 closed cavity under the T-slot neck: no straight path.
        let closed = try unwrap(regions.first { $0.access == .noAccess })
        let f6 = try finding("region-\(closed.faces[0])", all)
        try expectEqual(f6.category, .notSupported, text)
        try expect(closed.directions.isEmpty)
        // F7 side groove: one side direction, in plain words.
        let side = try unwrap(regions.first { $0.access == .otherDirection })
        try expectEqual(side.directions.count, 1, "\(side)")
        let f7 = try finding("region-\(side.faces[0])", all)
        try expectEqual(f7.category, .setupChange, text)
        try expectEqual(f7.title, "Cut from the \(DFM.sideName(side.directions[0]))")
        try expect(f7.summary.contains(DFM.sideName(side.directions[0])), f7.summary)
        try expectEqual(side.sides.map(\.side), side.directions)
        try expect(f7.measure?.hasPrefix("From the \(DFM.sideName(side.directions[0])): 3 mm deep") == true, f7.measure ?? "")
        // Owned tools left out, with why.
        let tools = try finding("tools", all)
        try expectEqual(tools.category, .missingResource, text)
        try expect(tools.remedies.contains(.addCollet(4.7625)), "\(tools.remedies)")
        try expect(tools.details.contains { $0.hasPrefix("3/16\" flat") && $0.contains("no collet") }, "\(tools.details)")
        try expect(tools.details.contains { $0.hasPrefix("1/4\" drill") && $0.contains("over the 75 mm limit") }, "\(tools.details)")
        try expect(!all.contains { $0.id == "tools-info" }, text)
        // The tightest corner is the slot's R1 ends; the drill point is not a curve for a ball mill.
        let corner = try finding("corner", all)
        try expect(corner.category == .ok && corner.title == "Inside corners R1 mm", "\(corner)")
        try expectEqual(run.analysis.minConcaveRadius, nil)
        try expect(!all.contains { $0.id == "concave" }, text)
        // Never a smaller part, never "a flip solves it".
        let words = allText(all, inv)
        try expect(!words.localizedCaseInsensitiveContains("scale") && !words.localizedCaseInsensitiveContains("flips the part"), words)
        // Every finding about geometry lights up real triangles.
        for f in all where !faceless.contains(f.id) {
            try expect(!f.faces.isEmpty && !access.triangles(forFaces: f.faces).isEmpty, "\(f.id) has nothing to highlight")
            try expect(access.bounds(forFaces: f.faces) != nil)
        }
        // Every reach finding carries its measurement; every problem says what to do.
        try expect([f1, f2, f3, f4].allSatisfy { $0.measure != nil }, "measure")
        try expect(all.filter { $0.category != .ok }.allSatisfy { $0.fix != nil }, "\(all.filter { $0.category != .ok && $0.fix == nil }.map(\.id))")
        try expectEqual(all.map(\.category), all.map(\.category).sorted())
    },
    TestCase(name: "smallStockOffersTheOwnedBlock") {
        let run = try defaultRun.get()
        let inv = ownedInventory()
        let all = DFM.assess(run.input(stock: plate, machine: try desktopCNC()))
        let stock = try finding("stock", all)
        try expectEqual(stock.category, .missingResource, dump(all))
        try expectEqual(stock.title, "Stock too small")
        let use = stock.remedies.compactMap { r -> (UUID, [Int])? in if case .useStock(let id, let axes) = r { (id, axes) } else { nil } }
        try expectEqual(use.map(\.0), [block.id], "\(stock.remedies)")
        // The offered axes hold the part as set up.
        var s = run.setup
        s.stockAxes = use[0].1
        let (lo, hi) = s.rotatedPartBounds(min: run.partMin, max: run.partMax)
        let raw = s.rawStockSize(block), need = hi - lo
        try expect((0..<3).allSatisfy { raw[$0] + 1e-6 >= need[$0] }, "\(raw) for \(need)")
        try expect(stock.remedies[0].title(in: inv).contains("203.2 x 50.8 x 50.8"), stock.remedies[0].title(in: inv))
        // Faces sticking out of the stock light up.
        try expect(!stock.faces.isEmpty && !(run.analysis.access?.triangles(forFaces: stock.faces).isEmpty ?? true))
        try expect(!all.contains { $0.id == "back" || $0.id == "profile" })
    },
    TestCase(name: "withoutTheLongEightTheDeepPocketChanges") {
        let run = try defaultRun.get()
        let m = try desktopCNC()
        let access = try unwrap(run.analysis.access)
        let deep = try unwrap(access.floors.first { abs($0.width - 6) < 0.05 })
        let before = try finding("floor-\(deep.face)", DFM.assess(run.input(machine: m)))
        var inv = ownedInventory()
        inv.tools.removeAll { $0.partNumber == "81635" }
        let all = DFM.assess(run.input(inventory: inv, machine: m))
        let after = try finding("floor-\(deep.face)", all)
        try expect(after != before)
        try expect(!after.remedies.contains { if case .setStickout = $0 { true } else { false } }, "\(after.remedies)")
        try expect(!after.summary.contains("81635") && !after.details.contains { $0.contains("81635") }, "\(after)")
        try expectEqual(after.category, .missingResource, dump(all))
        try expect(after.remedies.contains(.addCollet(4.7625)), "\(after.remedies)")
        // The legacy machine profile (76.2 mm tools) takes the owned drill: the hole is OK.
        let hole = try unwrap(access.holes.first)
        let legacy = try finding("hole-\(hole.faces[0])", DFM.assess(run.input(machine: .standard)))
        try expectEqual(legacy.category, .ok, "\(legacy)")
        try expect(legacy.summary.contains("1/4\" drill"), legacy.summary)
    },
    TestCase(name: "turningThePartChangesTheFindings") {
        let normal = try defaultRun.get(), turned = try turnedRun.get()
        print("    analyse with access, coupon turned: \(String(format: "%.2f", turned.seconds)) s")
        let m = try desktopCNC()
        try expect(turned.setup.facing != normal.setup.facing)
        let a = DFM.assess(normal.input(machine: m)), b = DFM.assess(turned.input(machine: m))
        func key(_ fs: [DFMFinding]) -> Set<String> { Set(fs.map { "\($0.id) \($0.category)" }) }
        try expect(key(a) != key(b), dump(b))
        // Still the same block, exactly: the faces stay as supplied.
        try expectEqual(try finding("stock", b).category, .ok, dump(b))
        // The side groove now faces the spindle: it is no longer a region needing another position.
        let side = try unwrap(normal.analysis.access?.regions.first { $0.access == .otherDirection })
        try expect(!(turned.analysis.access?.regions.contains { Set($0.faces) == Set(side.faces) && $0.access == .otherDirection } ?? true), dump(b))
    },
    TestCase(name: "quiddityNamesTheCouponFeatures") {
        let (e, _) = try couponPart.get()
        let url = repoRoot.appendingPathComponent("resources/samples/dfm_coupon.step")
        guard let named = try blocking({ try await e.recognise(path: url) }) else { throw Skip(reason: "quiddity not installed in the engine") }
        let labels = named.map(\.label)
        try expect(labels.contains("Drilled hole ⌀6.35 mm") && labels.contains("Pocket 20 x 30 mm") && labels.contains("Pocket 3 x 40 mm"), "\(labels)")
        // The same face numbers as the analysis: the side groove's region takes its name.
        let run = try defaultRun.get()
        var input = run.input(machine: try desktopCNC())
        input.named = named
        let side = try unwrap(run.analysis.access?.regions.first { $0.access == .otherDirection })
        let f7 = try unwrap(DFM.assess(input).first { $0.id == "region-\(side.faces[0])" })
        try expectEqual(f7.title, "Pocket 3 x 40 mm: cut from the \(DFM.sideName(side.directions[0]))")
    },
]
