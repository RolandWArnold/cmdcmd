import AppKit
import CoreGraphics

/// Standalone enumeration diagnostic (spec §7.3 / §8).
///
/// Answers the §5 empirical gate: does `CGWindowListCopyWindowInfo` with
/// `.optionAll` actually surface windows from other Spaces and native
/// full-screen Spaces on this machine? Run it from a native full-screen Space
/// and read /tmp/cmdcmd.log: every other-Space window should appear in the
/// `.optionAll` list with a correct Space ID (correct because §7.1 landed
/// first).
///
/// Gated by `Config.debugLoggingEnabled` (the `debugLogging` config flag, which
/// also honours the `CMDCMD_DEBUG=1` environment override).
enum Diagnostics {
    /// Mirror of `Overlay.systemOwners` so the standalone diagnostic can
    /// preview the §6 keep/drop decision. Consolidated with the real predicate
    /// when the all-Spaces filter lands in §7.6.
    private static let systemOwners: Set<String> = [
        "Window Server", "Dock", "WindowManager", "Control Center",
        "Spotlight", "NotificationCenter", "SystemUIServer",
        "TextInputMenuAgent", "Wallpaper",
    ]

    static func runEnumeration(tracker: SpaceTracker) {
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        // `.optionAll` is the empty option set; combine with excludeDesktopElements.
        let all = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []

        let activeSpace = tracker.activeSpaceID()
        let spaceByID = tracker.spaceByID()
        let ids = all.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let spaceMap = tracker.spaceMap(for: ids)
        let displayBounds = activeDisplayBounds()

        var out = "=== ENUM DIAGNOSTIC ===\n"
        out += "optionOnScreenOnly=\(onScreen.count)  optionAll=\(all.count)  activeSpace=\(activeSpace)  activeDisplay=\(rectString(displayBounds))\n"

        var keptCount = 0
        var keptOffActiveSpace = 0
        var keptSpaces: Set<String> = []

        for dict in all {
            guard let id = dict[kCGWindowNumber as String] as? CGWindowID else { continue }
            let pid = (dict[kCGWindowOwnerPID as String] as? pid_t) ?? -1
            let owner = (dict[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (dict[kCGWindowName as String] as? String) ?? ""
            let layer = (dict[kCGWindowLayer as String] as? Int) ?? 0
            let onScreenFlag = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let bounds = rect(from: dict[kCGWindowBounds as String])
            let spaceID = spaceMap[id]
            let spaceType = spaceID.flatMap { spaceByID[$0]?.type }
            let isActiveSpace = spaceID == activeSpace
            let onActiveDisplay = mostlyOn(display: displayBounds, window: bounds)

            let (decision, reason) = filterPreview(
                pid: pid, owner: owner, bounds: bounds, layer: layer,
                spaceID: spaceID, spaceType: spaceType
            )
            if decision == "KEEP" {
                keptCount += 1
                keptSpaces.insert("\(spaceID.map(String.init) ?? "-"):\(spaceType.map { "\($0)" } ?? "-")")
                if !isActiveSpace { keptOffActiveSpace += 1 }
            }

            out += "  wid=\(pad(id, 6)) pid=\(pad(pid, 6)) layer=\(pad(layer, 3))"
            out += " onScreen=\(onScreenFlag ? "1" : "0")"
            out += " space=\(spaceID.map(String.init) ?? "-")"
            out += " type=\(spaceType.map { "\($0)" } ?? "-")"
            out += " activeSpace=\(isActiveSpace ? "1" : "0")"
            out += " onActiveDisplay=\(onActiveDisplay ? "1" : "0")"
            out += " \(decision)(\(reason))"
            out += " \(owner) :: \(title)\n"
        }

        out += "--- gate summary ---\n"
        out += "kept(preview)=\(keptCount)  keptOffActiveSpace=\(keptOffActiveSpace)  keptSpaces=\(keptSpaces.sorted())\n"
        out += keptOffActiveSpace > 0
            ? "GATE: PASS — .optionAll surfaces \(keptOffActiveSpace) keep-eligible window(s) on non-active Space(s).\n"
            : "GATE: INCONCLUSIVE — no keep-eligible windows on a non-active Space. Ensure real app windows exist on OTHER Spaces, then re-run.\n"
        Log.write(out)
    }

    // MARK: - §6 keep/drop preview

    private static func filterPreview(
        pid: pid_t, owner: String, bounds: CGRect, layer: Int,
        spaceID: CGSSpaceID?, spaceType: SpaceType?
    ) -> (decision: String, reason: String) {
        if pid == getpid() { return ("DROP", "own-pid") }
        if owner.isEmpty { return ("DROP", "no-owner") }
        if systemOwners.contains(owner) { return ("DROP", "system-owner") }
        if bounds.width < 200 || bounds.height < 200 { return ("DROP", "too-small") }
        if layer != 0 { return ("DROP", "non-layer-0") }
        guard let spaceID, spaceID != 0 else { return ("DROP", "no-space") }
        _ = spaceID
        switch spaceType {
        case .user, .fullscreen, .tiled: return ("KEEP", "ok")
        case .system: return ("DROP", "space-system")
        case .none: return ("DROP", "space-unknown")
        }
    }

    // MARK: - helpers

    /// Active display = the one under the cursor (matches Overlay.cursorScreen).
    private static func activeDisplayBounds() -> CGRect {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return .zero }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        return CGDisplayBounds(id)
    }

    private static func mostlyOn(display: CGRect, window: CGRect) -> Bool {
        let inter = window.intersection(display)
        guard !inter.isNull else { return false }
        let interArea = inter.width * inter.height
        let total = window.width * window.height
        return total > 0 && interArea / total >= 0.5
    }

    private static func rect(from value: Any?) -> CGRect {
        guard let b = value as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return .zero }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func rectString(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    private static func pad(_ value: some BinaryInteger, _ width: Int) -> String {
        String(value).padding(toLength: max(width, String(value).count), withPad: " ", startingAt: 0)
    }
}
