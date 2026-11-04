import SwiftUI

/// On every page: the machine's state (click to open Machine Control), and while it is connected
/// Feed Hold, Resume and Stop. Their keys (⇧⌘H, ⇧⌘.) are in the Machine menu.
struct MillToolbar: ToolbarContent {
    let app: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button { app.page = .control } label: {
                Label("Mill · \(app.mill.stateWord)", systemImage: app.mill.isOpen ? "cable.connector" : "cable.connector.slash")
                    .labelStyle(.titleAndIcon)
            }
            .help("Open Machine Control (⇧⌘M)")
            if app.mill.isOpen || app.page == .control {
                Button("Feed Hold", systemImage: "pause.fill") { app.mill.feedHold() }
                    .tint(Theme.warning)
                    .disabled(!app.mill.isOpen)
                    .help("Feed hold (⇧⌘H)")
                Button("Resume", systemImage: "play.fill") { app.mill.resume() }
                    .disabled(app.mill.snapshot.gates.resume != nil)
                    .help("Resume after a feed hold")
                Button("Stop", systemImage: "stop.fill") { app.mill.stop() }
                    .tint(Theme.danger)
                    .disabled(!app.mill.isOpen)
                    .help("Stop the machine (⇧⌘.)")
            }
        }
        ToolbarSpacer(.fixed)
    }
}
