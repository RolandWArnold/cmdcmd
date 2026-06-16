import AppKit

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windows: CFArray) -> CFArray

enum SpaceType: Int {
    case user = 0
    case fullscreen = 4
    case system = 2
    case tiled = 5

    init(raw: Int) {
        self = SpaceType(rawValue: raw) ?? .user
    }
}

struct Space {
    let id: CGSSpaceID
    let uuid: String
    let type: SpaceType
    let displayUUID: String
    let isActive: Bool
}

struct SpaceWindow {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let bounds: CGRect
    let spaceID: CGSSpaceID?
}

final class SpaceTracker {
    private let cid = CGSMainConnectionID()

    func spaces() -> [Space] {
        let active = CGSGetActiveSpace(cid)
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }

        var result: [Space] = []
        for display in displays {
            let displayUUID = display["Display Identifier"] as? String ?? ""
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                guard let id = space["id64"] as? UInt64 else { continue }
                let uuid = space["uuid"] as? String ?? ""
                let type = SpaceType(raw: (space["type"] as? Int) ?? 0)
                result.append(Space(
                    id: id,
                    uuid: uuid,
                    type: type,
                    displayUUID: displayUUID,
                    isActive: id == active
                ))
            }
        }
        return result
    }

    func windows() -> [SpaceWindow] {
        windows(scope: .currentSpace)
    }

    /// Enumerate windows for the given scope, each annotated with the Space it
    /// occupies. `.currentSpace` keeps the on-screen-only set (existing
    /// behaviour); `.allSpaces` drops `.optionOnScreenOnly` so windows in other
    /// Spaces and native full-screen Spaces are returned too. Diagnostics path.
    func windows(scope: WindowScope) -> [SpaceWindow] {
        let opts: CGWindowListOption = scope == .allSpaces
            ? [.excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }

        let ids = raw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let spaceMap = spacesForWindows(ids)

        return raw.compactMap { dict in
            guard
                let id = dict[kCGWindowNumber as String] as? CGWindowID,
                let pid = dict[kCGWindowOwnerPID as String] as? pid_t
            else { return nil }
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""
            let title = dict[kCGWindowName as String] as? String ?? ""
            let bounds = (dict[kCGWindowBounds as String] as? [String: CGFloat]).flatMap { b -> CGRect? in
                guard let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            } ?? .zero
            return SpaceWindow(
                windowID: id,
                ownerPID: pid,
                ownerName: owner,
                title: title,
                bounds: bounds,
                spaceID: spaceMap[id]
            )
        }
    }

    func activeSpace() -> CGSSpaceID {
        CGSGetActiveSpace(cid)
    }

    /// Window→Space accessor for callers building their own per-window metadata
    /// (e.g. `WindowInfo.enumerate(scope:tracker:)`). Wraps the per-window
    /// `spacesForWindows` core.
    func spaceMap(for windowIDs: [CGWindowID]) -> [CGWindowID: CGSSpaceID] {
        spacesForWindows(windowIDs)
    }

    /// Space metadata keyed by Space ID, built from the managed-display list.
    func spaceByID() -> [CGSSpaceID: Space] {
        Dictionary(spaces().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func activeSpaceID() -> CGSSpaceID {
        activeSpace()
    }

    /// Map each window to the Space it occupies.
    ///
    /// `CGSCopySpacesForWindows` returns the *deduplicated set* of Spaces the
    /// passed windows occupy, not a parallel one-entry-per-window array. A
    /// single batch call therefore scrambles the moment two windows share a
    /// Space (i.e. always), which is why every working consumer (yabai,
    /// AltTab, asmagill `spaces`) queries one window at a time. We do the same:
    /// N IPC calls, kept off the main thread by the async enumeration path that
    /// drives this.
    private func spacesForWindows(_ ids: [CGWindowID]) -> [CGWindowID: CGSSpaceID] {
        var map: [CGWindowID: CGSSpaceID] = [:]
        for id in ids {
            let arr = [NSNumber(value: id)] as CFArray
            // 0x7 = current | other | user spaces.
            let result = CGSCopySpacesForWindows(cid, 0x7, arr)
            guard let nums = result as? [NSNumber], let first = nums.first else { continue }
            // A sticky (canJoinAllSpaces) window reports multiple Space IDs;
            // taking .first is an acceptable v1 simplification.
            let spaceID = first.uint64Value
            if spaceID != 0 { map[id] = spaceID }
        }
        return map
    }
}
