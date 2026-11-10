import AppKit
import SwiftUI

/// Native inspectors can extend into a unified/floating toolbar. Measure the actual window
/// content-layout boundary rather than assuming a fixed toolbar height or another safe area.
struct ToolbarContentInset: NSViewRepresentable {
    @Binding var top: CGFloat

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.changed = { value in if abs(top - value) > 0.5 { top = value } }
        view.needsLayout = true
    }

    final class Probe: NSView {
        var changed: ((CGFloat) -> Void)?
        private var reported: CGFloat?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            guard let window else { return }
            let rect = convert(bounds, to: nil)
            let overlap = max(0, rect.maxY - window.contentLayoutRect.maxY).rounded(.up)
            if reported != overlap, ProcessInfo.processInfo.environment["COASTLINE_DEV"] == "1" {
                let message = "Inspector toolbar inset: \(overlap) pt (panel top \(rect.maxY), content top \(window.contentLayoutRect.maxY))\n"
                try? FileHandle.standardOutput.write(contentsOf: Data(message.utf8))
                reported = overlap
            }
            DispatchQueue.main.async { [weak self] in self?.changed?(overlap) }
        }
    }
}
