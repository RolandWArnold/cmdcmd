import AppKit
import CoreGraphics

/// Plain, `Sendable` snapshot of main-thread-only AppKit display state, captured
/// on the main thread at trigger time and handed to background diagnostics so
/// they never read `NSScreen` / `NSEvent` off-main. All members are value types.
struct DisplaySnapshot: Sendable {
    let cursor: CGPoint
    let activeDisplayID: CGDirectDisplayID
    let activeDisplayBounds: CGRect
}

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

    /// Capture AppKit-derived display state on the MAIN THREAD (cursor + the
    /// display under it). Must be called on-main; the result is a plain value
    /// type safe to hand to background diagnostic work. Mirrors the active-display
    /// pick `Overlay.cursorScreen` makes at the same instant.
    static func snapshotDisplay() -> DisplaySnapshot {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main ?? NSScreen.screens.first
        let id: CGDirectDisplayID
        if let screen {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        } else {
            id = CGMainDisplayID()
        }
        return DisplaySnapshot(cursor: p, activeDisplayID: id, activeDisplayBounds: CGDisplayBounds(id))
    }

    static func runEnumeration(tracker: SpaceTracker, display: DisplaySnapshot) {
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        // `.optionAll` is the empty option set; combine with excludeDesktopElements.
        let all = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []

        let activeSpace = tracker.activeSpaceID()
        let spaceByID = tracker.spaceByID()
        let ids = all.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let spaceMap = tracker.spaceMap(for: ids)
        let displayBounds = display.activeDisplayBounds

        var out = "=== ENUM DIAGNOSTIC ===\n"
        out += "optionOnScreenOnly=\(onScreen.count)  optionAll=\(all.count)  activeSpace=\(activeSpace)  cursor=(\(Int(display.cursor.x)),\(Int(display.cursor.y)))  activeDisplay=#\(display.activeDisplayID) \(rectString(displayBounds))\n"

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

    // MARK: - Phase 1A startup identity + trust

    /// Startup snapshot (Phase 1A): AX trust, the launched bundle path /
    /// identifier / executable, and a codesign identity summary (Identifier,
    /// CDHash, Signature, TeamIdentifier, flags + designated requirement) so
    /// signing-identity drift across rebuilds is visible directly in the log.
    /// Shells out to /usr/bin/codesign once — records what codesign reports
    /// without assuming any TCC mechanism. Gated by the caller on debug; safe to
    /// run off the main thread.
    static func logStartup() {
        let trusted = AXIsProcessTrusted()
        let bundleURL = Bundle.main.bundleURL
        var out = "=== STARTUP DIAGNOSTIC (Phase 1A) ===\n"
        out += "AXIsProcessTrusted=\(trusted)\n"
        out += "bundlePath=\(bundleURL.path)\n"
        out += "bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "-")\n"
        out += "executablePath=\(Bundle.main.executablePath ?? "-")\n"
        let info = runCommand("/usr/bin/codesign", ["-dvvv", bundleURL.path])
        for line in info.split(separator: "\n") {
            let s = String(line)
            if s.contains("Identifier=") || s.contains("CDHash") || s.hasPrefix("Signature")
                || s.contains("TeamIdentifier=") || s.contains("flags=") {
                out += "codesign: \(s)\n"
            }
        }
        let req = runCommand("/usr/bin/codesign", ["-dr", "-", bundleURL.path])
        for line in req.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("designated") { out += "codesign-dr: \(s)\n" }
        }
        Log.write(out)
    }

    // MARK: - Phase 1E off-Space AX backfill probe

    /// Strictly-diagnostic probe (Phase 1E): for every all-Spaces tile candidate,
    /// asks whether AX can resolve a window element for it *right now*, sorting
    /// each into one explicit failure mode (1–6 below).
    ///
    /// CRITICAL: this NEVER reads or writes Overlay's AX cache. It creates its
    /// own per-app AX elements and discards them, so it measures whether
    /// cold-start resolution is *possible* without warming any state the real
    /// pick path would later reuse. Gated by the caller on debug.
    ///
    /// Failure modes, per target window:
    ///   1: AXIsProcessTrusted == false (probe aborts)
    ///   2: AXUIElementCreateApplication ok but kAXWindows failed (logs AXError)
    ///   3: kAXWindows ok but returned zero windows
    ///   4: AX windows returned but _AXUIElementGetWindow failed (logs AXError)
    ///   5: AX window IDs obtained but none matched the target CGWindowID
    ///   6: target CGWindowID matched — a retained AX element WOULD be available
    static func runBackfillProbe(tracker: SpaceTracker) {
        var out = "=== AX BACKFILL PROBE (Phase 1E; diagnostic, does NOT touch the AX cache) ===\n"
        let trusted = AXIsProcessTrusted()
        out += "AXIsProcessTrusted=\(trusted)\n"
        guard trusted else {
            out += "RESULT: [mode 1] AXIsProcessTrusted==false — cannot probe. Re-grant Accessibility, do NOT rebuild, relaunch.\n"
            Log.write(out)
            return
        }

        let all = WindowInfo.enumerate(scope: .allSpaces, tracker: tracker)
        let activeSpace = tracker.activeSpaceID()
        let candidates = all.filter { probeCapturable($0) }
        out += "activeSpace=\(activeSpace) enumerated(all-spaces)=\(all.count) candidates=\(candidates.count)\n"

        let byPid = Dictionary(grouping: candidates, by: { $0.processID })
            .sorted { ($0.value.first?.applicationName ?? "") < ($1.value.first?.applicationName ?? "") }

        // (app, off-active-Space?, resolved?) per target, for the gate verdict.
        var results: [(app: String, off: Bool, resolved: Bool)] = []

        for (pid, wins) in byPid {
            let app = wins.first?.applicationName ?? "?"
            out += "--- app=\(app) pid=\(pid) targets=\(wins.count) ---\n"

            let appEl = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let listErr = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef)
            let axWindows = (windowsRef as? [AXUIElement]) ?? []

            var axIDs = Set<CGWindowID>()
            var getWinFailures = 0
            if listErr == .success {
                for axWin in axWindows {
                    var wid: CGWindowID = 0
                    let err = _AXUIElementGetWindow(axWin, &wid)
                    if err == .success { axIDs.insert(wid) } else { getWinFailures += 1 }
                }
            }

            if listErr != .success {
                out += "  [mode 2] kAXWindows FAILED err=\(listErr.rawValue)\n"
            } else if axWindows.isEmpty {
                out += "  [mode 3] kAXWindows ok but ZERO windows returned\n"
            } else {
                out += "  kAXWindows ok count=\(axWindows.count)"
                if getWinFailures > 0 { out += " [mode 4] _AXUIElementGetWindow failed=\(getWinFailures)/\(axWindows.count)" }
                out += " resolvedIDs=\(axIDs.sorted())\n"
            }

            for w in wins {
                let off = (w.spaceID != activeSpace)
                let resolved = axIDs.contains(CGWindowID(w.windowID))
                let mode: String
                if listErr != .success { mode = "UNRESOLVED (app kAXWindows failed, mode 2)" }
                else if axWindows.isEmpty { mode = "UNRESOLVED (zero AX windows, mode 3)" }
                else if resolved { mode = "RESOLVED — retained AX element WOULD be available (mode 6)" }
                else { mode = "UNRESOLVED (no AX window matched this CGWindowID, mode 5)" }
                out += "    target wid=\(w.windowID) isOnScreen=\(w.isOnScreen ? 1 : 0) space=\(w.spaceID.map(String.init) ?? "-") type=\(w.spaceType.map { "\($0)" } ?? "-") onActiveSpace=\(off ? 0 : 1) → \(mode)\n"
                results.append((app: app, off: off, resolved: resolved))
            }
        }

        // Gate verdict — restricted to off-active-Space targets (the cold-start case).
        out += "--- probe gate summary (off-active-Space candidates) ---\n"
        let offResults = results.filter { $0.off }
        for app in Set(offResults.map { $0.app }).sorted() {
            let t = offResults.filter { $0.app == app }
            out += "  \(app): off-active-Space targets=\(t.count) resolved=\(t.filter { $0.resolved }.count)\n"
        }
        if offResults.isEmpty {
            out += "GATE: INCONCLUSIVE — no off-active-Space candidates. Ensure real windows exist on OTHER Spaces (incl. a native full-screen Space), then re-run.\n"
        } else {
            let totalRes = offResults.filter { $0.resolved }.count
            out += totalRes > 0
                ? "GATE: AX resolved \(totalRes)/\(offResults.count) off-active-Space target(s). Launch-time backfill CAN cache these → Phase 2 viable for the resolved apps.\n"
                : "GATE: AX resolved 0/\(offResults.count) off-active-Space target(s). kAXWindows is blind to these off-Space windows → a registry backfill will NOT satisfy the cold-start test for them. Product decision required.\n"
        }
        Log.write(out)
    }

    /// Mirror of `Overlay.isCapturable` for the probe's candidate set (real app
    /// content windows: own-pid / empty-owner / system-owner / sub-200px /
    /// non-layer-0 dropped). Kept local so the probe never imports Overlay state.
    private static func probeCapturable(_ w: WindowInfo) -> Bool {
        if w.processID == getpid() { return false }
        if w.applicationName.isEmpty { return false }
        if systemOwners.contains(w.applicationName) { return false }
        if w.frame.width < 200 || w.frame.height < 200 { return false }
        if w.layer != 0 { return false }
        return true
    }

    /// Run a command, capturing combined stdout+stderr (codesign writes to
    /// stderr). Diagnostic-only helper.
    private static func runCommand(_ launchPath: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return "runCommand(\(launchPath)) failed: \(error)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
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
