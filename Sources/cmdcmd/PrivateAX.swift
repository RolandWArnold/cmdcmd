import AppKit

/// `_AXUIElementGetWindow` maps an `AXUIElement` (an app's AX window object) to
/// its `CGWindowID` — the bridge between the Accessibility and CoreGraphics
/// window namespaces. It's a private HIServices symbol (no public header), bound
/// via `@_silgen_name`; it resolves at link time because HIServices is already
/// linked (via AppKit), unlike the SkyLight SLPS symbols which need dlsym.
///
/// Module-internal (no `private`) so the single binding is shared by both
/// `Overlay` (capture + raise) and `Diagnostics` (the Phase 1E backfill probe).
/// A second `@_silgen_name` for the same symbol would clash at link time, so it
/// lives here once rather than file-private in `Overlay.swift`.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ axEl: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError
