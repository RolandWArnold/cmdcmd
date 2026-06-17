import AppKit
import CoreGraphics
import Sparkle

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-iconset"), i + 1 < args.count {
    let url = URL(fileURLWithPath: args[i + 1])
    do {
        try AppIcon.writeIconset(to: url)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render-iconset failed: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared

if args.contains("--stress") {
    NSApp.setActivationPolicy(.accessory)
    app.finishLaunching()
    let serialize = args.contains("--serialize")
    let iterations: Int = {
        if let i = args.firstIndex(of: "--iterations"), i + 1 < args.count, let n = Int(args[i + 1]) {
            return n
        }
        return 500
    }()
    Task.detached(priority: .userInitiated) {
        await StressTest.run(serialize: serialize, iterations: iterations)
    }
    RunLoop.main.run()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var settingsFactory: (() -> SettingsWindowController)?
    private var settingsController: SettingsWindowController?
    private var statusItem: NSStatusItem?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return buildAppMenu()
    }

    private func buildAppMenu() -> NSMenu {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let openItem = NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let checkItem = NSMenuItem(title: "Check for Updates…",
                                   action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                   keyEquivalent: "")
        checkItem.target = updaterController
        menu.addItem(checkItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit cmdcmd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func applyDisplayMode(_ mode: DisplayMode) {
        switch mode {
        case .dock:
            removeStatusItem()
            NSApp.setActivationPolicy(.regular)
        case .menuBar:
            NSApp.setActivationPolicy(.accessory)
            installStatusItem()
        case .hidden:
            removeStatusItem()
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func installStatusItem() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let icon = NSImage(systemSymbolName: "command", accessibilityDescription: "cmdcmd")
            icon?.isTemplate = true
            item.button?.image = icon
            item.menu = buildAppMenu()
            statusItem = item
        }
    }

    private func removeStatusItem() {
        if let s = statusItem {
            NSStatusBar.system.removeStatusItem(s)
        }
        statusItem = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    @objc func openSettings() {
        let controller = settingsController ?? settingsFactory?()
        settingsController = controller
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openConfig() {
        do {
            let url = try Config.ensureExists()
            NSWorkspace.shared.open(url)
        } catch {
            Log.write("openConfig failed: \(error)")
        }
    }
}

let appDelegate = AppDelegate()
app.delegate = appDelegate
app.finishLaunching()

_ = try? Config.ensureExists()
var appConfig = Config.load()
appDelegate.applyDisplayMode(appConfig.displayModeOrDefault)
let tracker = SpaceTracker()
let axRegistry = WindowAXRegistry(debug: { appConfig.debugLoggingEnabled })
let axObservers = WindowAXObservers(registry: axRegistry, debug: { appConfig.debugLoggingEnabled })
let overlay = Overlay(tracker: tracker, config: appConfig, registry: axRegistry)
var trigger: AnyObject?

appDelegate.settingsFactory = {
    let controller = SettingsWindowController(config: appConfig)
    controller.onSave = { newConfig in
        appConfig = newConfig
        overlay.updateConfig(newConfig)
        appDelegate.applyDisplayMode(newConfig.displayModeOrDefault)
    }
    return controller
}

func startApp() {
    // 1A: startup identity + trust snapshot, off-main so it never delays launch.
    if appConfig.debugLoggingEnabled {
        DispatchQueue.global(qos: .utility).async { Diagnostics.logStartup() }
    }
    // Phase B: seed the AX registry (launch backfill, off-main) and begin
    // activation-driven scans. Show-time capture continues to feed it too.
    axRegistry.startPopulation()
    // Phase C: per-app AXObservers — retain windows at creation / focus time so
    // off-Space / full-screen targets have a retained handle at pick time even
    // when they were never shown in the overlay. Gated by a config kill-switch;
    // must run on main (run-loop sources attach to the main run loop).
    if appConfig.windowObserversEnabled {
        axObservers.start()
    }
    let fire = {
        overlay.toggle()
        // 1F: keep the heavy diagnostics (CGWindowList + per-window Space IPC +
        // the AX backfill probe) OFF the synchronous trigger path. Previously
        // dumpState + runEnumeration ran inline here, blocking the main run loop
        // between trigger and the async present/focus — so enabling debug
        // perturbed the very timing under measurement. Dispatched to a background
        // queue, turning debug on changes what's logged, not trigger → present →
        // pick timing.
        if appConfig.debugLoggingEnabled {
            // Snapshot AppKit/main-thread-only display state HERE, on-main, into a
            // plain value type — cheap reads, not the heavy enumeration — so the
            // background work below touches no NSScreen / NSEvent off-main.
            let display = Diagnostics.snapshotDisplay()
            DispatchQueue.global(qos: .utility).async {
                dumpState(tracker: tracker)
                Diagnostics.runEnumeration(tracker: tracker, display: display)
                Diagnostics.runBackfillProbe(tracker: tracker)
            }
        }
    }
    if appConfig.triggerSpec.lowercased() == "cmd-cmd" {
        trigger = CmdChord(handler: fire)
    } else if let monitor = HotkeyMonitor(spec: appConfig.triggerSpec, handler: fire) {
        trigger = monitor
        Log.write("trigger = \(appConfig.triggerSpec)")
    } else {
        Log.write("trigger spec '\(appConfig.triggerSpec)' invalid; falling back to cmd-cmd")
        trigger = CmdChord(handler: fire)
    }
    dumpState(tracker: tracker)
}

let onboarding = Onboarding(onComplete: startApp)
if !onboarding.showIfNeeded() {
    startApp()
}

NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil,
    queue: .main
) { _ in
    overlay.shutdown()
}

func dumpState(tracker: SpaceTracker) {
    guard appConfig.debugLoggingEnabled else { return }
    let spaces = tracker.spaces()
    let windows = tracker.windows()
    // Build the dump as one string and route it through Log so it lands in
    // /tmp/cmdcmd.log. print() only hits stdout, which LaunchServices discards
    // for an `open`-launched bundle, so the dump was previously unreadable.
    var out = "--- spaces (\(spaces.count)) ---\n"
    for s in spaces {
        let active = s.isActive ? " *" : ""
        out += "  \(s.id) [\(s.type)] display=\(s.displayUUID.prefix(8))\(active)\n"
    }
    out += "--- windows (\(windows.count)) ---\n"
    for w in windows where !w.ownerName.isEmpty {
        let space = w.spaceID.map(String.init) ?? "-"
        out += "  \(w.windowID) space=\(space) \(w.ownerName) :: \(w.title)\n"
    }
    Log.write(out)
}

app.run()
