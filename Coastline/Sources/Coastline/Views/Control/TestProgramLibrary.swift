import MillCore
import SwiftUI

/// The same saved programs in the inspector and Machine menu. Management stays available
/// when disconnected, while running still obeys the session's motion gates.
struct TestProgramsMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let mill = app.mill
        Menu("Test programs…") {
            ForEach(mill.programs.ordered) { program in
                Button {
                    mill.programToConfirm = program
                } label: {
                    if program.isFavorite {
                        Label(program.title, systemImage: "star.fill")
                    } else {
                        Text(program.title)
                    }
                }
                .disabled(program.homesFirst ? !mill.canHome : !mill.canRun)
            }
            if !mill.programs.programs.isEmpty { Divider() }
            Button("Manage Programs…") { mill.showProgramLibrary = true }
        }
        .help("Saved motion checks and setup programs; add, edit or favorite programs in Manage Programs")
    }
}

struct TestProgramLibrarySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SavedTestProgram?
    @State private var removing: SavedTestProgram?

    var body: some View {
        let mill = app.mill
        VStack(alignment: .leading, spacing: 14) {
            Text("Test Programs").font(.title2.weight(.semibold))
            Text("Save your most used motion checks and setup programs. Favorites appear first in the menu.")
                .foregroundStyle(.secondary)
            List {
                if mill.programs.programs.isEmpty {
                    Text("No saved programs. Add a program or restore a built-in below.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
                ForEach(mill.programs.ordered) { program in
                    HStack(spacing: 12) {
                        Button {
                            mill.favoriteProgram(program.id)
                        } label: {
                            Image(systemName: program.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(program.isFavorite ? Theme.accent : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(program.isFavorite ? "Remove \(program.title) from favorites" : "Favorite \(program.title)")
                        .help(program.isFavorite ? "Remove from favorites" : "Add to favorites")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(program.title).fontWeight(.medium)
                            if !program.detail.isEmpty {
                                Text(program.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Edit…") { editing = program }
                            .accessibilityLabel("Edit \(program.title)")
                        Button("Delete", systemImage: "trash", role: .destructive) { removing = program }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Delete \(program.title)")
                    }
                    .padding(.vertical, 5)
                }
            }
            .listStyle(.inset)
            Text("Motion checks allow spindle-off linear moves and dwells, checked against travel. Setup programs also support probing, work offsets, homing and spindle commands through the guided runner’s code checks. All programs use millimeters.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Add Program…", systemImage: "plus") { editing = SavedTestProgram(title: "") }
                Menu("Add Built-in") {
                    ForEach(TestProgram.allCases) { program in
                        Button(program.title) { mill.saveProgram(SavedTestProgram(program)) }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 420, idealHeight: 500)
        .sheet(item: $editing) { program in
            TestProgramEditor(program: program) { mill.saveProgram($0) }
        }
        .confirmationDialog("Delete \(removing?.title ?? "program")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Program", role: .destructive) {
                if let program = removing { mill.removeProgram(program.id) }
                removing = nil
            }
        } message: {
            Text("This removes the saved program from your list.")
        }
    }
}

private struct TestProgramEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var program: SavedTestProgram
    let save: (SavedTestProgram) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(program.title.isEmpty ? "New Test Program" : "Edit Test Program").font(.title2.weight(.semibold))
            TextField("Name", text: $program.title)
            TextField("Description", text: $program.detail, axis: .vertical).lineLimit(2...3)
            Picker("Program type", selection: $program.kind) {
                ForEach(SavedTestProgram.Kind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Favorite", isOn: $program.isFavorite)
            Text("G-code (millimeters)").font(.headline)
            TextEditor(text: $program.code)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Program G-code in millimeters")
                .frame(minHeight: 220)
                .border(.quaternary)
            Text(program.kind == .motionCheck
                 ? "Each run starts with G21, G90 and M5. Use G53 for absolute machine moves, or G91 for relative moves. Only spindle-off linear moves and dwells are allowed; travel is checked before running."
                 : "Setup programs can home, probe, change work offsets and run the spindle. Code is checked with the guided runner's rules and spindle limits. Coastline adds G21, G90 and M5 at the start (after a leading $H). Work-coordinate moves use the controller's soft limits.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let why = program.validationMessage {
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    program.title = program.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(program)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(program.validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 580, height: 590)
    }
}
