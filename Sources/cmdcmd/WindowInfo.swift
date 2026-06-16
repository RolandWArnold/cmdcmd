import AppKit
import CoreGraphics

/// Which Spaces to enumerate. Shared by `SpaceTracker.windows(scope:)`,
/// `WindowInfo.enumerate(scope:)`, and `Config.windowScope`.
enum WindowScope: String, Codable {
    case currentSpace = "current-space"
    case allSpaces = "all-spaces"
}

/// Plain snapshot of the per-window facts we used to lean on `SCWindow` for.
/// Populated from `CGWindowListCopyWindowInfo` + `NSRunningApplication` so the
/// app never needs to spin up ScreenCaptureKit just to enumerate windows
/// (which would light the screen-recording indicator).
struct WindowInfo {
    let windowID: CGWindowID
    let frame: CGRect
    let title: String?
    let applicationName: String
    let bundleIdentifier: String?
    let processID: pid_t
    let layer: Int
    let isOnScreen: Bool
    /// Managed Space the window lives on, and its kind. Nil when no tracker was
    /// supplied (legacy current-Space path) or the window has no managed Space
    /// (spaceID 0 — e.g. Dock / Notification Center hosts).
    let spaceID: CGSSpaceID?
    let spaceType: SpaceType?
    /// UUID of the display the window's Space belongs to, when known.
    let displayUUID: String?
    /// Space == the active Space at enumeration time. Useful for labelling, but
    /// for "is it safe to fly this tile from its real frame" prefer the
    /// per-overlay `isOnScreen && isOnActiveDisplay` check computed at render
    /// time — the active Space is ambiguous across multiple displays.
    let isOnActiveSpace: Bool

    /// Legacy current-Space enumeration without Space metadata, kept for the
    /// pre-7.6 call site. The overlay uses `enumerate(scope:tracker:)`.
    static func enumerate() -> [WindowInfo] {
        enumerate(options: [.optionOnScreenOnly, .excludeDesktopElements], tracker: nil)
    }

    /// Enumerate windows for `scope`, annotated with Space metadata from
    /// `tracker`. `.currentSpace` keeps the on-screen-only set; `.allSpaces`
    /// drops `.optionOnScreenOnly` so windows in other Spaces and native
    /// full-screen Spaces are returned too (proven by the §5 gate). WindowServer
    /// Z-order, front-most first.
    static func enumerate(scope: WindowScope, tracker: SpaceTracker) -> [WindowInfo] {
        let opts: CGWindowListOption = scope == .allSpaces
            ? [.excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        return enumerate(options: opts, tracker: tracker)
    }

    private static func enumerate(options opts: CGWindowListOption, tracker: SpaceTracker?) -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        // Resolve Space metadata once for the whole set — spaceMap does N IPC
        // calls, so batch it here rather than per-window. Empty without a tracker.
        let ids = raw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let spaceMap = tracker?.spaceMap(for: ids) ?? [:]
        let spaceByID = tracker?.spaceByID() ?? [:]
        let activeSpace = tracker?.activeSpaceID()

        var bundleCache: [pid_t: String?] = [:]
        return raw.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let pidNum = entry[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let pid = pid_t(pidNum)
            let owner = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            let title = entry[kCGWindowName as String] as? String
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            let onScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let bundleID: String?
            if let cached = bundleCache[pid] {
                bundleID = cached
            } else {
                let resolved = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                bundleCache[pid] = resolved
                bundleID = resolved
            }
            let wid = CGWindowID(id)
            let spaceID = spaceMap[wid]
            let space = spaceID.flatMap { spaceByID[$0] }
            let onActiveSpace = activeSpace != nil && spaceID == activeSpace
            return WindowInfo(
                windowID: wid,
                frame: frame,
                title: title,
                applicationName: owner,
                bundleIdentifier: bundleID,
                processID: pid,
                layer: layer,
                isOnScreen: onScreen,
                spaceID: spaceID,
                spaceType: space?.type,
                displayUUID: space?.displayUUID,
                isOnActiveSpace: onActiveSpace
            )
        }
    }
}
