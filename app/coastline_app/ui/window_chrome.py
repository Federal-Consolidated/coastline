"""The Mac app's window: content under a transparent, 52-point unified title bar, the traffic
lights centred in it (as SwiftUI places them with a toolbar). Qt draws everything else."""

from __future__ import annotations

import sys


def apply(window) -> None:
    """`window`: the QQuickWindow. On macOS, an empty unified NSToolbar makes the title bar as
    tall as the Swift app's and centres the traffic lights in it."""
    from PySide6.QtGui import QGuiApplication
    if sys.platform != "darwin" or QGuiApplication.platformName() != "cocoa":
        return
    try:
        import AppKit
        import objc
    except ImportError:
        return
    view = objc.objc_object(c_void_p=int(window.winId()))
    ns_window = view.window()
    if ns_window is None:
        return
    ns_window.setTitlebarAppearsTransparent_(True)
    ns_window.setTitleVisibility_(AppKit.NSWindowTitleHidden)
    ns_window.setStyleMask_(ns_window.styleMask() | AppKit.NSWindowStyleMaskFullSizeContentView)
    toolbar = AppKit.NSToolbar.alloc().initWithIdentifier_("coastline")
    toolbar.setShowsBaselineSeparator_(False)
    ns_window.setToolbar_(toolbar)
    ns_window.setToolbarStyle_(AppKit.NSWindowToolbarStyleUnified)
    ns_window.setAppearance_(AppKit.NSAppearance.appearanceNamed_(AppKit.NSAppearanceNameDarkAqua))
