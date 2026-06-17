import AppKit

/// App-lifetime store of retained `AXUIElement`s keyed by `CGWindowID`. The
/// proven cross-Space focus path is `SLPS.raise` → retained `applyRaise`; a
/// retained handle stays valid after its window moves off-Space (a fresh AX query
/// can't see off-Space windows), which is what makes warm cross-Space picks work.
/// Maximising how often a valid handle is present at pick time is this registry's
/// whole job.
///
/// Fed by population sources — show-time capture (`source: .showCapture`), launch
/// backfill across regular running apps (`.launchBackfill`), `NSWorkspace`
/// activation-driven `kAXWindows` scans (`.activationScan`), and the Phase C
/// per-app AXObserver triggers (`.windowCreated` / `.focusedWindowChanged` /
/// `.observerInstallFocused` / `.workspaceActivatedFocused`; see
/// `WindowAXObservers`). Still no hard-fail, no cold-unresolved UX. The functional
/// raise gate remains the OLD aliveness
/// check (`kAXRole` succeeds); the stricter identity checks (`_AXUIElementGetWindow
/// == WID`, PID match, app-running) stay ADVISORY-only — logged, non-blocking,
/// non-evicting — because an off-Space retained element legitimately fails
/// `_AXUIElementGetWindow` yet still raises. A1 decides separately whether strict
/// becomes blocking; not in this patch.
///
/// Thread-safety: the map is guarded by `lock`, but AX IPC is NEVER performed
/// while holding it. Use-time lookups copy the entry out under the lock; the
/// alive check + advisory strict checks run outside the lock; a dead entry
/// (`kAXRole` fails) is dropped by re-acquiring only if it still matches. Stored
/// from the off-main show path; read on the main thread at pick.
final class WindowAXRegistry {
    /// How an entry entered the registry (logged; informs later miss bucketing).
    /// The four Phase C triggers are kept distinct so a pick-time
    /// `registry.hit … source=<trigger>` reveals which capture path won.
    enum Source: String {
        case showCapture
        case launchBackfill
        case activationScan
        // Phase C — per-app AXObserver capture triggers (see WindowAXObservers).
        case windowCreated             // kAXWindowCreatedNotification
        case focusedWindowChanged      // kAXFocusedWindowChangedNotification
        case observerInstallFocused    // kAXFocusedWindow probe at observer install
        case workspaceActivatedFocused // kAXFocusedWindow probe on app activation
    }

    struct Entry {
        let element: AXUIElement
        let pid: pid_t
        let bundleID: String?
        let title: String?
        let lastSeen: CFAbsoluteTime
        let source: Source
    }

    private let lock = NSLock()
    private var entries: [CGWindowID: Entry] = [:]
    private var hits = 0
    private var misses = 0

    /// Reads current debug state per-call (the config flag can change at runtime).
    private let debugProvider: () -> Bool
    private var debug: Bool { debugProvider() }
    private var activationObserver: NSObjectProtocol?

    init(debug: @escaping () -> Bool) {
        self.debugProvider = debug
    }

    deinit {
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    /// Current entry count (lock-guarded snapshot).
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Bump + snapshot the cumulative hit/miss counters (lock-guarded).
    private func bump(hit: Bool) -> (hits: Int, misses: Int) {
        lock.lock(); defer { lock.unlock() }
        if hit { hits += 1 } else { misses += 1 }
        return (hits, misses)
    }

    /// Retain `element` for `wid`, overwriting any prior entry. Logs `registry.store`.
    func store(element: AXUIElement, wid: CGWindowID, pid: pid_t, bundleID: String?, title: String?, source: Source, debug: Bool) {
        let entry = Entry(element: element, pid: pid, bundleID: bundleID, title: title,
                          lastSeen: CFAbsoluteTimeGetCurrent(), source: source)
        lock.lock()
        entries[wid] = entry
        let size = entries.count
        lock.unlock()
        if debug {
            Log.write("registry.store wid=\(wid) pid=\(pid) source=\(source.rawValue) title=\"\(title ?? "")\" size=\(size)")
        }
    }

    /// Functional lookup for the raise path. Returns the retained element when it
    /// passes the OLD aliveness check (`kAXRole` succeeds) — preserving the proven
    /// foo.2/3/4 behavior. The stricter identity checks (`_AXUIElementGetWindow`
    /// == expected WID, AX PID match, app-running) are run and LOGGED as ADVISORY
    /// in A0 (`registry.validate(advisory)`) but do NOT gate the raise and do NOT
    /// cause eviction — an off-Space retained element legitimately fails
    /// `_AXUIElementGetWindow` yet still raises. Eviction happens only on the old
    /// dead-entry condition (`kAXRole` fails). A1 decides, from these advisory
    /// logs, whether the strict checks can safely become blocking.
    func retainedElementForRaise(for wid: CGWindowID, debug: Bool) -> AXUIElement? {
        lock.lock()
        let entry = entries[wid]
        lock.unlock()
        guard let entry else {
            if debug { let (h, m) = bump(hit: false); Log.write("registry.miss wid=\(wid) hits=\(h) misses=\(m)") }
            return nil
        }
        // OLD aliveness check — the functional gate (runs regardless of debug).
        var roleRef: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(entry.element, kAXRoleAttribute as CFString, &roleRef)
        let alive = (roleErr == .success)
        // ADVISORY strict checks — logged only; never gate or evict in A0.
        if debug {
            var widOut: CGWindowID = 0
            let g = _AXUIElementGetWindow(entry.element, &widOut)
            var axPID: pid_t = 0
            let p = AXUIElementGetPid(entry.element, &axPID)
            let appRunning = NSRunningApplication(processIdentifier: entry.pid) != nil
            Log.write("registry.validate(advisory) wid=\(wid) roleErr=\(roleErr.rawValue) alive=\(alive) getWindowErr=\(g.rawValue) getWindowWID=\(widOut) widMatch=\(g == .success && widOut == wid) axPidErr=\(p.rawValue) axPID=\(axPID) pidMatch=\(axPID == entry.pid) appRunning=\(appRunning)")
        }
        guard alive else {
            // The ONLY eviction condition in A0: old-equivalent dead entry.
            if debug { let (h, m) = bump(hit: false); Log.write("registry.invalid wid=\(wid) reason=role-err=\(roleErr.rawValue) (dead → evict) hits=\(h) misses=\(m)") }
            lock.lock()
            if let cur = entries[wid], cur.lastSeen == entry.lastSeen {
                entries.removeValue(forKey: wid)
            }
            lock.unlock()
            return nil
        }
        if debug { let (h, m) = bump(hit: true); Log.write("registry.hit wid=\(wid) pid=\(entry.pid) source=\(entry.source.rawValue) hits=\(h) misses=\(m)") }
        return entry.element
    }

    /// Non-destructive snapshot for diagnostics/logging only — no validation, no
    /// eviction, no hit/miss accounting. AX IPC on the returned element (if any)
    /// is the caller's choice and runs outside this registry's lock.
    func peek(for wid: CGWindowID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[wid]
    }

    // MARK: - Phase B population (launch backfill + activation-driven scans)

    /// Begin autonomous population. Call once at startup (after Accessibility is
    /// granted). Launch backfill runs off-main; each `NSWorkspace` app activation
    /// schedules an off-main `kAXWindows` scan of that app's windows. NOT an
    /// AXObserver — this is a workspace-notification windows-list scan; the per-app
    /// AX `kAXWindowCreated` / focused-window observers live in `WindowAXObservers`
    /// (Phase C) and feed this same registry under their own sources.
    func startPopulation() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.backfillAll() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Scan off-main so activation handling stays snappy; store is lock-safe.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.scanApp(app, source: .activationScan)
            }
        }
    }

    /// One-shot launch backfill: scan `kAXWindows` of every regular running app
    /// and retain what resolves. Off-Space-blind (only currently-resolvable
    /// windows), which is expected — it seeds coverage for apps seen at launch.
    private func backfillAll() {
        guard AXIsProcessTrusted() else {
            if debug { Log.write("registry.backfill skipped — AXIsProcessTrusted()=false") }
            return
        }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var stored = 0
        for app in apps { stored += scanApp(app, source: .launchBackfill) }
        if debug { Log.write("registry.backfill apps=\(apps.count) stored=\(stored) size=\(count)") }
    }

    /// Scan one app's `kAXWindows`, retaining each window that resolves to a
    /// `CGWindowID`. Skips cmdcmd itself. Returns the count stored. Logs
    /// `registry.scan` (per-app) and `registry.store` (per window).
    @discardableResult
    private func scanApp(_ app: NSRunningApplication, source: Source) -> Int {
        let pid = app.processIdentifier
        guard pid != getpid() else { return 0 }
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return 0 }
        let bundleID = app.bundleIdentifier
        let d = debug
        var stored = 0
        for axWin in axWindows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(axWin, &wid) == .success, wid != 0 else { continue }
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef)
            store(element: axWin, wid: wid, pid: pid, bundleID: bundleID, title: titleRef as? String, source: source, debug: d)
            stored += 1
        }
        if d { Log.write("registry.scan source=\(source.rawValue) pid=\(pid) app=\(app.localizedName ?? "?") windows=\(axWindows.count) stored=\(stored) size=\(count)") }
        return stored
    }

}
