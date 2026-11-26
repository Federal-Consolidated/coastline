import AppKit
import CoastlineCore
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// K10: bits with IDs, their wear before and after the job, what wear does to the part, and
// printable labels for their boxes.

extension WearStage {
    var tint: Color {
        switch self {
        case .new, .wornIn: Theme.ok
        case .dulling, .nearEnd: Theme.warning
        case .wornOut: Theme.danger
        }
    }
}

private func pct(_ v: Double) -> String { (min(max(v, 0), 9.99)).formatted(.percent.precision(.fractionLength(0))) }

/// The ID written on a bit's box, as a small capsule.
struct BitLabelPill: View {
    let label: String
    var body: some View {
        Text(label).font(.caption.monospaced().weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .accessibilityLabel("Bit \(label)")
    }
}

/// Wear now → after, as a bar with the added part lighter.
struct WearBar: View {
    let before: Double
    let after: Double
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(WearStage.of(after).tint.opacity(0.45)).frame(width: w * min(after, 1))
                Capsule().fill(WearStage.of(before).tint).frame(width: w * min(before, 1))
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wear")
        .accessibilityValue("\(pct(before)) now, \(pct(after)) after this job")
    }
}

/// Machining ▸ Bits: which bit each program uses, how worn it is before and after, and the
/// Save tools goal. Follows the tuner's settings before you regenerate.
struct BitForecastSection: View {
    @Environment(AppModel.self) private var model
    @Environment(InventoryModel.self) private var inventory

    var body: some View {
        @Bindable var model = model
        let items = model.wearForecast(model.tuning)
        let base = model.tunerEstimate(model.generatedTuning)
        let saver = { var t = model.tuning; t.toolSaver = model.tuning.saveTools ? nil : true; return t }()
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { model.tuning.saveTools }, set: { model.tuning.toolSaver = $0 ? true : nil })) {
                    HStack(spacing: 4) {
                        Text("Save tools")
                        InfoTip(text: "Plans the job to wear the bits less: the spindle about 15 % slower with the same chip per tooth (cooler edge; Taylor: about twice the life), and deep roughing, so wear spreads along the flutes instead of the tip. Adaptive roughing already avoids full-width slotting and enters on ramps and helices. It takes longer; the bits last longer.")
                    }
                }
                if let now = model.tunerEstimate(model.tuning), let other = model.tunerEstimate(saver) {
                    let (on, off) = model.tuning.saveTools ? (now, other) : (other, now)
                    let dt = (on.minutes - off.minutes) / max(off.minutes, 1e-9)
                    let dc = ((on.cost?.tools ?? 0) - (off.cost?.tools ?? 0)) / max(off.cost?.tools ?? 0, 1e-9)
                    Text("Save tools: \(dt >= 0 ? "+" : "−")\(pct(abs(dt))) time, \(dc <= 0 ? "−" : "+")\(pct(abs(dc))) tool cost.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if items.isEmpty {
                Text(base == nil ? "Generate once to see each bit's wear before and after this job." : "No tools with bits in this job.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { item in BitForecastRow(item: item, material: model.stock?.material) }
            if model.tuning != model.generatedTuning, !items.isEmpty {
                Text("At the settings above; regenerate to apply them.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Bits")
        } footer: {
            Text("Wear is estimated from cutting time, the material and the pace (Taylor tool life), and corrected when you mark a bit worn. Record each job so it stays true.")
        }
    }
}

struct BitForecastRow: View {
    let item: Consumables.ForecastItem
    let material: Material?
    @State private var effects = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: item.stage.symbol).foregroundStyle(item.stage.tint).accessibilityLabel(item.stage.title)
                Text(item.tool.name.components(separatedBy: " · ").first ?? item.tool.name).lineLimit(1).help(item.title)
                Spacer(minLength: 4)
                if let u = item.unit { BitLabelPill(label: u.label) }
            }
            if item.unit != nil {
                HStack(spacing: 8) {
                    WearBar(before: item.before, after: item.after)
                    Text("\(pct(item.before)) → \(pct(item.after))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let a = item.advice {
                Label(a, systemImage: item.swappedFrom != nil ? "arrow.triangle.2.circlepath" : "info.circle")
                    .font(.caption).foregroundStyle(item.stage >= .nearEnd || item.swappedFrom != nil ? Theme.warning : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let material, item.unit != nil, item.stage >= .dulling {
                DisclosureGroup("What \(item.stage.title.lowercased()) does to the part", isExpanded: $effects) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(item.stage.effects(tool: item.tool, material: material), id: \.self) { Text("• " + $0) }
                    }
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Tools ▸ inspector ▸ Bits: each physical bit, its wear, which one is in the collet, retiring
/// worn or broken ones, and labels for their boxes.
struct BitsInspectorSection: View {
    @Environment(InventoryModel.self) private var model
    @Binding var tool: Tool
    @State private var showRetired = false
    @State private var explain: WearStage?

    var body: some View {
        let learning = model.inventory.lifeLearning
        let active = Consumables.activeUnits(tool)
        let loaded = Consumables.loadedUnit(tool, learning: learning)?.id
        let retired = (tool.units ?? []).filter { !$0.isActive }
        Section {
            ForEach(active) { u in
                let w = Consumables.wear(u, tool: tool, learning: learning)
                let stage = WearStage.of(w)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        BitLabelPill(label: u.label)
                        if u.id == loaded {
                            Text("In use").font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        Button { explain = stage } label: {
                            Label(stage.title, systemImage: stage.symbol).font(.caption).foregroundStyle(stage.tint)
                        }
                        .buttonStyle(.plain)
                        .help("What \(stage.title.lowercased()) does to the part")
                        Menu {
                            Button("Use This Bit", systemImage: "scope") { tool.loadedUnitID = u.id }
                                .disabled(u.id == loaded)
                            Button("Print Label", systemImage: "printer") { BitLabels.open([(tool, u)]) }
                            Divider()
                            Button("Worn Out: Retire", systemImage: "archivebox") { retire(u, broken: false) }
                            Button("Broken: Retire", systemImage: "bolt.trianglebadge.exclamationmark") { retire(u, broken: true) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.button).buttonStyle(.borderless).fixedSize()
                        .accessibilityLabel("Actions for bit \(u.label)")
                    }
                    WearBar(before: w, after: w)
                    Text("\(pct(w)) of its life · \(Int(u.minutes.rounded())) min cut").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if active.isEmpty {
                Text(tool.quantity > 0 ? "Bits appear here once saved." : "Set a quantity to give each bit an ID.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !active.isEmpty {
                Button("Print Labels for All", systemImage: "printer") { BitLabels.open(active.map { (tool, $0) }) }
            }
            if !retired.isEmpty {
                DisclosureGroup("Retired (\(retired.count))", isExpanded: $showRetired) {
                    ForEach(retired) { u in
                        HStack {
                            BitLabelPill(label: u.label)
                            Text(u.condition == .broken ? "Broken" : "Worn out").font(.caption)
                            Spacer()
                            Text("\(Int(u.minutes.rounded())) min").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Bits")
        } footer: {
            Text("Write each ID on the bit's box or tube (or print the labels). Retiring a worn bit teaches Coastline how long this kind really lasts\(learning.map { l in abs(l.factor(for: tool) - 1) > 0.01 ? ": now \(pct(l.factor(for: tool))) of the first estimate" : "" } ?? "").")
        }
        .popover(item: $explain) { s in
            VStack(alignment: .leading, spacing: 6) {
                Label(s.title, systemImage: s.symbol).font(.headline).foregroundStyle(s.tint)
                ForEach(s.effects(tool: tool, material: MaterialLibrary.material(id: "al-6061") ?? MaterialLibrary.all[0]), id: \.self) {
                    Text("• " + $0).fixedSize(horizontal: false, vertical: true)
                }
                Text("Shown for aluminium; the forecast in Machining uses the job's material.").font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(14)
            .frame(width: 320)
        }
    }

    private func retire(_ u: ToolUnit, broken: Bool) {
        let id = tool.id
        model.update { inv in Consumables.retire(unit: u.id, of: id, broken: broken, in: &inv) }
    }
}

extension WearStage: Identifiable { public var id: Int { rawValue } }

/// Labels for bit boxes: the ID large, the tool under it, a QR code with the ID (a handheld
/// scanner types it into the Tools search). A PDF opened in Preview, ready to print.
enum BitLabels {
    static let mm: CGFloat = 72 / 25.4
    static let size = CGSize(width: 50 * mm, height: 22 * mm)

    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let img = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(img, from: img.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: img.extent.width, height: img.extent.height))
    }

    struct LabelView: View {
        let tool: Tool
        let unit: ToolUnit
        var body: some View {
            HStack(spacing: 6) {
                if let q = BitLabels.qr(unit.label) {
                    Image(nsImage: q).interpolation(.none).resizable().frame(width: 17 * BitLabels.mm, height: 17 * BitLabels.mm)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(unit.label).font(.system(size: 18, weight: .bold, design: .monospaced))
                    Text(tool.name).font(.system(size: 7)).lineLimit(1).minimumScaleFactor(0.8)
                    Text("\(Length.describe(tool.diameter)) · \(tool.flutes) fl · \(tool.toolMaterial.title)").font(.system(size: 6.5)).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .frame(width: BitLabels.size.width, height: BitLabels.size.height)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 0.4, dash: [2, 2])))
            .foregroundStyle(.black)
        }
    }

    /// A4 pages of 3 × 11 labels, cut along the dashes.
    @MainActor static func open(_ bits: [(Tool, ToolUnit)]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Coastline bit labels.pdf")
        if write(bits, to: url) { NSWorkspace.shared.open(url) }
    }

    @MainActor @discardableResult static func write(_ bits: [(Tool, ToolUnit)], to url: URL) -> Bool {
        guard !bits.isEmpty else { return false }
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let perPage = 33
        var box = page
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        for start in stride(from: 0, to: bits.count, by: perPage) {
            let chunk = Array(bits[start ..< min(start + perPage, bits.count)])
            let sheet = VStack(alignment: .leading, spacing: 0) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(0 ..< (chunk.count + 2) / 3, id: \.self) { r in
                        GridRow {
                            ForEach(0 ..< 3, id: \.self) { c in
                                let k = r * 3 + c
                                if k < chunk.count { LabelView(tool: chunk[k].0, unit: chunk[k].1) } else { Color.clear.frame(width: size.width, height: size.height) }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 36, leading: 72, bottom: 36, trailing: 36))
            .frame(width: page.width, height: page.height, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            let r = ImageRenderer(content: sheet)
            r.render { _, draw in
                ctx.beginPDFPage(nil)
                draw(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return true
    }
}
