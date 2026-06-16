import AppKit

/// Experimental private WindowServer Space switch, ported from yabai's
/// space-focus sequence (MIT — koekeishiya/yabai, `src/osax/payload.m`
/// `do_space_focus`): for a target Space on a display, issue
///   `SLSShowSpaces([dest])` → `SLSHideSpaces([src])` → `SLSManagedDisplaySetCurrentSpace(dest)`.
///
/// IMPORTANT CAVEAT: yabai makes these calls from *inside Dock* (an injected
/// scripting addition, on Dock's connection) and additionally patches Dock's
/// `_currentSpace` ivar. From our own process the symbols resolve and the calls
/// run, but the WindowServer authorizes managed-display Space transitions per
/// the caller's connection (canonically Dock's), so an in-process switch is NOT
/// guaranteed to take — and may leave Dock's Space model briefly desynced. This
/// is an experiment whose logs tell us whether it works on this machine.
///
/// Symbols resolved via dlsym from the SkyLight private framework (the SLS
/// space-switch family, plus the legacy CGS aliases, live there), matching how
/// `SkyLightCapture` / `PrivateFocusFallback` isolate their SPI.
enum PrivateSpaceSwitcher {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias SetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void
    private typealias GetCurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
    private typealias CopyDisplayForSpaceFn = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?
    private typealias ShowHideSpacesFn = @convention(c) (Int32, CFArray) -> Void

    private struct Symbols {
        let mainConnection: MainConnFn
        let setCurrentSpace: SetCurrentSpaceFn
        let getCurrentSpace: GetCurrentSpaceFn
        let copyDisplayForSpace: CopyDisplayForSpaceFn
        let showSpaces: ShowHideSpacesFn
        let hideSpaces: ShowHideSpacesFn
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            Log.write("PrivateSpaceSwitcher: dlopen SkyLight failed")
            return nil
        }
        guard let mainSym = dlsym(handle, "SLSMainConnectionID"),
              let setSym = dlsym(handle, "SLSManagedDisplaySetCurrentSpace"),
              let getSym = dlsym(handle, "SLSManagedDisplayGetCurrentSpace"),
              let copySym = dlsym(handle, "SLSCopyManagedDisplayForSpace"),
              let showSym = dlsym(handle, "SLSShowSpaces"),
              let hideSym = dlsym(handle, "SLSHideSpaces") else {
            Log.write("PrivateSpaceSwitcher: SLS symbols missing")
            return nil
        }
        return Symbols(
            mainConnection: unsafeBitCast(mainSym, to: MainConnFn.self),
            setCurrentSpace: unsafeBitCast(setSym, to: SetCurrentSpaceFn.self),
            getCurrentSpace: unsafeBitCast(getSym, to: GetCurrentSpaceFn.self),
            copyDisplayForSpace: unsafeBitCast(copySym, to: CopyDisplayForSpaceFn.self),
            showSpaces: unsafeBitCast(showSym, to: ShowHideSpacesFn.self),
            hideSpaces: unsafeBitCast(hideSym, to: ShowHideSpacesFn.self)
        )
    }()

    /// Attempt to make `spaceID` the current Space on its display. Returns
    /// whether the switch calls were issued (false if symbols are unavailable or
    /// the Space is already current). Logs each step when `debug` is set.
    @discardableResult
    static func switchTo(spaceID: CGSSpaceID, displayUUID: String?, debug: Bool) -> Bool {
        guard let symbols else {
            if debug { Log.write("SpaceSwitch: unavailable (SLS symbols not resolved)") }
            return false
        }
        let cid = symbols.mainConnection()
        // Prefer the target window's stored displayUUID (per spec — not inferred
        // from geometry); also derive yabai's way (from the space id) and log
        // both so a format mismatch is visible.
        let derived = symbols.copyDisplayForSpace(cid, spaceID).map { $0.takeRetainedValue() as String }
        let display: CFString = (displayUUID ?? derived ?? "") as CFString
        let currentOnDisplay = symbols.getCurrentSpace(cid, display)
        if debug {
            Log.write("SpaceSwitch: cid=\(cid) target=\(spaceID) displayUUID=\(displayUUID ?? "-") derivedDisplay=\(derived ?? "-") currentOnDisplay=\(currentOnDisplay)")
        }
        guard currentOnDisplay != spaceID else {
            if debug { Log.write("SpaceSwitch: already current") }
            return false
        }
        symbols.showSpaces(cid, [NSNumber(value: spaceID)] as CFArray)
        symbols.hideSpaces(cid, [NSNumber(value: currentOnDisplay)] as CFArray)
        symbols.setCurrentSpace(cid, display, spaceID)
        if debug {
            Log.write("SpaceSwitch: issued Show([\(spaceID)]) Hide([\(currentOnDisplay)]) SetCurrentSpace(\(spaceID))")
        }
        return true
    }
}
