import MillCore
import SwiftUI

/// The Machine menu: everything for the machine in one place, with the stop keys.
struct MachineCommands: Commands {
    let model: AppModel

    var body: some Commands {
        let mill = model.mill
        CommandMenu("Machine") {
            Button("Machine Control") { model.page = .control }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Guided Mode") { model.openGuidedMode() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Show Console") {
                model.page = .control
                mill.showConsole = true
            }
            Divider()
            if mill.isPortOpen {
                Button("Disconnect") { mill.disconnect() }
            } else {
                Button("Connect") {
                    model.page = .control
                    mill.connect()
                }
            }
            Button("Home…") {
                model.page = .control
                mill.requestHome()
            }
            .disabled(!mill.canHome)
            Menu("Test Programs") {
                ForEach(mill.programs.ordered) { program in
                    Button("\(program.title)…") {
                        model.page = .control
                        mill.programToConfirm = program
                    }
                    .disabled(program.homesFirst ? !mill.canHome : !mill.canRun)
                }
                Divider()
                Button("Open G-code File…") {
                    model.page = .control
                    mill.openProgramFile()
                }
                Button("Manage Programs…") { mill.showProgramLibrary = true }
            }
            Menu("Go To") {
                Button("Work Zero (X Y)…") { show(.workZero) }
                Button("Home Position…") { show(.home(mill.snapshot)) }
                Button("Tool-Change Position…") { show(.toolChange(model.controlMachine.toolChangeMoves)) }
                Divider()
                Button("Position…") { show(.position(mill.snapshot)) }
            }
            .disabled(!mill.canRun || !mill.allowJog)
            Menu("Overrides") {
                Button("Feed +10%") { mill.override(.feedPlus10) }
                Button("Feed −10%") { mill.override(.feedMinus10) }
                Button("Feed 100%") { mill.override(.feedReset) }
                Divider()
                Button("Rapid 100%") { mill.override(.rapid100) }
                Button("Rapid 50%") { mill.override(.rapid50) }
                Button("Rapid 25%") { mill.override(.rapid25) }
                Divider()
                Button("Spindle +10%") { mill.override(.spindlePlus10) }
                Button("Spindle −10%") { mill.override(.spindleMinus10) }
                Button("Spindle 100%") { mill.override(.spindleReset) }
            }
            .disabled(!mill.isPortOpen)
            Button("Spindle Stop") { mill.spindleOff() }
                .disabled(!mill.isPortOpen)
            Divider()
            Button("Feed Hold") { mill.feedHold() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!mill.isPortOpen)
            Button("Resume") { mill.resume() }
                .disabled(!mill.canResume)
            Button("Stop") { mill.stop() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!mill.isPortOpen)
            Button("Soft Reset") { mill.softReset() }
                .disabled(!mill.isPortOpen)
        }
    }

    private func show(_ request: GoToRequest?) {
        model.page = .control
        model.mill.goTo = request
    }
}
