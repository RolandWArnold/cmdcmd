import AppKit

/// Phase C: per-app Accessibility observers that retain an `AXUIElement` for a
/// window at *creation / focus* time — before the overlay is ever shown — so the
/// `WindowAXRegistry` already holds a raisable handle when a cold off-Space /
/// full-screen window is picked. This closes the Phase B gap where an app never
/// exposes such a window through `kAXWindows` (so launch backfill / activation
/// scan are blind to it), yet `kAXFocusedWindow` or a window-created notification
/// can still hand us a live element.
///
/// Four capture triggers, each stored with its OWN `WindowAXRegistry.Source` so a
/// pick-time `registry.hit … source=<trigger>` (and the per-capture
/// `registry.store … source=<trigger>`) reveals which path won — the decisive
/// Phase C measurement:
///   - `.windowCreated`             — `kAXWindowCreatedNotification`
///   - `.focusedWindowChanged`      — `kAXFocusedWindowChangedNotification`
///   - `.observerInstallFocused`    — `kAXFocusedWindow` probe at observer install
///   - `.workspaceActivatedFocused` — `kAXFocusedWindow` probe on app activation
///
/// The two focused-window PROBES log the decisive comparison directly
/// (`kAXWindowsCount=0 focusedPresent=1 result=ok` is exactly the cold full-screen
/// win we're hunting: focused-window resolves what the windows-list can't see). If
/// NONE of these triggers can resolve the residual "full-screen window that
/// existed before launch and was never touched this session" class, that class is
/// Phase D (best-effort visible-miss UX), NOT more registry plumbing.
///
/// Scope guards (per the Phase C brief): does NOT touch the focus / raise path,
/// adds no hard-fail and no cold-unresolved UX.
///
/// Threading: observer create + run-loop-source attach + the `[pid: observer]` map
/// and `installing` guard are MAIN-confined. ALL AX IPC (add-notification,
/// `kAXFocusedWindow` / `kAXWindows` / title reads, `_AXUIElementGetWindow`) runs
/// off-main on `axQueue`, with a bounded `AXUIElementSetMessagingTimeout` set on
/// every app and window element first so a hung app can't wedge a resolution.
final class WindowAXObservers {
    private let registry: WindowAXRegistry
    private let debugProvider: () -> Bool
    private var debug: Bool { debugProvider() }

    /// Main-confined: live per-app observers + an in-flight-install guard (an
    /// install hops main → axQueue → main, so a racing launch/start could
    /// otherwise double-install before the first lands in `observers`).
    private var observers: [pid_t: AXObserver] = [:]
    private var installing: Set<pid_t> = []
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?

    /// Off-main AX IPC. Concurrent so a retry chain's bounded waits on one app
    /// never head-of-line block another app's resolution.
    private let axQueue = DispatchQueue(label: "cmdcmd.axobservers", qos: .utility, attributes: .concurrent)

    /// Per-message AX timeout (seconds). Healthy apps answer in well under this;
    /// it only bounds a hung app so a retry chain can't wedge `axQueue`.
    private static let messagingTimeout: Float = 0.25
    /// Window-created / focus-changed fire at a transition where the WindowServer
    /// ID can briefly lag the AX element — bounded recapture covers that.
    private static let maxResolveAttempts = 5
    private static let resolveRetryDelay: DispatchTimeInterval = .milliseconds(50)

    init(registry: WindowAXRegistry, debug: @escaping () -> Bool) {
        self.registry = registry
        self.debugProvider = debug
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for o in [launchObserver, terminateObserver, activateObserver] where o != nil {
            nc.removeObserver(o!)
        }
    }

    // MARK: - Lifecycle (main thread)

    /// Install observers for all current regular apps and subscribe to
    /// launch / terminate / activate. MUST be called on the main thread (run-loop
    /// sources attach to the main run loop). No-op if Accessibility isn't trusted.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard AXIsProcessTrusted() else {
            if debug { Log.write("registry.observer.start skipped — AXIsProcessTrusted()=false") }
            return
        }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in apps { installObserver(for: app) }

        let nc = NSWorkspace.shared.notificationCenter
        launchObserver = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.installObserver(for: app)
        }
        terminateObserver = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.removeObserver(for: app.processIdentifier, reason: "terminate")
        }
        // workspaceActivatedFocused: probe the activated app's focused window. This
        // is independent of the registry's own activation `kAXWindows` scan
        // (`.activationScan`) — same event, different mechanism (focused-window vs
        // windows-list), tracked under a distinct source so we can tell them apart.
        activateObserver = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            guard pid != getpid() else { return }
            let bundleID = app.bundleIdentifier, name = app.localizedName
            self.axQueue.async { [weak self] in
                self?.focusedProbe(pid: pid, bundleID: bundleID, appName: name, trigger: .workspaceActivatedFocused)
            }
        }
        if debug { Log.write("registry.observer.start installed=\(observers.count) candidateApps=\(apps.count)") }
    }

    /// Tear down one app's observer (main thread).
    private func removeObserver(for pid: pid_t, reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        installing.remove(pid)
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        if debug { Log.write("registry.observer.remove pid=\(pid) reason=\(reason)") }
    }

    // MARK: - Install (main → axQueue → main)

    private func installObserver(for app: NSRunningApplication) {
        dispatchPrecondition(condition: .onQueue(.main))
        let pid = app.processIdentifier
        guard pid != getpid(), app.activationPolicy == .regular else { return }
        guard observers[pid] == nil, !installing.contains(pid) else { return }
        installing.insert(pid)
        let bundleID = app.bundleIdentifier, name = app.localizedName
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        axQueue.async { [weak self] in
            guard let self else { return }
            let appEl = AXUIElementCreateApplication(pid)
            // Timeout guard BEFORE any messaging to this app element.
            AXUIElementSetMessagingTimeout(appEl, Self.messagingTimeout)

            var obs: AXObserver?
            let createErr = AXObserverCreate(pid, axObserverCallback, &obs)
            guard createErr == .success, let obs else {
                if self.debug { Log.write("registry.observer.install pid=\(pid) app=\(name ?? "?") result=fail axCreateErr=\(createErr.rawValue)") }
                DispatchQueue.main.async { [weak self] in self?.installing.remove(pid) }
                return
            }
            let createdErr = AXObserverAddNotification(obs, appEl, kAXWindowCreatedNotification as CFString, refcon)
            let focusedErr = AXObserverAddNotification(obs, appEl, kAXFocusedWindowChangedNotification as CFString, refcon)
            if self.debug {
                Log.write("registry.observer.install pid=\(pid) app=\(name ?? "?") result=ok createdAddErr=\(createdErr.rawValue) focusedAddErr=\(focusedErr.rawValue)")
            }
            // observerInstallFocused: grab the currently-focused window right now —
            // for an app already showing a full-screen window at launch, this is the
            // one shot the notifications won't give us.
            self.focusedProbe(pid: pid, bundleID: bundleID, appName: name, trigger: .observerInstallFocused)

            // Back to main only for the run-loop-source attach + map insert.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.installing.remove(pid)
                // App may have terminated, or another path installed, while off-main.
                guard NSRunningApplication(processIdentifier: pid) != nil, self.observers[pid] == nil else { return }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
                self.observers[pid] = obs
            }
        }
    }

    // MARK: - Notification handling (callback on main → axQueue)

    /// Entry point from the C callback (fires on the main run loop). Derives the
    /// pid locally (no IPC), then does all AX work off-main.
    fileprivate func handle(element: AXUIElement, notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != 0, pid != getpid() else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier, name = app?.localizedName
        if debug { Log.write("registry.observer.event notif=\(notification) pid=\(pid) app=\(name ?? "?")") }

        axQueue.async { [weak self] in
            guard let self else { return }
            switch notification {
            case kAXWindowCreatedNotification:
                // The notification element IS the new window.
                AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
                self.resolveAndStore(window: element, pid: pid, bundleID: bundleID, appName: name, trigger: .windowCreated, attempt: 1)
            case kAXFocusedWindowChangedNotification:
                // The callback element is inconsistent across apps for this
                // notification (app vs window); read the focused window
                // deterministically from the app element instead.
                let appEl = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appEl, Self.messagingTimeout)
                if let win = self.copyFocusedWindow(appEl) {
                    AXUIElementSetMessagingTimeout(win, Self.messagingTimeout)
                    self.resolveAndStore(window: win, pid: pid, bundleID: bundleID, appName: name, trigger: .focusedWindowChanged, attempt: 1)
                } else if self.debug {
                    Log.write("registry.observer.resolve notif=focusedWindowChanged pid=\(pid) result=miss reason=no-focused-window")
                }
            default:
                break
            }
        }
    }

    /// `kAXFocusedWindow` probe — the decisive Phase C measurement. Single-shot
    /// (the focused window is steady-state, not a transition): logs the
    /// `kAXWindows` count alongside the focused-window resolution so a line with
    /// `kAXWindowsCount=0 focusedPresent=1 result=ok` is exactly the cold
    /// full-screen win. Off-main.
    private func focusedProbe(pid: pid_t, bundleID: String?, appName: String?, trigger: WindowAXRegistry.Source) {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, Self.messagingTimeout)

        var windowsRef: CFTypeRef?
        let windowsErr = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef)
        let windowsCount = (windowsRef as? [AXUIElement])?.count ?? 0

        guard let win = copyFocusedWindow(appEl) else {
            if debug {
                Log.write("registry.observer.focusedProbe trigger=\(trigger.rawValue) pid=\(pid) app=\(appName ?? "?") kAXWindowsErr=\(windowsErr.rawValue) kAXWindowsCount=\(windowsCount) focusedPresent=0 result=miss")
            }
            return
        }
        AXUIElementSetMessagingTimeout(win, Self.messagingTimeout)
        var wid: CGWindowID = 0
        let getErr = _AXUIElementGetWindow(win, &wid)
        let resolved = (getErr == .success && wid != 0)
        if debug {
            Log.write("registry.observer.focusedProbe trigger=\(trigger.rawValue) pid=\(pid) app=\(appName ?? "?") kAXWindowsErr=\(windowsErr.rawValue) kAXWindowsCount=\(windowsCount) focusedPresent=1 getWindowErr=\(getErr.rawValue) resolvedWID=\(wid) result=\(resolved ? "ok" : "unresolved")")
        }
        if resolved {
            registry.store(element: win, wid: wid, pid: pid, bundleID: bundleID, title: copyTitle(win), source: trigger, debug: debug)
        }
    }

    /// Resolve a window element to its `CGWindowID` and store it, with a bounded
    /// recapture for the transition case where the WindowServer ID lags the AX
    /// element (window-created / focus-changed). Off-main; retries via `axQueue`.
    private func resolveAndStore(window: AXUIElement, pid: pid_t, bundleID: String?, appName: String?, trigger: WindowAXRegistry.Source, attempt: Int) {
        var wid: CGWindowID = 0
        let getErr = _AXUIElementGetWindow(window, &wid)
        if getErr == .success, wid != 0 {
            registry.store(element: window, wid: wid, pid: pid, bundleID: bundleID, title: copyTitle(window), source: trigger, debug: debug)
            if debug { Log.write("registry.observer.resolve notif=\(trigger.rawValue) pid=\(pid) app=\(appName ?? "?") wid=\(wid) result=ok attempt=\(attempt)/\(Self.maxResolveAttempts)") }
            return
        }
        if attempt < Self.maxResolveAttempts {
            if debug { Log.write("registry.observer.resolve notif=\(trigger.rawValue) pid=\(pid) result=retry attempt=\(attempt)/\(Self.maxResolveAttempts) getWindowErr=\(getErr.rawValue)") }
            axQueue.asyncAfter(deadline: .now() + Self.resolveRetryDelay) { [weak self] in
                self?.resolveAndStore(window: window, pid: pid, bundleID: bundleID, appName: appName, trigger: trigger, attempt: attempt + 1)
            }
        } else if debug {
            Log.write("registry.observer.resolve notif=\(trigger.rawValue) pid=\(pid) app=\(appName ?? "?") result=miss attempt=\(attempt)/\(Self.maxResolveAttempts) getWindowErr=\(getErr.rawValue)")
        }
    }

    // MARK: - AX read helpers (off-main; element timeouts set by the caller)

    private func copyFocusedWindow(_ appEl: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyTitle(_ el: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}

/// C callback for `AXObserverCreate`. Must be a non-capturing top-level function
/// to convert to the `@convention(c)` `AXObserverCallback` pointer. `refcon` is the
/// owning `WindowAXObservers`, passed unretained — it's an app-lifetime singleton
/// held by `main.swift`, so it outlives every observer.
private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let mgr = Unmanaged<WindowAXObservers>.fromOpaque(refcon).takeUnretainedValue()
    mgr.handle(element: element, notification: notification as String)
}
