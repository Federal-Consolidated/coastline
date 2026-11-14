import SwiftUI

/// What Coastline does and how to drive it: shown once, and from Help ▸ How Coastline Works.
struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss

    private let stages: [(String, String, String)] = [
        ("cube.transparent", "1 · Part", "Load your CAD part and confirm its designed size. New parts start a fresh library-based proposal."),
        ("shippingbox", "2 · Stock", "Choose a blank you own. Coastline recommends fitting stock from your library, preferring blanks with a defined fixture assembly."),
        ("sparkles", "3 · Plan", "Build a job using your cutting tools and workholding. Missing fixture information is explained and can be defined here."),
        ("hand.raised", "4 · Setups", "Review each physical setup: fixture and grip, orientation, allowance, work zero, assigned cuts and tools. Re-clamping and any stock prep belong here."),
        ("point.topleft.down.to.point.bottomright.curvepath", "5 · Toolpaths", "Inspect the cuts, adjust operations and cutting data, and simulate material removal. Regenerate after changing the setup or cuts."),
        ("checklist", "6 · Review", "Walk through the complete job, check the results, then export or open the guided runner. Each program still requires your Run action."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "water.waves").font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading) {
                    Text("Welcome to Coastline").font(.title.weight(.semibold))
                    Text("From a CAD part to a guided job on your machine, one stage at a time.").foregroundStyle(.secondary)
                }
            }
            ForEach(stages, id: \.1) { s in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: s.0).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.1).font(.headline)
                        Text(s.2).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Orbit").bold(); Text("drag in empty space") }
                GridRow { Text("Pan").bold(); Text("two fingers, or ⌥-drag") }
                GridRow { Text("Zoom").bold(); Text("pinch, or the scroll wheel") }
                GridRow { Text("Frame all").bold(); Text("double-click") }
                GridRow { Text("Pages").bold(); Text("⌘1 … ⌘9") }
                GridRow { Text("Playback").bold(); Text("Space plays; ← → a move, ⌥← ⌥→ an operation, ⌘[ ⌘] a step") }
            }
            .font(.callout)
            Label("Every new program runs as an air cut first (spindle off, 10 mm up). Never use compressed air on the machine: vacuum and wipe.",
                  systemImage: "shield.lefthalf.filled")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Get Started") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 600)
    }
}
