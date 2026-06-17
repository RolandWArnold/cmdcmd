import AppKit

final class Overlay {
    private var window: NSWindow?
    private var view: OverlayView?
    private var backgroundLayer: CALayer?
    private var visible = false
    private var allTiles: [Tile] = []
    private var tiles: [Tile] = []
    private var gridCols: Int = 1
    private var selectedIndex: Int = 0
    private var isZoomed = false
    private var savedFrames: [CGRect] = []
    private var prevFrontPID: pid_t = 0
    private var prevFrontTitle: String = ""
    private var prevPickedWindowID: CGWindowID?
    private var dragState: DragState?
    private var lastLetterJump: String?
    private let tracker: SpaceTracker
    private let registry: WindowAXRegistry
    private var config: Config

    func updateConfig(_ config: Config) {
        self.config = config
        view?.letterPickActive = config.tilePicksMode == .letters
        if config.tilePicksMode != .letters {
            pickBuffer = ""
        }
    }

    private var displayKey: String = "main"
    private var activeScreen: NSScreen?

    private var paneColors: [CGWindowID: String] = [:]

    // Retained AXUIElements live in `WindowAXRegistry` (injected). Phase A0 feeds
    // it only from the show-time capture path, exactly as the old static
    // axElementCache did; the registry adds use-time validation + logging and is
    // the seam later phases grow (launch backfill, activation scans, observers).

    private struct DragState {
        var index: Int
        var offset: CGPoint
        var startPoint: CGPoint
        var moved: Bool
    }

    private var savedOrder: [CGWindowID] {
        get {
            (UserDefaults.standard.array(forKey: "tileOrder.\(displayKey)") as? [NSNumber] ?? [])
                .map { $0.uint32Value }
        }
        set {
            UserDefaults.standard.set(newValue.map { NSNumber(value: $0) }, forKey: "tileOrder.\(displayKey)")
        }
    }

    private var workspaceObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var activityTimer: Timer?
    private let search = SearchField()
    private var searchQuery: String = ""
    private var searching: Bool = false

    private var refreshGeneration: Int = 0

    private let labelAssigner = LabelAssigner()
    private var tileLabels: [CGWindowID: String] = [:]
    private var pickBuffer: String = ""

    private static var usageOrder: [String] {
        get { (UserDefaults.standard.array(forKey: "appUsageOrder") as? [String]) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(128)), forKey: "appUsageOrder") }
    }

    private static func usageKey(pid: pid_t, bundleIdentifier: String?) -> String {
        if let id = bundleIdentifier, !id.isEmpty { return id }
        return "pid:\(pid)"
    }

    private static func usageKey(for tile: Tile) -> String {
        usageKey(pid: tile.ownerPID, bundleIdentifier: tile.window.bundleIdentifier)
    }

    private static func recordUse(of app: NSRunningApplication) {
        guard app.processIdentifier != getpid(), app.activationPolicy == .regular else { return }
        let key = usageKey(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
        var order = usageOrder.filter { $0 != key }
        order.insert(key, at: 0)
        usageOrder = order
    }

    init(tracker: SpaceTracker, config: Config, registry: WindowAXRegistry) {
        self.tracker = tracker
        self.registry = registry
        self.config = config
        workspaceObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.visible, !self.isPicking else { return }
            self.hide(activatePrevious: false)
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let self, self.isPicking, self.config.debugLoggingEnabled {
                Log.write("notify: didActivateApplication DURING pick → \(app.localizedName ?? "?")#\(app.processIdentifier)")
            }
            Self.recordUse(of: app)
        }
    }

    private var isPicking = false

    deinit {
        if let o = workspaceObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }

    func toggle() {
        if config.debugLoggingEnabled {
            Log.write("command action=toggle visible=\(visible) NSApp.isActive=\(NSApp.isActive)")
        }
        if visible {
            if NSApp.isActive {
                if config.debugLoggingEnabled { Log.write("toggle: visible & NSApp.isActive=true → dismiss()") }
                dismiss()
            } else {
                // Phase 1 point 5: INSTRUMENT ONLY — behavior unchanged. This is
                // the "toggle() trap": NSApp.activate on a non-activating panel can
                // pull the overlay off a full-screen Space. The log records whether
                // the cold-start repro actually reaches this branch; the proposed
                // non-activating reassertion is deferred until the logs confirm it.
                if config.debugLoggingEnabled { Log.write("toggle: visible & NSApp.isActive=false → REASSERT branch (NSApp.activate+makeKey) [toggle-trap candidate REACHED]") }
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                if let v = view { window?.makeFirstResponder(v) }
            }
        } else {
            if config.debugLoggingEnabled { Log.write("toggle: not visible → show()") }
            show()
        }
    }

    /// Close the overlay — NEVER a pick. Escape and trigger re-press both land
    /// here; committing the highlighted tile is reserved for the explicit paths
    /// (`.pick` / number key / click / letter match) which call `pick()` directly.
    /// `hide()` restores focus to the previously-front app, so this is a true cancel.
    private func dismiss() {
        guard visible, !isPicking else { return }
        if config.debugLoggingEnabled {
            let hl = tiles.indices.contains(selectedIndex) ? String(CGWindowID(tiles[selectedIndex].window.windowID)) : "-"
            Log.write("dismiss → hide (no pick) highlightedWID=\(hl)")
        }
        hide()
    }

    private func show() {
        let t0 = CFAbsoluteTimeGetCurrent()
        let prevApp = NSWorkspace.shared.frontmostApplication
        prevFrontPID = prevApp?.processIdentifier ?? 0
        if let prevApp { Self.recordUse(of: prevApp) }
        prevFrontTitle = focusedWindowTitle(pid: prevFrontPID) ?? ""
        let screen = Self.cursorScreen()
        activeScreen = screen
        displayKey = Self.displayKeyString(for: screen)
        visible = true
        refreshGeneration &+= 1
        let gen = refreshGeneration
        startActivityTimer()
        Log.debug(String(format: "show: setup=%.1fms prevFrontPID=%d title=\"%@\"",
                         (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                         prevFrontPID, prevFrontTitle as NSString))

        Task { await prepareAndShow(gen: gen, screen: screen) }
    }

    private func renderOverlay(windows: [WindowInfo], screen: NSScreen) {
        guard visible else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let displayBounds = CGDisplayBounds(Self.displayID(for: screen))
        let visibleFrame = screen.visibleFrame
        let scope = config.windowScopeOrDefault
        let candidates = windows
            .filter(Self.isCapturable)
            .filter { Self.passesScopeFilter($0, scope: scope, displayBounds: displayBounds) }
        if config.debugLoggingEnabled {
            Log.write("renderOverlay scope=\(scope.rawValue) display=\(Int(displayBounds.width))x\(Int(displayBounds.height)) enumerated=\(windows.count) candidates=\(candidates.count)")
        }
        let tFilter = CFAbsoluteTimeGetCurrent()
        let createdWindow = window == nil
        let w = window ?? makeWindow(frame: visibleFrame)
        window = w
        w.setFrame(visibleFrame, display: false)
        w.alphaValue = 1
        let tWindow = CFAbsoluteTimeGetCurrent()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        installTiles(candidates: candidates)
        // Match each tile's z-order to its source window's WindowServer
        // z-order (candidates[0] is front-most) so tiles overlap correctly
        // at the start of show / end of dismiss instead of shuffling past
        // each other mid-flight.
        for (i, c) in candidates.enumerated() {
            let z = CGFloat(candidates.count - i)
            if let t = allTiles.first(where: { $0.window.windowID == c.windowID }) {
                t.layer.zPosition = z
            }
        }
        // Capture each tile's final grid frame, then teleport to its source
        // window frame so animateShow can fly all tiles in Exposé-style.
        let gridFrames = tiles.map { $0.layer.frame }
        if config.animations {
            backgroundLayer?.opacity = 0
            for t in tiles {
                let src = Self.contentLocalRect(forSourceCGFrame: t.window.frame, overlayWindow: w)
                t.setFrame(src)
            }
        }
        CATransaction.commit()
        let tTiles = CFAbsoluteTimeGetCurrent()
        presentOverlayWindow(w)
        let tFront = CFAbsoluteTimeGetCurrent()
        animateShow(gridFrames: gridFrames)
        let tEnd = CFAbsoluteTimeGetCurrent()
        Log.debug(String(format: "render: filter=%.1f window=%.1f(new=%@) installTiles=%.1f orderFront+activate=%.1f animate=%.1f total=%.1f n=%d",
                         (tFilter - t0) * 1000,
                         (tWindow - tFilter) * 1000, createdWindow ? "yes" : "no",
                         (tTiles - tWindow) * 1000,
                         (tFront - tTiles) * 1000,
                         (tEnd - tFront) * 1000,
                         (tEnd - t0) * 1000,
                         candidates.count))
        // 1B: per-tile facts, dispatched off-main AFTER present so the AX
        // aliveness IPC per tile never delays the trigger → present path.
        if config.debugLoggingEnabled {
            let snapshot = candidates
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.logTiles(snapshot) }
        }
    }

    /// Phase 1B: identity + Space metadata + retained-AX state for each tile, to
    /// pin down which windows lack a cached AX handle at cold start. Runs off the
    /// main thread (dispatched after present) — AX queries here are read-only and
    /// must not perturb trigger → present timing.
    private func logTiles(_ windows: [WindowInfo]) {
        for w in windows {
            let wid = CGWindowID(w.windowID)
            let (_, aliveDesc) = Self.axAliveness(registry.peek(for: wid)?.element)
            Log.write("tile: wid=\(wid) pid=\(w.processID) app=\(w.applicationName) title=\"\(w.title ?? "")\" isOnScreen=\(w.isOnScreen) space=\(w.spaceID.map(String.init) ?? "-") type=\(w.spaceType.map { "\($0)" } ?? "-") display=\(w.displayUUID ?? "-") \(aliveDesc)")
        }
    }

    /// Bring the overlay to the very front, even over a native full-screen
    /// Space. Activate the app *first*, then order / raise / key — full-screen
    /// Spaces are finicky about ordering a window whose owning app isn't active
    /// yet. Re-asserted once on the next main-loop tick because the first
    /// attempt can land before the window has joined the Space.
    private func presentOverlayWindow(_ w: NSWindow) {
        // EXPERIMENT: order a nonactivating panel WITHOUT activating the app.
        // NSApp.activate on a regular app forces a switch to cmdcmd's home Space
        // (the underlying user Space), which was pulling the overlay off the
        // active full-screen Space. A nonactivating panel can become key and
        // surface over a full-screen app on the current Space without that.
        w.level = .screenSaver
        w.orderFrontRegardless()
        w.makeKeyAndOrderFront(nil)
        if let v = view { w.makeFirstResponder(v) }
        logOverlaySpace(w, tag: "present")

        DispatchQueue.main.async { [weak self] in
            guard let self, self.visible, self.window === w else { return }
            w.orderFrontRegardless()
            w.makeKeyAndOrderFront(nil)
            if let v = self.view { w.makeFirstResponder(v) }
            self.logOverlaySpace(w, tag: "present(tick2)")
        }
    }

    /// Success check for the full-screen presentation experiment: is the
    /// cmdcmd-owned overlay panel actually on the active (full-screen) Space?
    /// `nsOnActiveSpace` / `space==activeSpace` true ⇒ it joined the right Space.
    private func logOverlaySpace(_ w: NSWindow, tag: String) {
        guard config.debugLoggingEnabled else { return }
        let wid = CGWindowID(w.windowNumber)
        let space = tracker.spaceMap(for: [wid])[wid]
        let active = tracker.activeSpaceID()
        Log.write("\(tag): overlay wid=\(wid) space=\(space.map(String.init) ?? "-") activeSpace=\(active) nsOnActiveSpace=\(w.isOnActiveSpace) visible=\(w.isVisible) level=\(w.level.rawValue) collection=\(w.collectionBehavior.rawValue) key=\(w.isKeyWindow) main=\(w.isMainWindow) appActive=\(NSApp.isActive) frame=\(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height))")
    }

    private static func cursorScreen() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main ?? NSScreen.screens.first!
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    private static func displayKeyString(for screen: NSScreen) -> String {
        let id = displayID(for: screen)
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let cf = CFUUIDCreateString(nil, uuidRef) as String? {
            return cf
        }
        return "id-\(id)"
    }

    private func startActivityTimer() {
        activityTimer?.invalidate()
        guard config.livePreviewsEnabled else { return }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            for t in self.allTiles { t.updateActivity(now: now) }
        }
    }

    private func stopActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = nil
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        let axWin = win as! AXUIElement
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    private func prepareAndShow(gen: Int, screen: NSScreen) async {
        // Scoped enumeration runs here, off the main thread, so the per-window
        // Space queries (N IPC calls for all-spaces) stay off the show path.
        let windows = WindowInfo.enumerate(scope: config.windowScopeOrDefault, tracker: tracker)
        captureAXElements(for: windows)
        await MainActor.run {
            guard self.visible, gen == self.refreshGeneration else { return }
            self.renderOverlay(windows: windows, screen: screen)
        }
    }

    /// Capture & retain AXUIElements for windows currently on screen (current
    /// Space), keyed by CGWindowID. AX can't enumerate off-Space windows, so we
    /// grab valid handles while they're visible; the retained ref then survives
    /// the window moving to another Space, giving us something raisable at pick
    /// time. Runs off the main thread (called from the async show path).
    private func captureAXElements(for windows: [WindowInfo]) {
        guard AXIsProcessTrusted() else {
            if config.debugLoggingEnabled { Log.write("axCapture: skipped — AXIsProcessTrusted()=false (re-grant Accessibility)") }
            return
        }
        let debug = config.debugLoggingEnabled
        let onScreen = windows.filter { $0.isOnScreen && $0.processID != getpid() }
        let byPid = Dictionary(grouping: onScreen, by: { $0.processID })
        var captured = 0
        for (pid, wins) in byPid {
            let app = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else { continue }
            let infoByWid = Dictionary(wins.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            for axWin in axWindows {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(axWin, &wid) == .success, let info = infoByWid[wid] {
                    registry.store(element: axWin, wid: wid, pid: pid, bundleID: info.bundleIdentifier, title: info.title, source: .showCapture, debug: debug)
                    captured += 1
                }
            }
        }
        if debug {
            Log.write("axCapture: onScreen=\(onScreen.count) captured/updated=\(captured) registrySize=\(registry.count)")
        }
    }

    private static let smoothEasing = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
    private static let baseShowDuration: TimeInterval = 0.2
    private static let baseDismissDuration: TimeInterval = 0.2
    private static let baseHideDuration: TimeInterval = 0.10
    private static let baseLayoutDuration: TimeInterval = 0.18
    private static let basePeekDuration: TimeInterval = 0.12

    private func animationDuration(_ base: TimeInterval) -> TimeInterval {
        base / config.animationSpeedOrDefault
    }

    private func suspendFrames() {
        for t in allTiles { t.suppressFrames = true }
    }

    private func resumeFrames(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            for t in self.allTiles { t.suppressFrames = false }
        }
    }

    private func animateShow(gridFrames: [CGRect]) {
        guard config.animations, !tiles.isEmpty, gridFrames.count == tiles.count else {
            updateSelection()
            return
        }
        suspendFrames()
        // Make sure the teleport-to-source state from renderOverlay is on
        // screen before we kick off the fly-in animation.
        CATransaction.flush()

        let duration = animationDuration(Self.baseShowDuration)
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Self.smoothEasing)
        for (i, t) in tiles.enumerated() {
            t.highlight = .none
            t.setFrame(gridFrames[i])
        }
        backgroundLayer?.opacity = 1
        CATransaction.commit()

        resumeFrames(after: duration)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.updateSelection()
        }
    }

    /// Convert a CGWindowList-style frame (top-left origin, anchored at the
    /// primary display) into the overlay content view's local coordinate
    /// space (bottom-left origin, relative to the overlay window).
    private static func contentLocalRect(forSourceCGFrame cg: CGRect, overlayWindow w: NSWindow) -> CGRect {
        guard let primary = NSScreen.screens.first else { return cg }
        let primaryMaxY = primary.frame.maxY
        let nsX = cg.origin.x
        let nsY = primaryMaxY - cg.origin.y - cg.height
        let winFrame = w.frame
        return CGRect(
            x: nsX - winFrame.origin.x,
            y: nsY - winFrame.origin.y,
            width: cg.width,
            height: cg.height
        )
    }

private static func windowMostlyOn(displayBounds: CGRect, window: WindowInfo) -> Bool {
        let inter = window.frame.intersection(displayBounds)
        guard !inter.isNull else { return false }
        let interArea = inter.width * inter.height
        let total = window.frame.width * window.frame.height
        return total > 0 && interArea / total >= 0.5
    }

    /// Scope-conditional keep/drop, applied after `isCapturable` (§6).
    /// - `.currentSpace`: classic ≥50%-on-active-display test.
    /// - `.allSpaces`: the window must have a managed Space of type
    ///   user/fullscreen/tiled — no managed Space (nil / id 0) means minimized
    ///   or junk, and system/unknown Spaces are not user-facing, both dropped —
    ///   then must be relevant to the active display (V1 is single-display, so
    ///   other-display windows are dropped).
    private static func passesScopeFilter(_ w: WindowInfo, scope: WindowScope, displayBounds: CGRect) -> Bool {
        switch scope {
        case .currentSpace:
            return windowMostlyOn(displayBounds: displayBounds, window: w)
        case .allSpaces:
            guard let type = w.spaceType, (w.spaceID ?? 0) != 0 else { return false }
            switch type {
            case .user, .fullscreen, .tiled: break
            case .system: return false
            }
            return windowRelevantToActiveDisplay(displayBounds: displayBounds, window: w)
        }
    }

    /// All-Spaces display gate (V1 = active display only). A window is relevant
    /// when a meaningful part of it overlaps the active display: same-Space and
    /// off-Space windows on this display share the physical display's
    /// coordinates so they pass, while windows on another display don't overlap
    /// and are dropped. Currently identical to `windowMostlyOn`; kept separate
    /// as the documented knob if full-screen frames ever need looser matching.
    private static func windowRelevantToActiveDisplay(displayBounds: CGRect, window: WindowInfo) -> Bool {
        windowMostlyOn(displayBounds: displayBounds, window: window)
    }

    private func orderTiles(_ tiles: [Tile]) -> [Tile] {
        let saved = savedOrder
        if config.usageOrderingEnabled {
            let usage = Self.usageOrder
            let usageRanks = Dictionary(uniqueKeysWithValues: usage.enumerated().map { ($1, $0) })
            let savedRanks = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($1, $0) })
            return tiles.sorted { a, b in
                let ar = usageRanks[Self.usageKey(for: a)] ?? Int.max
                let br = usageRanks[Self.usageKey(for: b)] ?? Int.max
                if ar != br { return ar < br }
                let asr = savedRanks[CGWindowID(a.window.windowID)] ?? Int.max
                let bsr = savedRanks[CGWindowID(b.window.windowID)] ?? Int.max
                if asr != bsr { return asr < bsr }
                return a.window.windowID < b.window.windowID
            }
        } else if saved.isEmpty {
            return tiles
        } else {
            let presentIDs = Set(tiles.map { CGWindowID($0.window.windowID) })
            let knownInOrder = saved.filter { presentIDs.contains($0) }
            let knownIDs = Set(knownInOrder)
            let known = knownInOrder.compactMap { wid in tiles.first(where: { CGWindowID($0.window.windowID) == wid }) }
            let unknown = tiles.filter { !knownIDs.contains(CGWindowID($0.window.windowID)) }
            return known + unknown
        }
    }

    private func installTiles(candidates: [WindowInfo]) {
        let mcTiles: [Tile] = candidates.map { w in
            Tile(window: w, ownerPID: w.processID)
        }

        let ordered = orderTiles(mcTiles)
        savedOrder = ordered.map { CGWindowID($0.window.windowID) }

        allTiles = ordered
        for t in ordered {
            window?.contentView?.layer?.addSublayer(t.layer)
        }
        rebuildDisplayed()
        let widMatch = prevPickedWindowID.flatMap { wid in tiles.firstIndex(where: { CGWindowID($0.window.windowID) == wid }) }
        let titleMatch = tiles.firstIndex(where: { $0.ownerPID == prevFrontPID && ($0.window.title ?? "") == prevFrontTitle })
        let pidMatch = tiles.firstIndex(where: { $0.ownerPID == prevFrontPID })
        if let i = widMatch ?? titleMatch ?? pidMatch {
            selectedIndex = i
            updateSelection()
        }
        let live = config.livePreviewsEnabled
        Task {
            await withTaskGroup(of: Void.self) { group in
                for t in ordered {
                    group.addTask {
                        await t.snapshot()
                        if live { await t.start() }
                    }
                }
            }
        }
    }

    private func rebuildDisplayed() {
        let displayed = allTiles.filter { Self.matches(tile: $0, query: searchQuery) }
        let visibleSet = Set(displayed.map { ObjectIdentifier($0) })
        for t in allTiles {
            t.layer.isHidden = !visibleSet.contains(ObjectIdentifier(t))
            t.layer.opacity = 1.0
            t.setLabel(nil)
            t.tintColorName = paneColors[CGWindowID(t.window.windowID)]
        }
        tiles = displayed
        applyTileLabels()
        let bounds = window?.contentView?.bounds ?? .zero
        layoutTiles(in: bounds)
        if !tiles.indices.contains(selectedIndex) {
            selectedIndex = max(0, tiles.count - 1)
        }
        updateSelection()
    }

    private func applyTileLabels() {
        switch config.tilePicksMode {
        case .numbers:
            for (i, t) in tiles.enumerated() {
                t.setLabel(i < 9 ? "\(i + 1)" : nil)
            }
        case .letters:
            tileLabels = labelAssigner.assign(allTiles)
            let buffer = pickBuffer
            for t in allTiles {
                let id = CGWindowID(t.window.windowID)
                let label = tileLabels[id]
                let matched: Int
                if !buffer.isEmpty, let label, label.hasPrefix(buffer) {
                    matched = buffer.count
                } else {
                    matched = 0
                }
                t.setLabel(label, matchPrefix: matched)
                if !buffer.isEmpty {
                    let dims = !(label?.hasPrefix(buffer) ?? false)
                    t.layer.opacity = dims ? 0.3 : 1.0
                }
            }
        }
    }

    private static func matches(tile: Tile, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        let app = tile.window.applicationName
        let title = tile.window.title ?? ""
        let haystack = app + " " + title
        return haystack.localizedCaseInsensitiveContains(q)
    }

    private func enterSearch() {
        guard let win = window, let host = win.contentView else { return }
        searching = true
        search.onChange = { [weak self] q in self?.searchQueryChanged(q) }
        search.onCommit = { [weak self] in self?.dispatch(.pick) }
        search.onCancel = { [weak self] in self?.commitSearch() }
        search.onArrow = { [weak self] d in self?.dispatchSearchArrow(d) }
        search.show(in: host, query: searchQuery)
        findSearchTextField(in: host)?.onCmdF = { [weak self] in self?.commitSearch() }
    }

    private func dispatchSearchArrow(_ d: SearchField.ArrowDirection) {
        switch d {
        case .left:  dispatch(.moveLeft)
        case .right: dispatch(.moveRight)
        case .up:    dispatch(.moveUp)
        case .down:  dispatch(.moveDown)
        }
    }

    private func findSearchTextField(in view: NSView) -> SearchTextField? {
        for sub in view.subviews {
            if let f = sub as? SearchTextField { return f }
            if let nested = findSearchTextField(in: sub) { return nested }
        }
        return nil
    }

    private func commitSearch() {
        searching = false
        search.hide()
        if let v = view { window?.makeFirstResponder(v) }
    }

    private func cancelSearch() {
        searching = false
        searchQuery = ""
        search.hide()
        rebuildDisplayed()
        layoutTilesAnimated()
        if let v = view { window?.makeFirstResponder(v) }
    }

    private func searchQueryChanged(_ q: String) {
        searchQuery = q
        rebuildDisplayed()
        layoutTilesAnimated()
    }

    private func tagSelectedColor(_ name: String?) {
        guard tiles.indices.contains(selectedIndex) else { return }
        let id = CGWindowID(tiles[selectedIndex].window.windowID)
        if let name { paneColors[id] = name } else { paneColors.removeValue(forKey: id) }
        tiles[selectedIndex].tintColorName = name
    }

    private func selectApp(startingWith letter: String) {
        guard config.tilePicksMode != .letters,
              config.letterJumpEnabled, !tiles.isEmpty else { return }
        let needle = letter.lowercased()
        let start = lastLetterJump == needle ? selectedIndex + 1 : 0
        let order = Array(start..<tiles.count) + Array(0..<min(start, tiles.count))
        guard let match = order.first(where: { idx in
            tiles[idx].window.applicationName
                .lowercased()
                .hasPrefix(needle)
        }) else { return }
        lastLetterJump = needle
        selectedIndex = match
        updateSelection()
    }

    private func dispatch(_ action: Action) {
        if config.debugLoggingEnabled {
            let hl = tiles.indices.contains(selectedIndex) ? String(CGWindowID(tiles[selectedIndex].window.windowID)) : "-"
            Log.write("command action=\(action.rawValue) highlightedWID=\(hl) sel=\(selectedIndex)/\(tiles.count) pickBuffer=\(pickBuffer.isEmpty ? "-" : pickBuffer) search=\(searchQuery.isEmpty ? "-" : "active") zoomed=\(isZoomed)")
        }
        switch action {
        case .pick: pick()
        case .dismiss:
            if !pickBuffer.isEmpty {
                pickBuffer = ""
                applyTileLabels()
            }
            else if !searchQuery.isEmpty { cancelSearch() }
            else { dismiss() }
        case .search: enterSearch()
        case .moveLeft:  move(dx: -1, dy: 0)
        case .moveRight: move(dx: 1, dy: 0)
        case .moveUp:    move(dx: 0, dy: -1)
        case .moveDown:  move(dx: 0, dy: 1)
        case .swapLeft:  swapSelected(dx: -1, dy: 0)
        case .swapRight: swapSelected(dx: 1, dy: 0)
        case .swapUp:    swapSelected(dx: 0, dy: -1)
        case .swapDown:  swapSelected(dx: 0, dy: 1)
        case .close: closeSelected()
        case .tagGreen:  tagSelectedColor("green")
        case .tagBlue:   tagSelectedColor("blue")
        case .tagRed:    tagSelectedColor("red")
        case .tagYellow: tagSelectedColor("yellow")
        case .tagOrange: tagSelectedColor("orange")
        case .tagPurple: tagSelectedColor("purple")
        case .tagClear:  tagSelectedColor(nil)
        case .pick1: pickIndex(0)
        case .pick2: pickIndex(1)
        case .pick3: pickIndex(2)
        case .pick4: pickIndex(3)
        case .pick5: pickIndex(4)
        case .pick6: pickIndex(5)
        case .pick7: pickIndex(6)
        case .pick8: pickIndex(7)
        case .pick9: pickIndex(8)
        }
    }

    private func closeSelected() {
        guard tiles.indices.contains(selectedIndex) else { return }
        let tile = tiles[selectedIndex]
        let pid = tile.ownerPID
        let windowID = CGWindowID(tile.window.windowID)
        pressCloseButton(pid: pid, windowID: windowID)

        let removed = tile
        tiles.remove(at: selectedIndex)
        allTiles.removeAll { $0 === removed }
        removed.layer.removeFromSuperlayer()
        Task { await removed.stop() }

        savedOrder = allTiles.map { CGWindowID($0.window.windowID) }
        if !tiles.indices.contains(selectedIndex) {
            selectedIndex = max(0, tiles.count - 1)
        }
        renumberTiles()
        layoutTilesAnimated()
        updateSelection()
    }

    private func pressCloseButton(pid: pid_t, windowID: CGWindowID) {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }
        for win in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(win, &wid) == .success, wid == windowID {
                var btnRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &btnRef) == .success,
                   let btn = btnRef, CFGetTypeID(btn) == AXUIElementGetTypeID() {
                    AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
                }
                return
            }
        }
    }

    func shutdown() {
        let toStop = allTiles
        allTiles = []
        tiles = []
        guard !toStop.isEmpty else { return }
        let group = DispatchGroup()
        for t in toStop { t.stopSync(group: group) }
        _ = group.wait(timeout: .now() + 1.0)
    }

    private func hide(activatePrevious: Bool = true) {
        if config.debugLoggingEnabled {
            Log.write("hide(activatePrevious: \(activatePrevious)) isPicking=\(isPicking) prevFrontPID=\(prevFrontPID) front=\(Self.frontDesc())")
        }
        refreshGeneration &+= 1
        let toStop = allTiles
        for t in toStop { t.suppressFrames = true }
        stopActivityTimer()
        let w = window
        let animate = config.animations && w != nil && w!.alphaValue > 0
        visible = false
        if activatePrevious, prevFrontPID != 0,
           let app = NSRunningApplication(processIdentifier: prevFrontPID) {
            if config.debugLoggingEnabled { Log.write("hide: RESTORING previous-front pid=\(prevFrontPID)") }
            app.activate()
        }
        prevFrontPID = 0
        tiles = []
        allTiles = []
        selectedIndex = 0
        lastLetterJump = nil
        searching = false
        searchQuery = ""
        pickBuffer = ""
        search.hide()
        view?.resetMomentaryPeek()
        Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for t in toStop {
                    group.addTask(priority: .utility) { await t.stop() }
                }
            }
        }
        isZoomed = false
        savedFrames = []
        let clearLayers = { [weak self] in
            guard let self else { return }
            if let root = self.window?.contentView?.layer {
                root.sublayers?.forEach { layer in
                    if layer !== self.backgroundLayer { layer.removeFromSuperlayer() }
                }
            }
            // Reset the backdrop so the next show starts opaque again.
            // pick() animates this to 0 and we never animate it back up.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.backgroundLayer?.opacity = 1
            CATransaction.commit()
        }
        if animate, let w {
            w.fadeOutAndDown(distance: 0, duration: animationDuration(Self.baseHideDuration)) { [weak self] in
                guard let self else { return }
                if !self.visible {
                    w.orderOut(nil)
                    clearLayers()
                }
            }
        } else {
            w?.orderOut(nil)
            clearLayers()
        }
    }


    private func pickIndex(_ n: Int) {
        guard tiles.indices.contains(n) else { return }
        selectedIndex = n
        updateSelection()
        pick(via: "pickIndex")
    }

    private func layoutTiles(in bounds: NSRect) {
        let screenSize = activeScreen?.frame.size ?? NSScreen.main?.frame.size ?? bounds.size
        let ar = screenSize.width / max(1, screenSize.height)
        let (rects, cols) = GridLayout.frames(count: tiles.count, bounds: bounds, aspectRatio: ar)
        gridCols = cols
        for (tile, cell) in zip(tiles, rects) {
            let src = tile.window.frame
            let srcAR = src.width / max(1, src.height)
            let cellAR = cell.width / max(1, cell.height)
            let fitted: CGRect
            if srcAR > cellAR {
                let h = cell.width / srcAR
                fitted = CGRect(x: cell.minX, y: cell.midY - h / 2, width: cell.width, height: h)
            } else {
                let w = cell.height * srcAR
                fitted = CGRect(x: cell.midX - w / 2, y: cell.minY, width: w, height: cell.height)
            }
            tile.setFrame(fitted)
        }
    }

    private func updateSelection() {
        for (i, t) in tiles.enumerated() {
            t.highlight = (i == selectedIndex) ? .subtle : .none
        }
    }

    private func move(dx: Int, dy: Int) {
        guard !tiles.isEmpty, !isZoomed else { return }
        let cols = max(1, gridCols)
        let row = selectedIndex / cols
        let col = selectedIndex % cols
        let newCol = max(0, min(cols - 1, col + dx))
        let newRow = max(0, row + dy)
        let candidate = newRow * cols + newCol
        if candidate >= 0 && candidate < tiles.count {
            selectedIndex = candidate
        } else if dy > 0 {
            selectedIndex = tiles.count - 1
        }
        updateSelection()
    }

    private func pick(via: String = "pick") {
        guard tiles.indices.contains(selectedIndex), !isPicking else { return }
        let tile = tiles[selectedIndex]
        let pid = tile.ownerPID
        let windowID = CGWindowID(tile.window.windowID)
        let title = tile.window.title
        let targetSpace = tile.window.spaceID
        prevFrontPID = 0
        prevPickedWindowID = windowID
        isPicking = true

        // A window that isn't currently on screen lives on a hidden Space, so
        // activating it must switch Spaces. Its real frame is off this Space, so
        // the fly-to-source animation can't apply — drop the overlay first, then
        // force-activate. (7.8 adds a proper off-Space animation.)
        let crossSpace = !tile.window.isOnScreen
        if config.debugLoggingEnabled {
            Log.write("pick: via=\(via) wid=\(windowID) pid=\(pid) app=\(tile.window.applicationName) title=\"\(title ?? "")\" space=\(tile.window.spaceID.map(String.init) ?? "-") type=\(tile.window.spaceType.map { "\($0)" } ?? "-") isOnScreen=\(tile.window.isOnScreen) onActiveSpace=\(tile.window.isOnActiveSpace) crossSpace=\(crossSpace) frontBefore=\(Self.frontDesc())")
            // 1C: trust + retained state captured BEFORE any focus mechanism runs.
            let (_, aliveDesc) = Self.axAliveness(registry.peek(for: windowID)?.element)
            Log.write("pick(trust): crossSpace=\(crossSpace) AXTrusted=\(AXIsProcessTrusted()) \(aliveDesc)")
        }
        if crossSpace {
            // Order the panel out without restoring the previous (full-screen)
            // app — prevFrontPID is already 0 and activatePrevious is false, so
            // no previous-front restoration runs — then switch Space + activate.
            let targetDisplay = tile.window.displayUUID
            window?.alphaValue = 0
            hide(activatePrevious: false)
            if config.debugLoggingEnabled {
                Log.write("pick: overlay ordered out (crossSpace); activeSpace(before)=\(tracker.activeSpaceID()) targetSpace=\(targetSpace.map(String.init) ?? "-") targetDisplay=\(targetDisplay ?? "-")")
            }
            activateCrossSpacePick(spaceID: targetSpace, displayUUID: targetDisplay, pid: pid, windowID: windowID)
            isPicking = false
            return
        }

        guard let w = window, config.animations else {
            // Order the panel out BEFORE activating, then activate on the next
            // main-loop tick — ordering it out *after* activation lets the
            // non-activating panel's dismissal hand key back to the previous app.
            window?.alphaValue = 0
            hide(activatePrevious: false)
            if config.debugLoggingEnabled { Log.write("pick(no-anim): overlay ordered out, front=\(Self.frontDesc())") }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.raiseAndActivate(pid: pid, windowID: windowID, title: title, targetSpace: targetSpace)
                self.isPicking = false
            }
            return
        }
        let targetFrame = Self.contentLocalRect(forSourceCGFrame: tile.window.frame, overlayWindow: w)

        suspendFrames()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.highlight = .none
        // Float above all other tiles during the flight regardless of
        // their assigned z-order so the picked tile reads as "the one
        // being activated."
        tile.layer.zPosition = 1_000_000
        // Letter-mode dims non-matching tiles to 0.3 while the user types a
        // prefix. Snap everyone back to full opacity before the dismiss so
        // the fly-home animation matches the click path.
        for t in allTiles { t.layer.opacity = 1.0 }
        CATransaction.commit()
        CATransaction.flush()

        // Every tile flies back to where its window actually lives, so no
        // fades are needed — each one settles onto its own window. Only the
        // backdrop fades out.
        let bg = backgroundLayer
        CATransaction.begin()
        CATransaction.setAnimationDuration(animationDuration(Self.baseDismissDuration))
        CATransaction.setAnimationTimingFunction(Self.smoothEasing)
        // setCompletionBlock fires after the real final frame renders,
        // not just `duration` ms after we kick the animation off, so we
        // don't activate while the slide is still moving.
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            // Hold a beat so the fly-to-window animation reads as "done", then
            // order the overlay out BEFORE activating. Ordering it out *after*
            // activation lets the non-activating panel's dismissal hand key back
            // to the previously-front app (the focus regression). Activate on the
            // next tick, once the panel is gone, so the target wins for good.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.window?.alphaValue = 0
                self.hide(activatePrevious: false)
                if self.config.debugLoggingEnabled { Log.write("pick(anim): overlay ordered out, front=\(Self.frontDesc())") }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.raiseAndActivate(pid: pid, windowID: windowID, title: title, targetSpace: targetSpace)
                    self.isPicking = false
                }
            }
        }
        for (i, t) in tiles.enumerated() {
            let dest = (i == selectedIndex)
                ? targetFrame
                : Self.contentLocalRect(forSourceCGFrame: t.window.frame, overlayWindow: w)
            t.setFrame(dest)
            if i == selectedIndex {
                // Animate a macOS-style window shadow onto the picked tile
                // so the system's real drop shadow (which appears the moment
                // activation runs) blends with what's already painted instead
                // of popping in around the tile's edges.
                t.layer.shadowColor = NSColor.black.cgColor
                t.layer.shadowOpacity = 0.45
                t.layer.shadowRadius = 22
                t.layer.shadowOffset = CGSize(width: 0, height: -10)
            }
        }
        bg?.opacity = 0
        CATransaction.commit()
    }

    /// Aliveness probe for a retained AX element. Returns whether it's alive
    /// plus a description naming the actual AX op and its `AXError` — so debug
    /// logs show *why* an element is considered dead, not a bare boolean
    /// (Phase 1 point 4). Shared by per-tile (1B), pick() (1C), and both focus
    /// paths (1D).
    private static func axAliveness(_ el: AXUIElement?) -> (alive: Bool, desc: String) {
        guard let el else { return (false, "retained=absent") }
        var roleRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? "-"
        return (err == .success, "retained=present aliveOp=AXCopyAttr(kAXRole) err=\(err.rawValue) alive=\(err == .success) role=\(role)")
    }

    /// Focus the picked window, run AFTER the overlay panel is ordered out.
    /// Uses the SLPS front-process primitive (the one that works cross-Space) +
    /// an AX raise — NOT NSRunningApplication.activate(), which no-ops here: with
    /// the non-activating panel, cmdcmd can't cooperatively activate another app,
    /// so the previous app keeps frontmost. Same-Space (on-screen) windows may
    /// fall back to a fresh AX lookup; off-Space windows rely on the retained
    /// element.
    private func raiseAndActivate(pid: pid_t, windowID: CGWindowID, title: String?, targetSpace: CGSSpaceID?) {
        let debug = config.debugLoggingEnabled
        let activeSpaceBefore = tracker.activeSpaceID()
        if debug { Log.write("focus(before): front=\(Self.frontDesc())") }

        // SLPS front-process forcing + makeKeyWindow events (PrivateFocusFallback
        // logs the setFront/post result codes internally under debug).
        let slpsOK = PrivateFocusFallback.raise(pid: pid, windowID: windowID, debug: debug)
        if debug { Log.write("focus: SLPS.raise ran=true result=\(slpsOK) front=\(Self.frontDesc())") }

        // AX raise: prefer the registry's validated retained element (valid even
        // off-Space); a fresh lookup is fine for an on-screen same-Space window.
        // (registry logs hit/miss/invalid.)
        if let retained = registry.retainedElementForRaise(for: windowID, debug: debug) {
            let ok = applyRaise(app: AXUIElementCreateApplication(pid), win: retained)
            if debug { Log.write("focus: retainedRaise ran=true result=\(ok); freshRaise ran=false front=\(Self.frontDesc())") }
        } else {
            let ok = raiseAXWindow(pid: pid, windowID: windowID, title: title)
            if debug { Log.write("focus: retainedRaise ran=false; freshRaise ran=true result=\(ok) front=\(Self.frontDesc())") }
        }

        // Same-Space window-level instrumentation (debug-only, read-only). No
        // retry here — same-Space is reliable and stays unchanged functionally.
        if debug {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pickVerifyDelay) { [weak self] in
                _ = self?.settleOutcome(pid: pid, windowID: windowID, tag: "sameSpace settle", activeSpaceBefore: activeSpaceBefore, targetSpace: targetSpace, debug: true)
            }
        }
    }

    /// Cross-Space pick handler. SLPS front-process + key-window events is the
    /// PRIMARY mechanism — log analysis shows it alone drives the Space switch to
    /// a desktop target, even cold with no retained AX element, and no datapoint
    /// shows retained AX rescuing an SLPS-alone failure. A live retained element,
    /// when present, gets an optional follow-up raise (window-level nicety). A
    /// missing retained handle is NOT fatal (logged `retained-missing-slps-only`);
    /// fresh AX is off-Space-blind so it's used only as a read-only diagnostic,
    /// never relied upon. A single late, frontmost-PID-gated safety-net retry runs
    /// after the transition settles. The unsafe in-process SLS Space switch stays
    /// gated off; switching *into* a native full-screen target is a known
    /// limitation under these constraints, not retried here.
    private func activateCrossSpacePick(spaceID: CGSSpaceID?, displayUUID: String?, pid: pid_t, windowID: CGWindowID) {
        let debug = config.debugLoggingEnabled
        let activeSpaceBefore = tracker.activeSpaceID()
        let trusted = AXIsProcessTrusted()
        let (_, aliveDesc) = Self.axAliveness(registry.peek(for: windowID)?.element)
        if debug {
            Log.write("crossSpace pick: wid=\(windowID) pid=\(pid) AXTrusted=\(trusted) \(aliveDesc) activeSpace(before)=\(activeSpaceBefore) front(before)=\(Self.frontDesc())")
        }

        // Experimental in-process SLS Space switch — gated OFF by default.
        if config.experimentalInProcessSpaceSwitchEnabled, let spaceID {
            let attempted = PrivateSpaceSwitcher.switchTo(spaceID: spaceID, displayUUID: displayUUID, debug: debug)
            if debug { Log.write("SpaceSwitch(experimental): attempted=\(attempted)") }
        }

        // Focus primitive, A/B-switched by crossSpaceTargetActivate (SLPS vs
        // target-app activation), followed by the optional retained-AX correction.
        issueCrossSpaceFocus(pid: pid, windowID: windowID, tag: "crossSpace pick", debug: debug)

        // Window-level instrumentation + the single late safety-net retry,
        // scheduled past the Space-transition settle so it can't interrupt an
        // in-flight switch.
        scheduleCrossSpaceVerify(pid: pid, windowID: windowID, activeSpaceBefore: activeSpaceBefore, targetSpace: spaceID)
    }

    /// The cross-Space focus primitive, A/B-switched by `crossSpaceTargetActivate`.
    /// flag OFF → SLPS front-process (the current/default path). flag ON →
    /// experiment #5's cooperative-activation handoff: self-activate cmdcmd (to
    /// gain activation provenance), then `target.activate()`, then (shared) the
    /// retained-AX raise; SLPS fallback if the target hand-off is refused so cmdcmd
    /// isn't left frontmost. The self-activation is the deliberate, gated exception
    /// to "no NSApp.activate" — it runs at the pick hand-off (overlay already
    /// hidden), not for overlay presentation. Used by both the initial pick and the
    /// late retry so the A/B stays consistent; a missing retained handle is not
    /// fatal (read-only fresh-AX probe under debug).
    private func issueCrossSpaceFocus(pid: pid_t, windowID: CGWindowID, tag: String, debug: Bool) {
        if config.crossSpaceTargetActivateEnabled {
            // #5: a never-active accessory's bare target.activate() is refused by
            // Sonoma (result=false, front unchanged). Self-activate cmdcmd FIRST to
            // gain provenance, THEN hand off to the target. If still refused, fall
            // back to SLPS so we don't strand cmdcmd frontmost.
            NSApp.activate()
            let app = NSRunningApplication(processIdentifier: pid)
            let activated = app?.activate() ?? false
            if debug { Log.write("\(tag): selfActivate→targetActivate cmdcmdActive=\(NSApp.isActive) targetActivate ran=\(app != nil) result=\(activated) front=\(Self.frontDesc())") }
            if !activated {
                let slpsOK = PrivateFocusFallback.raise(pid: pid, windowID: windowID, debug: debug)
                if debug { Log.write("\(tag): targetActivate refused → SLPS fallback result=\(slpsOK) front=\(Self.frontDesc())") }
            }
        } else {
            let slpsOK = PrivateFocusFallback.raise(pid: pid, windowID: windowID, debug: debug)
            if debug { Log.write("\(tag): SLPS.raise ran=true result=\(slpsOK)") }
        }
        if let retained = registry.retainedElementForRaise(for: windowID, debug: debug) {
            let ok = applyRaise(app: AXUIElementCreateApplication(pid), win: retained)
            if debug { Log.write("\(tag): retainedRaise ran=true result=\(ok)") }
        } else if debug {
            // Registry miss/invalid (logged by retainedElementForRaise). A0 keeps the
            // current cross-Space miss behavior: no functional fresh-AX fallback,
            // just the read-only off-Space resolvability probe.
            let mode = config.crossSpaceTargetActivateEnabled ? "activate" : "slps"
            Log.write("\(tag): retained-missing-\(mode)-only")
            Log.write("\(tag): freshAX off-Space diagnostic (read-only, not relied upon) resolvable=\(Self.freshAXResolvable(pid: pid, windowID: windowID))")
        }
    }

    /// Delay before the post-pick verify/retry runs. Deliberately past the
    /// macOS Space-transition animation: log analysis shows desktop switches
    /// register frontmost within ~50ms, but re-issuing SLPS mid-animation could
    /// disrupt an in-flight switch, so the one retry waits until it has settled.
    private static let pickVerifyDelay: TimeInterval = 0.6
    /// Early success-latch sample. If the pick is already frontmost+visible here,
    /// it succeeded and the late retry is suppressed — so a manual switch-away
    /// later in the settle window is never overridden by a stale reassert.
    private static let pickEarlySampleDelay: TimeInterval = 0.4

    /// Settle-time classification of a pick. `targetWindowIsOnScreenAfter` is the
    /// strongest success signal; `activeSpaceChanged` is weaker (the selected
    /// window may not be the visible one) — enough to suppress the retry, but
    /// labelled distinctly. The earlier frontmost-PID-only check was too weak:
    /// SLPS can make the target process frontmost while the active Space never
    /// transitions, leaving the user stuck behind full-screen.
    enum PickOutcome: String {
        case successSpaceMatch = "success-space-match"        // frontmost && activeSpaceAfter == targetSpace
        case frontmostWrongSpace = "frontmost-wrong-space"    // frontmost, but active Space != targetSpace (or unknown)
        case wrongFrontmost = "wrong-frontmost"               // front PID is not the target

        /// Functional verdict: only an active-Space match counts as success and
        /// suppresses the retry. `kCGWindowIsOnscreen` is NOT used here — it
        /// false-negatives same-Space picks (the window is the focused/main one
        /// yet reports off-screen), so it's advisory logging only.
        var suppressesRetry: Bool { self == .successSpaceMatch }
    }

    /// Compute the pick outcome and (when `debug`) log the full picture, incl.
    /// window-level fields and the noisy `activeSpace==targetSpace` advisory.
    /// Read-only.
    private func settleOutcome(pid: pid_t, windowID: CGWindowID, tag: String, activeSpaceBefore: CGSSpaceID, targetSpace: CGSSpaceID?, debug: Bool) -> PickOutcome {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let frontIsTarget = (frontPID == pid)
        let activeSpaceAfter = tracker.activeSpaceID()
        let activeSpaceChanged = activeSpaceAfter != activeSpaceBefore
        let (onScreenAfter, spaceAfter) = Self.windowState(windowID, tracker: tracker)
        // Functional verdict = frontmost AND the active Space is now the target
        // window's Space. on-screen is advisory only (see PickOutcome). Depends on
        // targetSpace fidelity; a mislabelled targetSpace can read a real success
        // as frontmost-wrong-space.
        let spaceMatch = targetSpace.map { $0 == activeSpaceAfter } ?? false
        let outcome: PickOutcome
        if !frontIsTarget { outcome = .wrongFrontmost }
        else if spaceMatch { outcome = .successSpaceMatch }
        else { outcome = .frontmostWrongSpace }
        if debug {
            let app = AXUIElementCreateApplication(pid)
            let focusedWID = Self.axWindowID(of: app, attribute: kAXFocusedWindowAttribute)
            let mainWID = Self.axWindowID(of: app, attribute: kAXMainWindowAttribute)
            var targetIsMain = "?"
            if let retained = registry.peek(for: windowID)?.element {
                var mainRef: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(retained, kAXMainAttribute as CFString, &mainRef)
                targetIsMain = err == .success ? "\((mainRef as? Bool) ?? false)" : "err=\(err.rawValue)"
            }
            Log.write("\(tag): targetPID=\(pid) targetWID=\(windowID) frontPID=\(frontPID) frontIsTarget=\(frontIsTarget) targetSpace=\(targetSpace.map(String.init) ?? "-") activeSpaceBefore=\(activeSpaceBefore) activeSpaceAfter=\(activeSpaceAfter) activeSpaceEqTargetSpace=\(spaceMatch) activeSpaceChanged=\(activeSpaceChanged) targetWindowIsOnScreenAfter(advisory)=\(onScreenAfter) targetWindowSpaceAfter(advisory)=\(spaceAfter.map(String.init) ?? "-") appFocusedWID=\(focusedWID.map(String.init) ?? "-") appMainWID=\(mainWID.map(String.init) ?? "-") targetWindowIsMain=\(targetIsMain) focusOutcome=\(outcome.rawValue)")
        }
        return outcome
    }

    /// Re-enumerate a specific window at settle time: its current on-screen flag
    /// and Space. `CGWindowListCreateDescriptionFromArray` returns a description
    /// even for off-screen windows; `kCGWindowIsOnscreen` is absent (→ false)
    /// when the window isn't on the active Space. The Space is advisory (the
    /// per-window mapping is unreliable). Read-only.
    private static func windowState(_ wid: CGWindowID, tracker: SpaceTracker) -> (onScreen: Bool, space: CGSSpaceID?) {
        let arr = [NSNumber(value: wid)] as CFArray
        let infos = (CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]]) ?? []
        let onScreen = (infos.first?[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let space = tracker.spaceMap(for: [wid])[wid]
        return (onScreen, space)
    }

    /// Resolve the `CGWindowID` behind an app-level AX window attribute
    /// (`kAXFocusedWindowAttribute` / `kAXMainWindowAttribute`). Read-only.
    private static func axWindowID(of app: AXUIElement, attribute: String) -> CGWindowID? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let win = value as! AXUIElement
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(win, &wid) == .success ? wid : nil
    }

    /// READ-ONLY diagnostic: would a fresh AX query resolve `windowID` right now?
    /// Mirrors `raiseAXWindow`'s matching but performs NO raise, so it's safe to
    /// run under debug without changing behavior. Off-Space this returns false
    /// (AX is blind to off-Space windows) — exactly the fact we want to record.
    private static func freshAXResolvable(pid: pid_t, windowID: CGWindowID) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }
        for win in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(win, &wid) == .success, wid == windowID { return true }
        }
        return false
    }

    /// Cross-Space verify with an EARLY SUCCESS LATCH, then at most one late
    /// retry (functional — runs regardless of debug; only detail logging is
    /// debug-gated).
    ///
    /// At `pickEarlySampleDelay` (~0.4s): if the pick is already frontmost+visible
    /// (`suppressesRetry`), it has succeeded — latch and STOP. This is what keeps
    /// a manual switch-away later in the settle window from being overridden by a
    /// stale reassert. Only if the early sample was NOT successful do we schedule
    /// the late check at `pickVerifyDelay` (~0.6s, past the transition animation),
    /// which re-evaluates and, only if STILL not successful, re-issues SLPS once
    /// and raises a live retained element once. No eager retries; no second retry.
    private func scheduleCrossSpaceVerify(pid: pid_t, windowID: CGWindowID, activeSpaceBefore: CGSSpaceID, targetSpace: CGSSpaceID?) {
        let debug = config.debugLoggingEnabled
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pickEarlySampleDelay) { [weak self] in
            guard let self else { return }
            let early = self.settleOutcome(pid: pid, windowID: windowID, tag: "crossSpace early", activeSpaceBefore: activeSpaceBefore, targetSpace: targetSpace, debug: debug)
            if early.suppressesRetry {
                if debug { Log.write("crossSpace verify: early focusOutcome=\(early.rawValue) → latched success, late retry suppressed") }
                return
            }
            // Not yet successful — allow the single late retry, scheduled so it
            // lands at ~pickVerifyDelay from the original pick.
            let remaining = max(0, Self.pickVerifyDelay - Self.pickEarlySampleDelay)
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self else { return }
                let late = self.settleOutcome(pid: pid, windowID: windowID, tag: "crossSpace settle", activeSpaceBefore: activeSpaceBefore, targetSpace: targetSpace, debug: debug)
                guard !late.suppressesRetry else {
                    if debug { Log.write("crossSpace verify: late focusOutcome=\(late.rawValue) → succeeded by settle, no retry") }
                    return
                }
                if debug { Log.write("crossSpace verify: late focusOutcome=\(late.rawValue) → single late retry") }
                self.issueCrossSpaceFocus(pid: pid, windowID: windowID, tag: "crossSpace retry", debug: debug)
                if debug {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self else { return }
                        _ = self.settleOutcome(pid: pid, windowID: windowID, tag: "crossSpace verify(post-retry)", activeSpaceBefore: activeSpaceBefore, targetSpace: targetSpace, debug: true)
                    }
                }
            }
        }
    }

    private static func frontDesc() -> String {
        let f = NSWorkspace.shared.frontmostApplication
        return "\(f?.localizedName ?? "?")#\(f?.processIdentifier ?? -1)"
    }

    /// Raise + focus a specific window by CGWindowID (falling back to title).
    /// Returns whether the focus + raise actions succeeded; logs each AX step.
    @discardableResult
    private func raiseAXWindow(pid: pid_t, windowID: CGWindowID, title: String?) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let listErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard listErr == .success, let windows = windowsRef as? [AXUIElement] else {
            if config.debugLoggingEnabled { Log.write("raiseAX: pid=\(pid) kAXWindows failed err=\(listErr.rawValue)") }
            return false
        }
        for win in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(win, &wid) == .success, wid == windowID {
                let ok = applyRaise(app: app, win: win)
                if config.debugLoggingEnabled { Log.write("raiseAX: pid=\(pid) wid=\(windowID) match=byID axWindows=\(windows.count) raised=\(ok)") }
                return ok
            }
        }
        if let title, !title.isEmpty {
            for win in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                if let t = titleRef as? String, t == title {
                    let ok = applyRaise(app: app, win: win)
                    if config.debugLoggingEnabled { Log.write("raiseAX: pid=\(pid) wid=\(windowID) match=byTitle axWindows=\(windows.count) raised=\(ok)") }
                    return ok
                }
            }
        }
        if config.debugLoggingEnabled { Log.write("raiseAX: pid=\(pid) wid=\(windowID) NO MATCH axWindows=\(windows.count)") }
        return false
    }

    private func applyRaise(app: AXUIElement, win: AXUIElement) -> Bool {
        let eFocus = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, win)
        let eMain = AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        let eRaise = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        if config.debugLoggingEnabled, eFocus != .success || eMain != .success || eRaise != .success {
            Log.write("raiseAX: setFocused=\(eFocus.rawValue) setMain=\(eMain.rawValue) raiseAction=\(eRaise.rawValue)")
        }
        return eFocus == .success && eRaise == .success
    }

    private func mouseDownAt(_ point: NSPoint) {
        if isZoomed {
            dragState = nil
            pick(via: "click")
            return
        }
        guard let i = tiles.firstIndex(where: { $0.layer.frame.contains(point) }) else {
            dragState = nil
            return
        }
        let tile = tiles[i]
        dragState = DragState(
            index: i,
            offset: CGPoint(x: tile.layer.frame.origin.x - point.x,
                            y: tile.layer.frame.origin.y - point.y),
            startPoint: point,
            moved: false
        )
        tile.layer.zPosition = 1
        selectedIndex = i
        updateSelection()
    }

    private func mouseDraggedAt(_ point: NSPoint) {
        guard var state = dragState, tiles.indices.contains(state.index) else { return }
        if !state.moved {
            let dist = hypot(point.x - state.startPoint.x, point.y - state.startPoint.y)
            if dist > 5 { state.moved = true }
        }
        if state.moved {
            let tile = tiles[state.index]
            let f = tile.layer.frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tile.setFrame(CGRect(
                x: point.x + state.offset.x,
                y: point.y + state.offset.y,
                width: f.width,
                height: f.height
            ))
            CATransaction.commit()
        }
        dragState = state
    }

    private func mouseUpAt(_ point: NSPoint) {
        guard let state = dragState, tiles.indices.contains(state.index) else {
            dragState = nil
            return
        }
        let tile = tiles[state.index]
        tile.layer.zPosition = 0
        if state.moved {
            if let target = tiles.firstIndex(where: { $0 !== tile && $0.layer.frame.contains(point) }) {
                let other = tiles[target]
                tiles.swapAt(state.index, target)
                if let ai = allTiles.firstIndex(where: { $0 === tile }),
                   let bi = allTiles.firstIndex(where: { $0 === other }) {
                    allTiles.swapAt(ai, bi)
                }
                savedOrder = allTiles.map { CGWindowID($0.window.windowID) }
                selectedIndex = target
                renumberTiles()
            }
            layoutTilesAnimated()
            updateSelection()
        } else {
            pick(via: "click")
        }
        dragState = nil
    }

    private func swapSelected(dx: Int, dy: Int) {
        guard !tiles.isEmpty, !isZoomed else { return }
        let cols = max(1, gridCols)
        let row = selectedIndex / cols
        let col = selectedIndex % cols
        let newCol = col + dx
        let newRow = row + dy
        guard newCol >= 0, newCol < cols, newRow >= 0 else { return }
        let target = newRow * cols + newCol
        guard target >= 0, target < tiles.count, target != selectedIndex else { return }
        let a = tiles[selectedIndex]
        let b = tiles[target]
        tiles.swapAt(selectedIndex, target)
        if let ai = allTiles.firstIndex(where: { $0 === a }),
           let bi = allTiles.firstIndex(where: { $0 === b }) {
            allTiles.swapAt(ai, bi)
        }
        savedOrder = allTiles.map { CGWindowID($0.window.windowID) }
        selectedIndex = target
        renumberTiles()
        layoutTilesAnimated()
        updateSelection()
    }

    private func renumberTiles() {
        applyTileLabels()
    }

    private func layoutTilesAnimated() {
        let bounds = window?.contentView?.bounds ?? .zero
        let duration = animationDuration(Self.baseLayoutDuration)
        suspendFrames()
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layoutTiles(in: bounds)
        CATransaction.commit()
        resumeFrames(after: duration)
    }

    private func beginZoom() {
        guard !isZoomed, tiles.indices.contains(selectedIndex) else { return }
        let bounds = window?.contentView?.bounds ?? .zero
        let pad: CGFloat = 4
        let avail = bounds.insetBy(dx: pad, dy: pad)
        let src = tiles[selectedIndex].window.frame
        let srcAR = src.width / max(1, src.height)
        let availAR = avail.width / max(1, avail.height)
        let target: CGRect
        if srcAR > availAR {
            let h = avail.width / srcAR
            target = CGRect(x: avail.minX, y: avail.midY - h / 2, width: avail.width, height: h)
        } else {
            let w = avail.height * srcAR
            target = CGRect(x: avail.midX - w / 2, y: avail.minY, width: w, height: avail.height)
        }
        savedFrames = tiles.map { $0.layer.frame }
        isZoomed = true
        let duration = animationDuration(Self.basePeekDuration)
        suspendFrames()
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for (i, t) in tiles.enumerated() {
            if i == selectedIndex {
                t.layer.zPosition = 1
                t.setFrame(target)
                // Fade the accent border + blue glow during the zoom: at full
                // size they dominate the screen and read as a flash of color.
                t.layer.borderWidth = 0
                t.layer.shadowOpacity = 0
            } else {
                t.layer.opacity = 0
            }
        }
        CATransaction.commit()
        resumeFrames(after: duration)
    }

    private func endZoom() {
        guard isZoomed else { return }
        isZoomed = false
        let duration = animationDuration(Self.basePeekDuration)
        suspendFrames()
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for (i, t) in tiles.enumerated() {
            if i < savedFrames.count { t.setFrame(savedFrames[i]) }
            t.layer.zPosition = 0
            t.layer.opacity = 1
            if i == selectedIndex, t.highlight == .subtle {
                t.layer.borderWidth = 3
                t.layer.shadowOpacity = 0.6
            }
        }
        CATransaction.commit()
        resumeFrames(after: duration)
        savedFrames = []
    }

    private static let systemOwners: Set<String> = [
        "Window Server", "Dock", "WindowManager", "Control Center",
        "Spotlight", "NotificationCenter", "SystemUIServer",
        "TextInputMenuAgent", "Wallpaper",
    ]

    private static func isCapturable(_ w: WindowInfo) -> Bool {
        if w.processID == getpid() { return false }
        if w.applicationName.isEmpty { return false }
        if systemOwners.contains(w.applicationName) { return false }
        if w.frame.width < 200 || w.frame.height < 200 { return false }
        if !w.isOnScreen && w.layer != 0 { return false }
        // CGWindowListCopyWindowInfo returns every layer including menus,
        // tooltips, and floating panels. Only the normal window layer (0) is
        // user-facing app content.
        if w.layer != 0 { return false }
        return true
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        let w = OverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // .screenSaver keeps the panel above other content; the real lever for
        // appearing over a full-screen Space is the nonactivating panel + not
        // activating the app (see presentOverlayWindow).
        w.level = .screenSaver
        w.isOpaque = false
        // We drive show/hide explicitly; don't let the panel vanish when the
        // app isn't the active app (it never becomes active in this model).
        w.hidesOnDeactivate = false
        w.worksWhenModal = true
        // Backdrop lives on a dedicated CALayer (see backgroundLayer below)
        // so dismiss can fade it independently of the selected tile.
        w.backgroundColor = .clear
        // canJoinAllSpaces + fullScreenAuxiliary let the panel render over a
        // full-screen Space; stationary keeps it put across Space transitions;
        // ignoresCycle hides it from Cmd-` window cycling.
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = OverlayView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear

        let bg = CALayer()
        bg.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        bg.frame = v.bounds
        bg.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(bg)
        backgroundLayer = bg
        v.keymap = Keymap(overrides: config.bindings)
        v.onAction = { [weak self] action in self?.dispatch(action) }
        v.onSpaceDown = { [weak self] in self?.beginZoom() }
        v.onSpaceUp = { [weak self] in self?.endZoom() }
        v.onMouseDown = { [weak self] p in self?.mouseDownAt(p) }
        v.onMouseDragged = { [weak self] p in self?.mouseDraggedAt(p) }
        v.onMouseUp = { [weak self] p in self?.mouseUpAt(p) }
        v.onLetter = { [weak self] letter in self?.selectApp(startingWith: letter) }
        v.onTypeahead = { [weak self] ch in self?.appendPickBuffer(ch) }
        v.onTypeaheadBackspace = { [weak self] in self?.popPickBuffer() }
        v.letterPickActive = config.tilePicksMode == .letters
        w.contentView = v
        view = v
        return w
    }

    private func appendPickBuffer(_ ch: String) {
        guard config.tilePicksMode == .letters else { return }
        let candidate = pickBuffer + ch
        let matches = tiles.filter { tile in
            guard let label = tileLabels[CGWindowID(tile.window.windowID)] else { return false }
            return label.hasPrefix(candidate)
        }
        guard !matches.isEmpty else { return }
        pickBuffer = candidate
        if matches.count == 1, matches[0].layer.isHidden == false,
           let label = tileLabels[CGWindowID(matches[0].window.windowID)],
           label == candidate {
            if let idx = tiles.firstIndex(where: { $0 === matches[0] }) {
                selectedIndex = idx
                updateSelection()
                pick(via: "letter")
                return
            }
        }
        applyTileLabels()
    }

    private func popPickBuffer() {
        guard config.tilePicksMode == .letters else { return }
        guard !pickBuffer.isEmpty else { return }
        pickBuffer.removeLast()
        applyTileLabels()
    }
}
