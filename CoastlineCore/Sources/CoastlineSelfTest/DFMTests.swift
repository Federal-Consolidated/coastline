import CoastlineCore
import Foundation
import simd

// The DFM check on synthetic engine results that reproduce the reference coupon
// (resources/samples/dfm_coupon.step, scripts/make-dfm-coupon.py) with the user's real tools,
// collets and stock, on the Desktop CNC rev 2 limits (75 mm tool length, 8 mm shank).

fileprivate func tool(_ name: String, _ kind: Tool.Kind, _ d: Double, _ shank: Double, _ flute: Double,
                      _ stick: Double, _ length: Double, part: String = "") -> Tool {
    var t = Tool(name: name, kind: kind, vendor: part.isEmpty ? "" : "Helical", partNumber: part, diameter: d,
                 shankDiameter: shank, flutes: kind == .drill || kind == .spotDrill ? 2 : 3, fluteLength: flute,
                 stickout: stick, overallLength: length, cornerRadius: kind == .bullNoseEndMill ? 0.5 : 0)
    if kind == .chamferMill { t.angle = 45 }
    return t
}

/// The user's owned tools (quantity 1, new), as listed in the inventory.
fileprivate let realTools: [Tool] = [
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

fileprivate func named(_ part: String, in inv: Inventory) -> Tool { inv.tools.first { $0.partNumber == part }! }
fileprivate let block = StockItem(materialID: "al-6061", sizeX: 203.2, sizeY: 50.8, sizeZ: 50.8)
fileprivate let plate = StockItem(materialID: "al-6061", sizeX: 150, sizeY: 80, sizeZ: 20)

fileprivate func realInventory() -> Inventory {
    var inv = Inventory()
    inv.tools = realTools
    inv.accessories = [Accessory(name: "ER-11 1/8\"", kind: .collet, size: 3.175),
                       Accessory(name: "ER-11 1/4\"", kind: .collet, size: 6.35)]
    inv.stock = [block, plate]
    return inv
}

/// Desktop CNC rev 2: the legacy profile with the package's tool limits.
fileprivate func desktopCNC() -> MachineProfile {
    var m = MachineProfile.standard
    m.maxToolLength = 75
    m.maxShankDiameter = 8
    return m
}

/// The coupon as the engine measures it (work frame, tool from +Z, feature face at Z 0):
/// 50.8 up (X) x 203.2 along (Y) x 50.8 deep (Z).
fileprivate func couponAccess() -> PartAccess {
    let lo = SIMD3<Double>(-25.4, -101.6, -50.8), hi = SIMD3<Double>(25.4, 101.6, 0)
    var faces = [
        PartAccess.Face(index: 0, area: 10322, boundary: "+z", planeOffset: 0, access: .thisSide, visible: ["+z": 1]),
        PartAccess.Face(index: 1, area: 10322, boundary: "-z", planeOffset: -50.8, access: .oppositeSide, visible: ["+z": 0, "-z": 1]),
        PartAccess.Face(index: 2, area: 10322, boundary: "+x", planeOffset: 25.4, access: .thisSide, visible: ["+z": 1]),
        PartAccess.Face(index: 3, area: 10322, boundary: "-x", planeOffset: -25.4, access: .thisSide, visible: ["+z": 1]),
        PartAccess.Face(index: 4, area: 2581, boundary: "+y", planeOffset: 101.6, access: .thisSide, visible: ["+z": 1]),
        PartAccess.Face(index: 5, area: 2581, boundary: "-y", planeOffset: -101.6, access: .thisSide, visible: ["+z": 1]),
    ]
    for k in [10, 20, 30, 40, 41] { faces.append(PartAccess.Face(index: k, access: .thisSide)) }
    for k in 50...53 { faces.append(PartAccess.Face(index: k, access: .oppositeSide)) }
    for k in 60...63 { faces.append(PartAccess.Face(index: k, kind: "other", access: .noAccess)) }
    for k in 70...74 { faces.append(PartAccess.Face(index: k, access: .otherDirection, visible: ["+z": 0, "-z": 0, "+x": 1])) }
    return PartAccess(
        faces: faces,
        regions: [
            // F5: back recess 20 x 20, 3 deep.
            PartAccess.Region(faces: [50, 51, 52, 53], area: 640, access: .oppositeSide, directions: ["-z"],
                              min: SIMD3(-10, 35, -50.8), max: SIMD3(10, 55, -47.8)),
            // F6: the closed T-slot's cavity under its neck.
            PartAccess.Region(faces: [60, 61, 62, 63], area: 900, access: .noAccess,
                              min: SIMD3(-6, 48, -9), max: SIMD3(6, 84, -5)),
            // F7: side groove 3 x 3 x 40 in the upper long side.
            PartAccess.Region(faces: [70, 71, 72, 73, 74], area: 380, access: .otherDirection, directions: ["+x"],
                              min: SIMD3(22.4, -20, -6.5), max: SIMD3(25.4, 20, -3.5)),
        ],
        floors: [
            // F1: pocket 20 x 30, 8 deep, R4.
            PartAccess.Floor(face: 10, z: -8, area: 586, width: 20, wallDepth: 8, holderDepth: 9,
                             min: SIMD3(-10, -85, -8), max: SIMD3(10, -55, -8)),
            // F2: stadium 6 x 20, 30 deep.
            PartAccess.Floor(face: 20, z: -30, area: 112, width: 6, wallDepth: 30, holderDepth: 31,
                             min: SIMD3(-3, -45, -30), max: SIMD3(3, -25, -30)),
            // F3: stadium 2 x 15, 8 deep.
            PartAccess.Floor(face: 30, z: -8, area: 29, width: 2, wallDepth: 8, holderDepth: 9,
                             min: SIMD3(-1, -15, -8), max: SIMD3(1, 0, -8)),
        ],
        holes: [
            // F4: blind 6.35 drilled hole, 20 deep, 118° cone bottom.
            PartAccess.Hole(faces: [40, 41], x: 0, y: 15, diameter: 6.35, zTop: 0, zBottom: -20, through: false,
                            access: .thisSide, holderDepth: 21),
        ],
        partMin: lo, partMax: hi)
}

fileprivate func couponSetup(_ stock: StockItem) -> Setup {
    var s = Setup()
    s.topAllowance = 0
    s.stockAxes = stock.id == block.id ? [1, 0, 2] : Setup.defaultStockAxes(stock)
    return s
}

fileprivate func couponInput(stock: StockItem? = block, inventory: Inventory = realInventory(),
                             machine: MachineProfile = desktopCNC(), twoSided: Bool = false) -> DFM.Input {
    let analysis = PartAnalysis(minCornerRadius: 1, undercutArea: 1200, depth: 50.8, access: couponAccess())
    return DFM.Input(analysis: analysis, setup: couponSetup(stock ?? block), partMin: .zero, partMax: SIMD3(50.8, 203.2, 50.8),
                     stock: stock, inventory: inventory, machine: machine, twoSided: twoSided)
}

fileprivate func finding(_ id: String, _ all: [DFMFinding]) throws -> DFMFinding {
    try unwrap(all.first { $0.id == id }, line: #line)
}

/// Every word a finding can show, for the wording checks.
fileprivate func allText(_ fs: [DFMFinding], _ inv: Inventory) -> String {
    fs.flatMap { [$0.title, $0.summary] + $0.details + $0.remedies.flatMap { [$0.title, $0.title(in: inv)] } }.joined(separator: "\n")
}

let dfmTests: [TestCase] = [
    TestCase(name: "couponFindingsMatchTheKnownAnswers") {
        let inv = realInventory()
        let all = DFM.assess(couponInput())
        let text = allText(all, inv)
        // Stock: exact size, zero allowance, all six outer faces kept.
        let stock = try finding("stock", all)
        try expectEqual(stock.category, .ok, text)
        try expect(stock.summary.contains("Exact size") && stock.summary.contains("6 faces"), stock.summary)
        try expectEqual(Set(stock.faces), Set(0...5))
        try expect(stock.details.contains("Kept as supplied: all six faces.") && stock.details.contains("Stock to cut: none."), "\(stock.details)")
        try expect(!all.contains { $0.id == "back" || $0.id == "profile" }, text)
        // F1: the 1/4" flat reaches.
        let f1 = try finding("floor-10", all)
        try expectEqual(f1.category, .ok, "\(f1)")
        try expect(f1.title == "Pocket 20 x 30 mm, 8 deep", f1.title)
        try expect(f1.summary.contains("1/4\" flat"), f1.summary)
        // F2: only the 1/8" 81635 with 31 mm stick-out, and its shank rubs; a 3/16" collet would help.
        let f2 = try finding("floor-20", all)
        try expectEqual(f2.category, .missingResource, "\(f2)")
        let longFlat = named("81635", in: inv)
        try expect(f2.remedies.contains(.setStickout(toolID: longFlat.id, minimum: 31)), "\(f2.remedies)")
        try expect(f2.remedies.contains(.showTool(longFlat.id)) && f2.remedies.contains(.addCollet(4.7625)), "\(f2.remedies)")
        try expect(f2.summary.contains("81635") && f2.summary.contains("rubs"), f2.summary)
        try expect(f2.details.contains { $0.contains("03017") && $0.contains("collet nut") }, "\(f2.details)")
        try expect(f2.details.contains { $0.hasPrefix("1/4\" flat") && $0.contains("too wide") }, "\(f2.details)")
        try expect(f2.details.contains { $0.hasPrefix("3/16\" flat") && $0.contains("no collet") }, "\(f2.details)")
        // F3: the 1/16" shanks stop them at 6.35 mm.
        let f3 = try finding("floor-30", all)
        try expectEqual(f3.category, .missingResource, "\(f3)")
        try expect(f3.title.hasPrefix("Slot 2 x 15 mm"), f3.title)
        try expect(f3.details.contains { $0.hasPrefix("1/16\" flat") && $0.contains("shank wider than the cutter stops it at 6.35 mm") }, "\(f3.details)")
        try expect(f3.summary.contains("2 mm wide and 8 mm deep") && f3.summary.contains("fits this machine"), f3.summary)
        // Not owning a tool doesn't stop the job: Coastline specifies one that fits the machine,
        // to add to the library as a tool to buy.
        guard case .addTool(let slotTool)? = f3.remedies.first else { throw TestFailure(description: "\(f3.remedies)") }
        try expect(slotTool.kind == .flatEndMill && slotTool.diameter < 2 && slotTool.fluteLength >= 8.5, "\(slotTool)")
        try expect(slotTool.overallLength <= 75 && slotTool.shankDiameter <= 8 && slotTool.quantity == 0 && slotTool.isSuggestion, "\(slotTool)")
        try expect(realInventory().colletSizes.contains { abs($0 - slotTool.shankDiameter) < 0.01 }, "a shank you have a collet for")
        try expect(f3.fix?.contains("to buy") == true && f3.details.contains { $0.hasPrefix("Coastline suggests:") }, "\(f3)")
        // Once added it is on your list: the same tool, now "Buy".
        var listed = couponInput()
        listed.inventory.tools.append(slotTool)
        let again = try finding("floor-30", DFM.assess(listed))
        try expect(again.remedies.contains(.buyTool(slotTool.id)) && !again.remedies.contains(.addTool(slotTool)), "\(again.remedies)")
        try expect(again.fix?.contains("on your list") == true, again.fix ?? "")
        // F4: the drill is over the 75 mm limit; the 1/8" 81635 bores it but rubs.
        let f4 = try finding("hole-40", all)
        try expectEqual(f4.category, .missingResource, "\(f4)")
        try expect(f4.title == "Hole 6.35 mm, 20 deep", f4.title)
        try expect(f4.details.contains { $0.hasPrefix("1/4\" drill") && $0.contains("over the 75 mm limit") }, "\(f4.details)")
        try expect(f4.summary.contains("81635") && f4.summary.contains("rubs") && !f4.summary.contains("stick-out"), f4.summary)
        try expect(f4.remedies.contains(.showTool(longFlat.id)) && f4.remedies.contains(.addCollet(4.7625)), "\(f4.remedies)")
        try expectEqual(f4.faces, [40, 41])
        // F5: the back side, not marked solved.
        let f5 = try finding("region-50", all)
        try expectEqual(f5.category, .setupChange)
        try expectEqual(f5.title, "Needs the back side")
        try expect(f5.summary.contains("not checked"), f5.summary)
        try expectEqual(f5.remedies, [.reviewSetups])
        // F6: closed cavity.
        let f6 = try finding("region-60", all)
        try expectEqual(f6.category, .notSupported)
        try expectEqual(f6.faces, [60, 61, 62, 63])
        // F7: one side direction, in plain words.
        let f7 = try finding("region-70", all)
        try expectEqual(f7.category, .setupChange)
        try expect(f7.summary.contains("upper side"), f7.summary)
        try expect(f7.details.contains { $0.contains("not checked") }, "\(f7.details)")
        // Owned tools left out, with why.
        let tools = try finding("tools", all)
        try expectEqual(tools.category, .missingResource)
        try expect(tools.remedies.contains(.addCollet(4.7625)), "\(tools.remedies)")
        try expect(tools.remedies.contains(.showTool(inv.tools.first { $0.kind == .drill }!.id)), "\(tools.remedies)")
        try expect(tools.details.contains { $0.hasPrefix("3/16\" flat") && $0.contains("no collet") }, "\(tools.details)")
        try expect(tools.details.contains { $0.hasPrefix("1/4\" drill") && $0.contains("76.2 mm long") }, "\(tools.details)")
        try expect(!all.contains { $0.id == "tools-info" }, text)
        // The tightest corner (R1, the slot ends) takes the 1/16" flat.
        try expectEqual(try finding("corner", all).category, .ok)
        // Sorted by category, the blocking ones first.
        try expectEqual(all.map(\.category), all.map(\.category).sorted())
        try expectEqual(all.first?.category, .notSupported)
        // Every reach finding carries its measurement; every problem says what to do.
        try expect([f1, f2, f3, f4].allSatisfy { $0.measure != nil }, "measure")
        try expect(all.filter { $0.category != .ok }.allSatisfy { $0.fix != nil }, "\(all.filter { $0.category != .ok && $0.fix == nil }.map(\.id))")
    },
    TestCase(name: "neverScalesOrClaimsAFlipSolvesAccess") {
        let inv = realInventory()
        var texts = [allText(DFM.assess(couponInput()), inv), allText(DFM.assess(couponInput(stock: plate)), inv),
                     allText(DFM.assess(couponInput(twoSided: true)), inv), allText(DFM.assess(couponInput(stock: nil)), inv)]
        let legacy = Feasibility.assess(PartAnalysis(undercutArea: 50, depth: 50.8), inventory: inv,
                                        partSize: SIMD3(50.8, 203.2, 50.8), stockSize: SIMD3(80, 150, 20))
        texts.append(legacy.map(\.message).joined(separator: "\n"))
        let big = Feasibility.assess(PartAnalysis(), inventory: inv, partSize: SIMD3(500, 500, 500), stockSize: SIMD3(600, 600, 600))
        texts.append(big.map(\.message).joined(separator: "\n"))
        for t in texts {
            try expect(!t.localizedCaseInsensitiveContains("scale"), t)
            try expect(!t.localizedCaseInsensitiveContains("flip"), t)
            try expect(!t.contains("resiz"), t)
        }
        try expect(legacy.contains { $0.message.contains("doesn't fit this stock") && $0.message.contains("too small") })
        try expect(big.contains { $0.message.contains("machine is too small") })
    },
    TestCase(name: "smallStockOffersOwnedStockThatFits") {
        let inv = realInventory()
        let all = DFM.assess(couponInput(stock: plate))
        let stock = try finding("stock", all)
        try expectEqual(stock.category, .missingResource)
        try expectEqual(stock.title, "Stock too small")
        let use = stock.remedies.compactMap { r -> (UUID, [Int])? in if case .useStock(let id, let axes) = r { (id, axes) } else { nil } }
        try expectEqual(use.map(\.0), [block.id], "\(stock.remedies)")
        // The offered orientation holds the part (50.8 up, 203.2 along, 50.8 deep).
        var s = couponSetup(block)
        s.stockAxes = use[0].1
        let raw = s.rawStockSize(block)
        try expect(raw.x >= 50.8 - 1e-6 && raw.y >= 203.2 - 1e-6 && raw.z >= 50.8 - 1e-6, "\(raw)")
        try expect(stock.remedies[0].title(in: inv).contains("203.2 x 50.8 x 50.8"), stock.remedies[0].title(in: inv))
        try expect(stock.summary.contains("30.8"), stock.summary)
        // No stock-dependent findings on a stock that doesn't hold the part.
        try expect(!all.contains { $0.id == "back" || $0.id == "profile" })
        // Back on the block: OK again (changing stock updates the finding).
        try expectEqual(try finding("stock", DFM.assess(couponInput())).category, .ok)
        // The same block turned the wrong way: the remedy is turning it, not other stock.
        var input = couponInput()
        input.setup.stockAxes = [0, 1, 2]
        let turned = try finding("stock", DFM.assess(input))
        try expectEqual(turned.category, .missingResource)
        try expect(turned.remedies.contains { if case .useStock(let id, _) = $0 { id == block.id } else { false } }, "\(turned.remedies)")
        try expectEqual(turned.remedies.first { if case .useStock = $0 { true } else { false } }?.title(in: inv, currentStock: block.id), "Turn the stock")
        // No stock chosen: choose one of yours.
        let none = try finding("stock", DFM.assess(couponInput(stock: nil)))
        try expectEqual(none.category, .missingInformation)
        try expect(none.remedies.contains { if case .useStock(let id, _) = $0 { id == block.id } else { false } })
    },
    TestCase(name: "stockBehindThePartAndOutsideProfile") {
        let deep = StockItem(materialID: "al-6061", sizeX: 210, sizeY: 60, sizeZ: 60)
        var input = couponInput(stock: deep)
        input.setup.stockAxes = [1, 0, 2]
        let all = DFM.assess(input)
        let stock = try finding("stock", all)
        try expectEqual(stock.category, .ok)
        try expect(stock.summary.hasPrefix("Fits.") && stock.summary.contains("1 face stays"), stock.summary)
        try expectEqual(stock.faces, [0])
        try expect(stock.details.contains("Kept as supplied: front.") && stock.details.contains { $0.hasPrefix("Stock to cut: back 9.2") }, "\(stock.details)")
        let back = try finding("back", all)
        try expectEqual(back.category, .setupChange)
        try expectEqual(back.faces, [1])
        try expect(back.summary.contains("9.2"), back.summary)
        let profile = try finding("profile", all)
        try expectEqual(Set(profile.faces), Set(2...5))
        // Only the long 1/4" 82720 reaches 50.8 mm walls (51.8 mm stick-out ≤ 63.5 − 10), and its shank rubs.
        try expectEqual(profile.category, .missingResource, "\(profile)")
        try expect(profile.remedies.contains(.setStickout(toolID: named("82720", in: realInventory()).id, minimum: 52)), "\(profile.remedies)")
        // Two-sided: the back is planned, no "stock behind" finding; the back region says side B.
        input.twoSided = true
        let two = DFM.assess(input)
        try expect(!two.contains { $0.id == "back" })
        try expect(try finding("region-50", two).summary.contains("Side B"))
    },
    TestCase(name: "changingToolsMachineOrStockUpdatesFindings") {
        // A 3/16" collet: the 3/16" end mills come back, and the larger one wins F2.
        var inv = realInventory()
        inv.accessories.append(Accessory(name: "ER-11 3/16\"", kind: .collet, size: 4.7625))
        let withCollet = DFM.assess(couponInput(inventory: inv))
        let f2 = try finding("floor-20", withCollet)
        try expect(f2.summary.contains("3/16\" flat"), f2.summary)
        try expect(!f2.remedies.contains(.addCollet(4.7625)), "\(f2.remedies)")
        let tools = try finding("tools", withCollet)
        try expect(!tools.details.contains { $0.contains("no collet") } && !tools.remedies.contains(.addCollet(4.7625)), "\(tools)")
        // The legacy 76.2 mm limit: the owned drill fits, F4 is OK and no tool is over the limit.
        let legacy = DFM.assess(couponInput(machine: .standard))
        let f4 = try finding("hole-40", legacy)
        try expectEqual(f4.category, .ok, "\(f4)")
        try expect(f4.summary.contains("1/4\" drill"), f4.summary)
        try expect(!(try finding("tools", legacy)).details.contains { $0.contains("drill") })
        // A not-owned long-reach 1/16" from the catalog reaches the F3 slot: offered to buy.
        var shop = realInventory()
        var buy = tool("1/16\" long reach flat", .flatEndMill, 1.5875, 3.175, 9.525, 15.875, 38.1, part: "LR1")
        buy.quantity = 0
        buy.source = ToolCatalog.source
        shop.tools.append(buy)
        let f3 = try finding("floor-30", DFM.assess(couponInput(inventory: shop)))
        try expectEqual(f3.category, .missingResource)
        try expect(f3.remedies.contains(.buyTool(buy.id)), "\(f3.remedies)")
        // Owning it makes the slot OK, and stops offering it.
        shop.tools[shop.tools.count - 1].quantity = 1
        let owned = try finding("floor-30", DFM.assess(couponInput(inventory: shop)))
        try expectEqual(owned.category, .ok, "\(owned)")
        // A tool needing only more stick-out is a setup change with the value stated.
        var stick = realInventory()
        stick.tools.removeAll { $0.partNumber == "81635" }
        stick.tools.append(tool("1/8\" flat end mill · long", .flatEndMill, 3.175, 3.175, 32, 28.575, 50.8, part: "LONG"))
        let f2b = try finding("floor-20", DFM.assess(couponInput(inventory: stick)))
        try expectEqual(f2b.category, .setupChange, "\(f2b)")
        try expect(f2b.remedies.contains(.setStickout(toolID: named("LONG", in: stick).id, minimum: 31)), "\(f2b.remedies)")
    },
    TestCase(name: "unconfirmedSpecsAreMissingInformation") {
        var inv = realInventory()
        var draft = tool("1.5 mm flat", .flatEndMill, 1.5, 3.175, 9, 15, 38, part: "DRAFT")
        draft.unconfirmedSpecifications = ["flute length"]
        inv.tools.append(draft)
        let all = DFM.assess(couponInput(inventory: inv))
        let info = try finding("tools-info", all)
        try expectEqual(info.category, .missingInformation)
        try expect(info.remedies == [.showTool(draft.id)] && info.details.contains { $0.contains("flute length") }, "\(info)")
        // The slot only an unconfirmed tool might reach.
        let f3 = try finding("floor-30", all)
        try expectEqual(f3.category, .missingInformation, "\(f3)")
        try expect(f3.remedies.contains(.showTool(draft.id)) && f3.summary.contains("Confirm"), "\(f3)")
        // Never ready for CAM, and never a buy suggestion when not owned.
        try expect(!OperationPlanner.usableTools(inv, machine: desktopCNC()).contains { $0.id == draft.id })
        inv.tools[inv.tools.count - 1].quantity = 0
        let f3b = try finding("floor-30", DFM.assess(couponInput(inventory: inv)))
        try expect(!f3b.remedies.contains(.buyTool(draft.id)) && f3b.category == .missingResource, "\(f3b)")
    },
    TestCase(name: "reachChecksCutterShankNutAndMachine") {
        let inv = realInventory(), m = desktopCNC()
        func reach(_ part: String, opening: Double?, wall: Double, holder: Double, hole: Double? = nil,
                   machine: MachineProfile = desktopCNC(), inventory: Inventory = realInventory()) -> DFM.Reach {
            DFM.reach(tool: named(part, in: inventory), opening: opening, wallDepth: wall, holderDepth: holder, hole: hole,
                      machine: machine, inventory: inventory)
        }
        // A shank wider than the cutter stops it at the flute length.
        let wide = reach("TC10804", opening: 2, wall: 8, holder: 9)
        try expectEqual(wide.verdict, .cannot)
        try expect(wide.reason.contains("shank wider than the cutter stops it at 6.35 mm"), wide.reason)
        try expectEqual(reach("TC10804", opening: 2, wall: 6, holder: 7).verdict, .reaches)
        // Shank as wide as the cutter: it reaches but rubs past the flutes.
        let rub = reach("81635", opening: 10, wall: 12, holder: 13)
        try expectEqual(rub.verdict, .reaches)
        try expect(rub.warnings.contains { $0.contains("rubs the wall below 9.525 mm") }, "\(rub)")
        // More stick-out, stated in half millimetres, within the grip.
        try expectEqual(reach("81635", opening: 6, wall: 9, holder: 31).verdict, .needsStickout(31))
        try expectEqual(reach("81635", opening: 6, wall: 9, holder: 31.000001).verdict, .needsStickout(31))
        try expectEqual(reach("81635", opening: 6, wall: 9, holder: 30.2).verdict, .needsStickout(30.5))
        // The collet nut: 38.1 − 10 mm grip leaves 28.1 mm.
        let nut = reach("03017", opening: 6, wall: 6, holder: 31)
        try expectEqual(nut.verdict, .cannot)
        try expect(nut.reason.contains("collet nut"), nut.reason)
        // No collet for the shank.
        let collet = reach("48031", opening: 10, wall: 5, holder: 9)
        try expectEqual(collet.verdict, .cannot)
        try expect(collet.reason.contains("no collet"), collet.reason)
        // Too long for this machine: the 76.2 mm drill.
        let drill = DFM.reach(tool: inv.tools.first { $0.kind == .drill }!, opening: 6.35, wallDepth: 20, holderDepth: 21, hole: 6.35,
                              machine: m, inventory: inv)
        try expectEqual(drill.verdict, .cannot)
        try expect(drill.reason.contains("over the 75 mm limit"), drill.reason)
        try expectEqual(DFM.reach(tool: inv.tools.first { $0.kind == .drill }!, opening: 6.35, wallDepth: 20, holderDepth: 21, hole: 6.35,
                                  machine: .standard, inventory: inv).verdict, .reaches)
        // Too wide for the opening, and too wide to bore a hole of its own size.
        try expect(reach("81400", opening: 6, wall: 5, holder: 6).reason.contains("too wide (6.35 > 6 mm)"))
        try expect(reach("81400", opening: 6.35, wall: 5, holder: 6, hole: 6.35).reason.contains("too wide to bore"))
        // Slender at the needed stick-out.
        let thin = DFM.reach(tool: tool("1 mm flat", .flatEndMill, 1, 1, 3, 10, 38.1), opening: 3, wallDepth: 2, holderDepth: 12,
                             hole: nil, machine: m, inventory: { var i = inv; i.accessories.append(Accessory(name: "1", kind: .collet, size: 1)); return i }())
        try expectEqual(thin.verdict, .needsStickout(12))
        try expect(thin.warnings.contains { $0.contains("slender") }, "\(thin)")
        // A broken tool never reaches.
        var broken = named("81400", in: inv)
        broken.condition = .broken
        try expectEqual(DFM.reach(tool: broken, opening: 20, wallDepth: 5, holderDepth: 6, hole: nil, machine: m, inventory: inv).verdict, .cannot)
    },
    TestCase(name: "withoutAccessOnlyStockAndExactCAD") {
        var input = couponInput()
        input.analysis.access = nil
        let all = DFM.assess(input)
        try expectEqual(all.map(\.id), ["exact", "stock"])
        try expectEqual(all[0].category, .missingInformation)
        try expect(all[1].summary.hasPrefix("Exact size"), all[1].summary)
    },
    TestCase(name: "accessDecodesTheEngineResult") {
        let json: [String: Any] = [
            "faces": [["index": 0, "area": 12.5, "kind": "plane", "boundary": "+z", "plane_offset": 0.0, "access": "this",
                       "visible": ["+z": 1.0, "-z": 0.0]],
                      ["index": 1, "area": 3, "kind": "cylinder", "boundary": NSNull(), "plane_offset": NSNull(), "access": "other",
                       "visible": ["+z": 0.25, "+x": 1]]],
            "regions": [["faces": [1], "area": 3, "access": "other", "directions": ["+x"], "min": [0, 1, 2], "max": [3, 4, 5],
                         "sides": [["side": "+x", "share": 1, "depth": 9.5]],
                         "sides_two": [["side": "-z", "share": 0.25, "depth": 4], ["side": "+x", "share": 0.75, "depth": 9.5]],
                         "thread": ["sides": [["side": "+y", "depth": 18, "open": true]], "major": 12.8, "minor": 11.4, "length": 18]]],
            "floors": [["face": 0, "z": -8, "area": 586.5, "width": 20, "wall_depth": 8, "holder_depth": 9, "enclosed": 0.97,
                        "min": [-10, -15, -8], "max": [10, 15, -8]]],
            "holes": [["faces": [2, 3], "x": 1, "y": 2, "diameter": 6.35, "z_top": 0, "z_bottom": -20, "through": false, "access": "this", "holder_depth": 21]],
            "part_min": [-1, -2, -3], "part_max": [1, 2, 0],
            "face_triangles": [[0, 0, 1], [1, 1, 2]],
        ]
        let tris: [Float] = (0..<27).map { Float($0) }
        let a = PartAccess(json: json, triangles: tris)
        try expectEqual(a.faces.count, 2)
        try expectEqual(a.faces[0].boundary, "+z")
        try expectEqual(a.faces[1].boundary, nil)
        try expectEqual(a.faces[1].planeOffset, nil)
        try expectEqual(a.faces[1].access, .otherDirection)
        try expectEqual(a.faces[1].visible["+x"], 1)
        try expectEqual(a.regions[0].directions, ["+x"])
        try expectEqual(a.regions[0].max, SIMD3(3, 4, 5))
        try expectEqual(a.regions[0].sides, [.init(side: "+x", share: 1, depth: 9.5)])
        try expectEqual(a.regions[0].sidesTwo.map(\.side), ["-z", "+x"])
        try expectEqual(a.regions[0].thread, .init(sides: [.init(side: "+y", depth: 18, open: true)], major: 12.8, minor: 11.4, length: 18))
        try expectEqual(a.floors[0].holderDepth, 9)
        try expectEqual(a.floors[0].enclosed, 0.97)
        try expectEqual(a.holes[0].length, 20)
        try expectEqual(a.holes[0].faces, [2, 3])
        try expectEqual(a.partMin, SIMD3(-1, -2, -3))
        try expectEqual(a.faceTriangles[1], 1..<3)
        try expectEqual(a.triangles(forFaces: [0]).count, 9)
        try expectEqual(a.triangles(forFaces: [1, 1]), Array(tris[9..<27]))
        let b = try unwrap(a.bounds(forFaces: [0]))
        try expectEqual(b.min, SIMD3(0, 1, 2))
        try expectEqual(b.max, SIMD3(6, 7, 8))
        try expect(a.bounds(forFaces: [7]) == nil)
        // An older engine: no sides (the old wording, reach not checked), no wall share.
        let old = PartAccess(json: ["regions": [["faces": [1], "access": "other", "directions": ["+x"]]],
                                    "floors": [["face": 0, "z": -8, "width": 20]]])
        try expect(old.regions[0].sides.isEmpty && old.regions[0].sidesTwo.isEmpty && old.regions[0].thread == nil)
        try expectEqual(old.floors[0].enclosed, nil)
        // Missing keys decode as empty.
        let empty = PartAccess(json: [:])
        try expect(empty.faces.isEmpty && empty.floors.isEmpty && empty.faceTriangles.isEmpty)
    },
    TestCase(name: "sideReachThreadsBoresAndFloorNames") {
        typealias Region = PartAccess.Region
        var access = couponAccess()
        for k in 80...83 { access.faces.append(PartAccess.Face(index: k, kind: "cylinder", access: .otherDirection)) }
        access.regions = [
            // A 10 mm bore along Y from the left (-y) end, seen through two windows: 40 and 150 mm in.
            Region(faces: [80], access: .otherDirection, directions: ["-y"], min: SIMD3(-5, -70, -30), max: SIMD3(5, -61.6, -20),
                   sides: [.init(side: "-y", depth: 40)]),
            Region(faces: [81], access: .otherDirection, directions: ["-y"], min: SIMD3(-5, 30, -30), max: SIMD3(5, 48.4, -20),
                   sides: [.init(side: "-y", depth: 150)]),
            // A side window, 9 mm in from the upper (+x) side, 30 mm across.
            Region(faces: [82], access: .otherDirection, directions: ["+x"], min: SIMD3(16.4, -10, -40), max: SIMD3(25.4, 20, -10),
                   sides: [.init(side: "+x", depth: 9)]),
            // A modelled thread at the right (+y) end.
            Region(faces: [83], access: .noAccess, min: SIMD3(-6.4, 83.6, -31.4), max: SIMD3(6.4, 101.6, -18.6),
                   thread: .init(sides: [.init(side: "+y", depth: 18, open: true), .init(side: "-y", depth: 203.2, open: false)],
                                 major: 12.8, minor: 11.4, length: 18)),
            // F5, the back recess, measured from the back.
            Region(faces: [50, 51, 52, 53], area: 640, access: .oppositeSide, directions: ["-z"],
                   min: SIMD3(-10, 35, -50.8), max: SIMD3(10, 55, -47.8), sides: [.init(side: "-z", depth: 3)]),
        ]
        access.floors = [
            PartAccess.Floor(face: 10, z: -8, area: 586, width: 20, wallDepth: 8, holderDepth: 9,
                             min: SIMD3(-10, -85, -8), max: SIMD3(10, -55, -8), enclosed: 1),
            PartAccess.Floor(face: 20, z: -2, area: 5000, width: 15, wallDepth: 2, holderDepth: 3,
                             min: SIMD3(-18, -101.6, -2), max: SIMD3(18, 80, -2), enclosed: 0.1),
            PartAccess.Floor(face: 30, z: -8, area: 29, width: 2, wallDepth: 8, holderDepth: 9,
                             min: SIMD3(-1, -15, -8), max: SIMD3(1, 0, -8), enclosed: 0.7),
        ]
        var input = couponInput()
        input.analysis.access = access
        let all = DFM.assess(input)
        let text = all.map { "\($0.id) [\($0.category)] \($0.title): \($0.summary) | \($0.measure ?? "-") | \($0.fix ?? "-")" }.joined(separator: "\n")
        // The bore is one item, judged at its deepest place: no tool this machine holds reaches 150 mm.
        let bore = try unwrap(all.first { $0.faces.contains(80) }, line: #line)
        try expectEqual(bore.category, .notSupported, text)
        try expectEqual(bore.title, "Too deep from the left side (2 places)")
        try expectEqual(bore.areas, [[81], [80]])
        try expectEqual(bore.measure, "From the left side: 150 mm deep, 10 mm wide.")
        try expect(bore.fix?.contains("shallower") == true, bore.fix ?? "")
        // The window: a setup from that side, and an owned 1/4" reaches 9 mm in.
        let window = try finding("region-82", all)
        try expectEqual(window.category, .setupChange, text)
        try expectEqual(window.title, "Cut from the upper side")
        try expect(window.summary.contains("only get in from the upper side") && window.summary.contains("1/4\" flat"), window.summary)
        try expect(window.fix?.contains("upper side toward the spindle") == true && window.remedies.contains(.reviewSetups), "\(window)")
        try expect(window.details.contains("Holding from there is not checked."), "\(window.details)")
        // The thread: found by its shape, cut from its open end; no thread mill owned.
        let thread = try finding("region-83", all)
        try expectEqual(thread.category, .missingResource, text)
        try expectEqual(thread.title, "Thread 12.8 mm, 18 long")
        try expect(thread.summary.contains("right side") && thread.fix?.contains("Add a single-profile thread mill") == true, "\(thread)")
        guard case .addTool(let threadMill)? = thread.remedies.first else { throw TestFailure(description: "\(thread.remedies)") }
        try expect(threadMill.kind == .threadMill && threadMill.diameter < 11.4 - 0.5 && threadMill.fluteLength >= 19
                   && threadMill.overallLength <= 75, "\(threadMill)")
        try expect(!all.contains { $0.title == "No straight path for the tool" }, text)
        var withMill = input
        var mill = Tool(name: "Thread mill 8 mm", kind: .threadMill, diameter: 8, shankDiameter: 6.35, flutes: 3,
                        fluteLength: 20, stickout: 28, overallLength: 50.8)
        mill.threadPitch = 1.27
        withMill.inventory.tools.append(mill)
        let milled = try finding("region-83", DFM.assess(withMill))
        try expectEqual(milled.category, .setupChange, "\(milled)")
        try expect(milled.summary.contains("Thread mill") && milled.fix?.contains("right side toward the spindle") == true, "\(milled)")
        // The back recess: reach measured from the back; with both sides, side B gets to it.
        let back = try finding("region-50", all)
        try expectEqual(back.title, "Cut from the back")
        try expectEqual(back.measure, "From the back: 3 mm deep, 20 mm wide.")
        input.twoSided = true
        try expect(try finding("region-50", DFM.assess(input)).summary.hasPrefix("Side B gets to it."))
        // Floors: named by how much of their edge has a wall.
        try expect(try finding("floor-10", all).title.hasPrefix("Pocket 20 x 30 mm"))
        try expect(try finding("floor-20", all).title.hasPrefix("Step 36 x 181.6 mm"), text)
        try expect(try finding("floor-30", all).title.hasPrefix("Open slot 2 x 15 mm"), text)
        // Both sides machined: the outside walls are cut half from each side (plus 0.3 mm past the split).
        let deep = StockItem(materialID: "al-6061", sizeX: 210, sizeY: 60, sizeZ: 60)
        var two = couponInput(stock: deep, twoSided: true)
        two.setup.stockAxes = [1, 0, 2]
        try expectEqual(try finding("profile", DFM.assess(two)).title, "Outside profile, 25.7 deep per side")
        two.twoSided = false
        try expectEqual(try finding("profile", DFM.assess(two)).title, "Outside profile, 50.8 deep")
    },
    TestCase(name: "featureNamesTitleTheAccessFindings") {
        // The name goes to the feature most of whose faces are in the region.
        let named = [NamedFeature(family: "pockets", label: "Pocket 3 x 40 mm", faces: [70, 71, 72, 90]),
                     NamedFeature(family: "holes", label: "Through hole ⌀10 mm", faces: [99]),
                     NamedFeature(family: "chamfers", label: "Chamfer 1 mm", faces: [74, 91, 92, 93])]
        try expectEqual(NamedFeature.name(for: [70, 71, 72, 73, 74], in: named), "Pocket 3 x 40 mm")
        try expectEqual(NamedFeature.name(for: [74], in: named), nil, "a quarter of the chamfer is not enough")
        try expectEqual(NamedFeature.name(for: Array(60...79), in: named), nil, "three faces of twenty don't name the region")
        try expectEqual(NamedFeature.name(for: [1, 2], in: named), nil)
        var input = couponInput()
        input.named = named
        let all = DFM.assess(input)
        let groove = try finding("region-70", all)
        try expectEqual(groove.title, "Pocket 3 x 40 mm: needs another position")
        try expect(groove.summary.contains("only get in from the"), groove.summary)  // what is wrong stays in the summary
        // Without names, the problem is the title.
        try expectEqual(try finding("region-70", DFM.assess(couponInput())).title, "Needs another position")
    },
    TestCase(name: "planCoverageSaysWhatEachSetupCutsAndWhatIsLeft") {
        let all = DFM.assess(couponInput())
        func gap(_ id: String, _ c: PlanCoverage) -> PlanCoverage.Gap? { c.gaps.first { $0.finding == id } }
        // One side (the front): the closed T-slot can't be cut, the back recess and the side
        // groove need setups the plan doesn't have, the 2 mm slot needs a tool the plan doesn't use.
        let one = PlanCoverage.assess(all, sides: ["+z"], jobTools: [])
        let gaps = one.gaps.map { "\($0.finding) \($0.reason)" }.joined(separator: "\n")
        try expectEqual(gap("region-60", one)?.reason, .cannotMachine, gaps)
        try expectEqual(gap("region-50", one)?.reason, .needsSides(["-z"]), gaps)
        try expectEqual(gap("region-70", one)?.reason, .needsSides(["+x"]), gaps)
        try expectEqual(gap("floor-30", one)?.reason, .needsTool, gaps)
        try expect(gap("region-50", one)?.text.contains("Machine both sides") == true)
        try expect(gap("region-70", one)?.text == "Needs a setup from the upper side. The plan has no setup from there yet.")
        try expect(!one.complete && !one.gaps.contains { ["tools", "tools-info", "stock", "exact", "thin"].contains($0.finding) }, gaps)
        try expectEqual(one.setups.map(\.number), [1])
        // The owned 1/4" drill is longer than the machine takes: the hole waits for a tool too.
        try expectEqual(gap("hole-40", one)?.reason, .needsTool, gaps)
        // The front setup lists its features, those still waiting for a tool too.
        try expectEqual(Set(one.setups[0].findings), ["floor-10", "floor-20", "floor-30", "hole-40"], "\(one.setups)")
        try expect(one.setups[0].faces.contains(10) && !one.setups[0].faces.contains(60), "\(one.setups[0].faces)")
        // The tool Coastline specifies for the 2 mm slot, used by the plan: cut, with a tool to buy.
        guard case .addTool(let mill)? = try finding("floor-30", all).remedies.first else { throw TestFailure(description: "no tool to buy") }
        let buying = PlanCoverage.assess(all, sides: ["+z"], jobTools: [mill.id])
        try expect(gap("floor-30", buying) == nil && buying.withToolsToBuy == ["floor-30"], "\(buying.gaps)")
        try expect(buying.setups[0].findings.contains("floor-30"))
        // Both sides: side B cuts the back recess; the side groove still needs its own setup.
        let two = PlanCoverage.assess(DFM.assess(couponInput(twoSided: true)), sides: ["+z", "-z"], jobTools: [])
        try expect(gap("region-50", two) == nil && gap("region-70", two) != nil, "\(two.gaps)")
        try expectEqual(two.setups.map(\.side), ["+z", "-z"])
        try expect(two.setups[1].findings == ["region-50"], "\(two.setups[1])")
        // A merged feature keeps every side it is cut from.
        try expect(DFM.assess(couponInput()).allSatisfy { f in !f.id.hasPrefix("floor-") || f.sides == ["+z"] })
    },
    TestCase(name: "allSixSidesAreConsideredAndCheckedForRoom") {
        // The coupon lies 203.2 mm along Y, 50.8 deep. On the 74.9 mm table a long side toward
        // the spindle fits; an end hangs 128.3 mm past the table: through the enclosure's panel
        // (57 mm behind the table), clear of the machine itself up to 100 mm in this test.
        let ends = SetupRoom.Turn(behind: 57, behindOpen: 100)
        let room = SetupRoom(tableDepth: 74.93, turns: ["+y": ends, "-y": ends])
        let stock = SIMD3(50.8, 203.2, 50.8)
        try expectEqual(room.fit(SetupRoom.size(stock, facing: "+x"), side: "+x"), .fits)
        try expectEqual(room.problem(SetupRoom.size(stock, facing: "-y"), side: "-y"),
                        "It is 203.2 mm deep that way, 128.3 mm past the 74.9 mm table, and the machine leaves 100 mm there.")
        let open = SetupRoom(tableDepth: 74.93, turns: ["+y": SetupRoom.Turn(behind: 57, behindOpen: 1000)])
        try expectEqual(open.fit(SetupRoom.size(stock, facing: "+y"), side: "+y"),
                        .enclosureOpen("It is 203.2 mm deep that way, 128.3 mm past the 74.9 mm table. That fits with the enclosure open: its panel leaves 57 mm."))
        try expectEqual(open.problem(SetupRoom.size(stock, facing: "+y"), side: "+y"), nil)
        // A side measured nowhere counts the table alone.
        try expect(open.problem(SetupRoom.size(stock, facing: "-y"), side: "-y")?.hasSuffix("the machine leaves 0 mm there.") == true)
        // The fewest sides that cut the most: the front, the back for the recess, the upper side
        // for the groove. The closed T-slot can't be cut from any side.
        let all = DFM.assess(couponInput())
        let sides = PlanCoverage.propose(all)
        try expectEqual(sides, ["+z", "-z", "+x"])
        // Toolpaths for the front and back only: the groove's setup is proposed, its feature waits.
        let c = PlanCoverage.assess(all, sides: sides, jobTools: [], toolpathSides: ["+z", "-z"], room: room, stock: stock)
        try expectEqual(c.setups.map(\.number), [1, 2, 3])
        try expectEqual(c.setups.map(\.toolpaths), [true, true, false])
        try expectEqual(c.waiting, ["region-70"])
        try expect(c.gaps.first { $0.finding == "region-70" } == nil && c.open == c.gaps.count + 1, "\(c.gaps)")
        // Every other side is accounted for, with the reason.
        try expectEqual(c.unused.map(\.side), ["-x", "+y", "-y"])
        try expectEqual(c.unused[0].why, "Nothing needs it.")
        try expect(!c.unused[1].fits && c.unused[1].why.hasPrefix("Doesn't fit the machine. It is 203.2 mm deep"), c.unused[1].why)
        // A thread at the end of the bar: the part check says the machine has no room that way.
        var access = couponAccess()
        access.faces.append(PartAccess.Face(index: 83, kind: "cylinder", access: .noAccess))
        access.regions.append(PartAccess.Region(faces: [83], access: .noAccess, min: SIMD3(-6.4, 83.6, -31.4), max: SIMD3(6.4, 101.6, -18.6),
            thread: .init(sides: [.init(side: "+y", depth: 18, open: true)], major: 12.8, minor: 11.4, length: 18)))
        var input = couponInput()
        input.analysis.access = access
        input.room = room
        let thread = try finding("region-83", DFM.assess(input))
        try expectEqual(thread.category, .notSupported)
        try expect(thread.summary == "Cut from the right side. The stock doesn't fit the machine with the right side toward the spindle. It is 203.2 mm deep that way, 128.3 mm past the 74.9 mm table, and the machine leaves 100 mm there.", thread.summary)
        try expect(thread.remedies.isEmpty && thread.fix?.contains("more room") == true)
        // With room behind the table once the enclosure is open: the thread keeps its own verdict,
        // the condition is in its details and on the setup.
        input.room = open
        let opened = try finding("region-83", DFM.assess(input))
        try expectEqual(opened.category, .missingResource, "\(opened)")
        try expect(opened.details.contains { $0.hasPrefix("With the right side toward the spindle: It is 203.2 mm deep that way") }, "\(opened.details)")
        let endSetup = PlanCoverage.assess(DFM.assess(input), sides: ["+z", "+y"], jobTools: [], room: open, stock: stock)
        try expect(endSetup.setups[1].note?.contains("enclosure open") == true, "\(endSetup.setups)")
        input.room = room
        // The groove on the upper side fits: unchanged by the room check.
        try expectEqual(try finding("region-70", DFM.assess(input)).category, .setupChange)
        let withRoom = PlanCoverage.assess(DFM.assess(input), sides: ["+z"], jobTools: [], room: room, stock: stock)
        try expectEqual(withRoom.gaps.first { $0.finding == "region-83" }?.reason, .noRoom("+y"))
    },
]
