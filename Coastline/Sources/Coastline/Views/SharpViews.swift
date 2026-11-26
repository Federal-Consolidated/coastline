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
            // One control, styled as Play: clicking it sharpens the whole stock (or, when a
            // snapshot is shown, goes back); its arrow opens the options, snapshots and export.
            Menu {
                Section("Make a sharp snapshot here") {
                    Button("Whole Stock", systemImage: "square.grid.3x3.fill") { model.sharpen() }
                    Button("Around Measure Point A (5 mm, 2.5 µm)", systemImage: "scope") {
                        if let p = model.measurePoints.first, let w = model.simWorkPoint(p) { model.sharpen(around: w) }
                    }
                    .disabled(model.measurePoints.first.map { !$0.onSim } ?? true)
                }
                if let id = model.shownSnapshot {
                    Section("The snapshot shown") {
                        Button("Back to the Playback Grid", systemImage: "arrow.uturn.backward") { model.hideSharp() }
                        Button("Export STL…", systemImage: "square.and.arrow.up") { model.exportSnapshotWithPanel(id, format: "stl") }
                        Button("Export OBJ…", systemImage: "square.and.arrow.up") { model.exportSnapshotWithPanel(id, format: "obj") }
                    }
                }
                let mine = model.sharpSnapshots.filter { $0.side == model.viewSide }
                if !mine.isEmpty {
                    Section("Snapshots of this side") {
                        ForEach(mine) { rec in
                            Menu {
                                Button("Show", systemImage: "eye") { model.showSnapshot(rec.id) }
                                    .disabled(!model.snapshotIsCurrent(rec))
                                Button("Export STL…", systemImage: "square.and.arrow.up") { model.exportSnapshotWithPanel(rec.id, format: "stl") }
                                Button("Export OBJ…", systemImage: "square.and.arrow.up") { model.exportSnapshotWithPanel(rec.id, format: "obj") }
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSnapshot(rec.id) }
                            } label: {
                                Text(rec.name + (model.snapshotIsCurrent(rec) ? "" : " · out of date"))
                                Text("\(rec.resolutionText) · \(rec.cols.formatted()) × \(rec.rows.formatted()) cells")
                            }
                        }
                    }
                }
                if model.sharpSnapshots.contains(where: { $0.side != model.viewSide }) {
                    Text("Other setups' snapshots show on their own timelines.")
                }
            } label: {
                if compact {
                    BarIconLabel(symbol: symbol)
                } else {
                    Label(title, systemImage: symbol).font(.callout.weight(.semibold))
                }
            } primaryAction: {
                if shown { model.hideSharp() } else { model.sharpen() }
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .tint(Theme.accent)
            .foregroundStyle(.white)
            .fixedSize()
            .help(shown
                  ? "Showing a sharp snapshot. Click to go back to the playback grid; the arrow has export and your snapshots."
                  : "Click: re-simulate the whole stock up to the playhead at high resolution (about 10 µm; the playback grid is \(Length.mm(model.heightmap?.cell ?? 0)) mm). The arrow: a detail around a measured point, your snapshots, export.")
            .accessibilityLabel(shown ? "Sharp snapshot shown" : "Sharpen")
            .accessibilityHint(shown ? "Goes back to the playback grid" : "Sharpens the whole stock")
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
