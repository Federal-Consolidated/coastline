import Charts
import CoastlineCore
import SwiftUI
import simd

/// K12: the playback bar's Sharpen menu: make a sharp snapshot here, the snapshots of this
/// side, and what to do with each.
struct SharpenMenu: View {
    @Environment(AppModel.self) private var model
    /// Narrow bars: the icon only.
    var compact = false

    var body: some View {
        if let p = model.sharpProgress {
            HStack(spacing: 8) {
                if p < 0 {
                    ProgressView().controlSize(.small)
                } else {
                    ProgressView(value: p).frame(width: compact ? 60 : 110)
                }
                Text(compact ? (p < 0 ? "\(model.sharpPhase)…" : "\(Int((p * 100).rounded())) %")
                             : (p < 0 ? "\(model.sharpPhase)…" : "\(model.sharpPhase) \(Int((p * 100).rounded())) %"))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Button("Cancel", systemImage: "xmark.circle.fill") { model.cancelSharpen() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Stop making the sharp snapshot")
                    .disabled(model.sharpPhase == "Drawing")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .help(p < 0 ? "\(model.sharpPhase)…" : "\(model.sharpPhase): \(Int((p * 100).rounded())) %")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(p < 0 ? "Sharpening: \(model.sharpPhase)" : "Sharpening, \(Int((p * 100).rounded())) percent")
        } else {
            let shown = model.shownSnapshot != nil
            let title = shown ? "Sharp" : "Sharpen"
            let symbol = shown ? "checkmark.seal.fill" : "sparkle.magnifyingglass"
            HStack(spacing: 6) {
                // Liquid Glass like the display toggles beside it: click sharpens the whole stock
                // (or, when a snapshot is shown, goes back to the playback grid).
                Button {
                    if shown { model.hideSharp() } else { model.sharpen() }
                } label: {
                    if compact {
                        BarIconLabel(symbol: symbol)
                    } else {
                        Label(title, systemImage: symbol).font(.callout.weight(.semibold)).frame(height: 18)
                    }
                }
                .buttonStyle(.glass)
                .tint(shown ? Theme.accent : .clear)
                .foregroundStyle(shown ? Color.white : Color.primary)
                .fixedSize()
                .help(shown
                      ? "Showing a sharp snapshot. Click to go back to the playback grid."
                      : "Re-simulate the whole stock up to the playhead at high resolution (about 10 µm; the playback grid is \(Length.mm(model.heightmap?.cell ?? 0)) mm).")
                .accessibilityLabel(shown ? "Sharp snapshot shown, back to the playback grid" : "Sharpen the whole stock")
                // Everything else: a detail around a point, the snapshots, export.
                Button { model.sharpPanelOpen.toggle() } label: {
                    if compact {
                        BarIconLabel(symbol: "square.and.arrow.up")
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up").font(.callout.weight(.semibold)).frame(height: 18)
                    }
                }
                    .buttonStyle(.glass)
                    .tint(model.sharpPanelOpen ? Theme.accent : .clear)
                    .foregroundStyle(model.sharpPanelOpen ? Color.white : Color.primary)
                    .help("Export a sharp snapshot (clean CAD for Rhino or STEP, meshes), make a detail around a measured point, manage your snapshots")
                    .accessibilityLabel("Export and snapshots")
                    .popover(isPresented: Binding(get: { model.sharpPanelOpen }, set: { model.sharpPanelOpen = $0 }), arrowEdge: .top) {
                        SharpPanel { model.sharpPanelOpen = false }
                    }
            }
            .disabled(!model.simulate || model.heightmap == nil)
        }
    }
}

/// Snapshot marks on a step's segment of the timeline.
struct SnapshotMarks: View {
    @Environment(AppModel.self) private var model
    let span: ClosedRange<Double>
    let width: CGFloat

    var body: some View {
        ForEach(model.sharpSnapshots.filter { $0.side == model.viewSide && span.contains($0.time) }) { rec in
            let current = model.snapshotIsCurrent(rec)
            let x = CGFloat((rec.time - span.lowerBound) / max(span.upperBound - span.lowerBound, 1e-6)) * max(width - 8, 0)
            Button { model.showSnapshot(rec.id) } label: {
                Image(systemName: rec.region == .whole ? "diamond.fill" : "diamond")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(current ? (model.shownSnapshot == rec.id ? Color.white : Theme.warning) : Color.secondary)
                    .shadow(radius: 1)
            }
            .buttonStyle(.plain)
            .offset(x: x, y: -9)
            .disabled(!current)
            .help("\(rec.name) · \(rec.resolutionText)\(current ? "" : " · out of date: the toolpaths changed")")
            .accessibilityLabel("Sharp snapshot \(rec.name)\(current ? "" : ", out of date")")
        }
    }
}

/// The exact section: material along the section line from the toolpath itself, the playback
/// grid, and the part.
struct ExactSectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let section: ExactSection
    @State private var zoom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title).font(.title3.weight(.semibold))
            Text("Exact: the tool's envelope over each point, from every move so far (\(section.positions.count) points). Grey: the playback grid, \(Length.mm(section.gridCell)) mm cells.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Chart {
                if let part = section.part {
                    ForEach(Array(zip(section.positions, part).enumerated()), id: \.offset) { _, v in
                        if v.1.isFinite {
                            LineMark(x: .value(section.axis, v.0), y: .value("Z", v.1), series: .value("Line", "Part"))
                                .foregroundStyle(by: .value("Line", "Part"))
                        }
                    }
                }
                ForEach(Array(zip(section.positions, section.grid).enumerated()), id: \.offset) { _, v in
                    LineMark(x: .value(section.axis, v.0), y: .value("Z", v.1), series: .value("Line", "Playback grid"))
                        .foregroundStyle(by: .value("Line", "Playback grid")).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(Array(zip(section.positions, section.exact).enumerated()), id: \.offset) { _, v in
                    LineMark(x: .value(section.axis, v.0), y: .value("Z", v.1), series: .value("Line", "Exact"))
                        .foregroundStyle(by: .value("Line", "Exact")).lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartForegroundStyleScale(["Exact": Color(nsColor: .systemBlue), "Playback grid": Color.gray.opacity(0.7), "Part": Color(nsColor: .systemGreen)])
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxisLabel("\(section.axis) (mm)")
            .chartYAxisLabel("Z (mm)")
            .chartScrollableAxes(zoom ? .horizontal : [])
            .chartXVisibleDomain(length: zoom ? max((section.positions.last ?? 1) - (section.positions.first ?? 0), 1) / 20 : max((section.positions.last ?? 1) - (section.positions.first ?? 0), 1))
            .frame(minHeight: 280)
            Toggle("Zoom in 20× (scroll along)", isOn: $zoom)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Highest material").foregroundStyle(.secondary); Text("\(Length.mm(section.exact.max() ?? 0)) mm") }
                GridRow { Text("Lowest").foregroundStyle(.secondary); Text("\(Length.mm(section.exact.min() ?? 0)) mm") }
                if let l = section.leftAbovePart, let c = section.cutIntoPart {
                    GridRow { Text("Most left above the part").foregroundStyle(.secondary); Text("\(Int((l * 1000).rounded())) µm") }
                    GridRow { Text("Deepest into the part").foregroundStyle(.secondary)
                        Text(c < 0.001 ? "none" : "\(Int((c * 1000).rounded())) µm").foregroundStyle(c > 0.02 ? Theme.danger : .primary) }
                }
            }
            .font(.callout.monospacedDigit())
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 720)
    }
}

extension AppModel {
    /// A measure point on the simulated stock, in work coordinates.
    func simWorkPoint(_ p: MeasurePoint) -> SIMD2<Double>? {
        guard p.onSim, let wo = simWorkOrigin else { return nil }
        let inv = (renderer.scene.groupTransform(renderer.scene.mesh("simstock")?.group) * simd_float4x4(translation: SIMD3<Float>(wo))).inverse
        let w = inv * SIMD4(p.world, 1)
        return SIMD2(Double(w.x), Double(w.y))
    }
}

/// Export ▸ the formats, for one snapshot.
struct ExportMenu: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    var iconOnly = false
    var body: some View {
        Menu {
            ForEach(AppModel.exportFormats, id: \.ext) { f in
                Button("\(f.title)…") { model.exportSnapshotWithPanel(id, format: f.ext) }
            }
        } label: {
            if iconOnly { Image(systemName: "square.and.arrow.up") } else { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .tint(Color(nsColor: .systemBlue))
        .foregroundStyle(.white)
        .help("Export: clean CAD (NURBS STEP), Rhino mesh, STEP mesh, 3MF, STL, OBJ")
        .accessibilityLabel("Export")
    }
}

/// The Sharpen options: make a snapshot, the one shown, this side's snapshots, export.
struct SharpPanel: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        let mine = model.sharpSnapshots.filter { $0.side == model.viewSide }
        VStack(alignment: .leading, spacing: 12) {
            Text("Export and snapshots").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Make one at the playhead").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    Button("Whole Stock", systemImage: "square.grid.3x3.fill") { close(); model.sharpen() }
                        .buttonStyle(.bordered).foregroundStyle(.primary)
                    Button("Around Point A", systemImage: "scope") {
                        close()
                        if let p = model.measurePoints.first, let w = model.simWorkPoint(p) { model.sharpen(around: w) }
                    }
                    .disabled(model.measurePoints.first.map { !$0.onSim } ?? true)
                    .buttonStyle(.bordered).foregroundStyle(.primary)
                    .help("A 5 mm square at 2.5 µm around Measure's point A (click the stock with Measure on first).")
                }
            }
            if let id = model.shownSnapshot {
                Divider()
                HStack {
                    Label("Shown now", systemImage: "checkmark.seal.fill").font(.callout.weight(.semibold))
                    Spacer()
                    ExportMenu(id: id).fixedSize()
                    Button("Back", systemImage: "arrow.uturn.backward") { close(); model.hideSharp() }
                        .buttonStyle(.bordered).foregroundStyle(.primary)
                        .help("Back to the playback grid")
                }
            }
            if !mine.isEmpty {
                Divider()
                Text("This side's snapshots").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(mine) { rec in
                            let current = model.snapshotIsCurrent(rec)
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rec.name).lineLimit(1)
                                    Text("\(rec.resolutionText) · \(rec.cols.formatted()) × \(rec.rows.formatted()) cells\(current ? "" : " · out of date")")
                                        .font(.caption).foregroundStyle(current ? Color.secondary : Theme.warning)
                                }
                                Spacer(minLength: 8)
                                Button { close(); model.showSnapshot(rec.id) } label: { Image(systemName: "eye") }
                                    .buttonStyle(.bordered).foregroundStyle(.primary)
                                    .disabled(!current).help("Show it").accessibilityLabel("Show \(rec.name)")
                                ExportMenu(id: rec.id, iconOnly: true).fixedSize()
                                Button(role: .destructive) { model.deleteSnapshot(rec.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.bordered).foregroundStyle(Color(nsColor: .systemRed))
                                    .help("Delete it").accessibilityLabel("Delete \(rec.name)")
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            if model.sharpSnapshots.contains(where: { $0.side != model.viewSide }) {
                Text("Other setups' snapshots are listed on their own timelines.").font(.caption).foregroundStyle(.secondary)
            }
            if mine.isEmpty && model.shownSnapshot == nil {
                Text("Export appears here once you've made a snapshot.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
