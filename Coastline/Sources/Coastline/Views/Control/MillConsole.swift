import MillCore
import SwiftUI

/// Everything sent to and received from the machine (status reports are left out), and a command
/// line. Settings changes and resets are blocked; moves need a homed machine.
struct MillConsole: View {
    @Environment(AppModel.self) private var app
    @State private var line = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @FocusState private var focused: Bool

    var body: some View {
        let mill = app.mill
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Console").font(.headline)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { copy(mill.console) }
                    .labelStyle(.iconOnly)
                    .help("Copy the console")
                Button("Clear", systemImage: "trash") { mill.clearConsole() }
                    .labelStyle(.iconOnly)
                    .help("Clear the console")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(mill.console) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .textSelection(.enabled)
                }
                .onChange(of: mill.console.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                TextField("Command, e.g. $# or G0 X-50", text: $line)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .focused($focused)
                    .onSubmit(send)
                    .onKeyPress(.upArrow) { recall(-1) }
                    .onKeyPress(.downArrow) { recall(1) }
                    .disabled(!mill.isOpen)
                Button("Send", action: send)
                    .plainGlassButton()
                    .disabled(!mill.isOpen || line.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, mill.message == nil ? 14 : 4)
            if let message = mill.message {
                Text(message).font(.caption).foregroundStyle(Theme.warning)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .background(Theme.panelBackground)
    }

    private func row(_ entry: MillConsoleLine) -> some View {
        let (mark, color): (String, Color) = switch entry.kind {
        case .sent: ("→", Theme.accent)
        case .received: ("←", .primary)
        case .realtime: ("⚡", Theme.warning)
        case .note: ("•", .secondary)
        case .error: ("!", Theme.danger)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.time, format: .dateTime.hour().minute().second())
                .foregroundStyle(.tertiary)
            Text(mark).foregroundStyle(color).frame(width: 12)
            Text(entry.text).foregroundStyle(entry.kind == .received ? .primary : color)
        }
        .font(.caption.monospaced())
    }

    private func send() {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if history.last != text { history.append(text) }
        historyIndex = nil
        if app.mill.send(text) { line = "" }
        focused = true
    }

    private func recall(_ step: Int) -> KeyPress.Result {
        guard !history.isEmpty else { return .ignored }
        let index = min(max((historyIndex ?? history.count) + step, 0), history.count)
        historyIndex = index
        line = index < history.count ? history[index] : ""
        return .handled
    }

    private func copy(_ lines: [MillConsoleLine]) {
        let text = lines.map { "\($0.time.formatted(.dateTime.hour().minute().second())) \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
