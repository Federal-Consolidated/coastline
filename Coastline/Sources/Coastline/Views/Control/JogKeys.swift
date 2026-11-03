import AppKit
import MillCore
import SwiftUI

/// The jog keys on the Control page, as the jog buttons: ↑ ↓ the table (X− up, X+ down),
/// ← → the gantry (Y), Page Up / Page Down or ⇧↑ ⇧↓ the spindle (Z+ out, Z− in).
///
/// They work only in this page's window, without a sheet, while Allow Jog is on and no text
/// field or focused control wants the keys. A step per key press (repeats are ignored), or in
/// hold-to-jog, motion while the key is down. The hold ends when the key comes up, when the
/// window loses the keys, when the app is left and when the page goes away.
struct JogKeys: NSViewRepresentable {
    let mill: MillControl

    func makeNSView(context: Context) -> KeyView { KeyView(mill: mill) }
    func updateNSView(_ view: KeyView, context: Context) {}

    final class KeyView: NSView {
        private let mill: MillControl
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        /// The key that holds a jog now.
        private var heldKey: UInt16?

        init(mill: MillControl) {
            self.mill = mill
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            remove()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                // Local monitors run on the main thread, with the event being dispatched.
                nonisolated(unsafe) let event = event
                let used = MainActor.assumeIsolated { self?.handle(event) == true }
                return used ? nil : event
            }
            let center = NotificationCenter.default
            let letGo: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.letGo() }
            }
            observers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: letGo),
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: letGo),
            ]
        }

        private func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            letGo()
        }

        /// True when the key was used (it goes no further).
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            if event.type == .keyUp {
                guard event.keyCode == heldKey else { return false }
                letGo()
                return true
            }
            guard window.attachedSheet == nil, event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                  let (axis, direction) = Self.jog(event) else { return false }
            if let responder = window.firstResponder, KeyPassThrough.wantsKeys(responder) { return false }
            guard mill.allowJog else { return false }
            if event.isARepeat { return true }  // the step or the hold is already under way
            if mill.jogHold {
                guard heldKey == nil else { return true }
                mill.startHold(axis, direction)
                if mill.heldJog != nil { heldKey = event.keyCode }
            } else {
                mill.jog(axis, direction)
            }
            return true
        }

        /// Ends any hold, also one held with the mouse (no-op without one).
        private func letGo() {
            heldKey = nil
            mill.endHold()
        }

        static func jog(_ event: NSEvent) -> (MillCore.Axis, Double)? {
            let shift = event.modifierFlags.contains(.shift)
            switch event.specialKey {
            case .upArrow?: return shift ? (.z, 1) : (.x, -1)
            case .downArrow?: return shift ? (.z, -1) : (.x, 1)
            case .leftArrow?: return shift ? nil : (.y, -1)
            case .rightArrow?: return shift ? nil : (.y, 1)
            case .pageUp?: return (.z, 1)
            case .pageDown?: return (.z, -1)
            default: return nil
            }
        }
    }
}
