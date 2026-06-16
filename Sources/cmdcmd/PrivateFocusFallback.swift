import AppKit
import Carbon  // ProcessSerialNumber, OSStatus, noErr

/// Private WindowServer (SkyLight / SLPS) focus fallback for raising a specific
/// window across Spaces — including *into* another app's native full-screen
/// Space, where the public AX raise + `NSRunningApplication.activate` path
/// fails (AX reports zero windows for an off-Space app, and `activate` returns
/// false).
///
/// The symbol names, the mode value, and the `SLPSPostEventRecordTo`
/// event-record byte layout are the undocumented WindowServer ABI — the same
/// reverse-engineered sequence shipped by the MIT-licensed yabai and Hammerspoon
/// (issue #370). This is an independent implementation of that ABI; no third-
/// party source was copied.
///
/// The SLPS symbols live in the SkyLight private framework, which the app does
/// not link, so they're resolved at runtime via dlopen/dlsym — the same pattern
/// `SkyLightCapture` uses (an @_silgen_name bind would fail at link time).
enum PrivateFocusFallback {

    private static let slpsUserGenerated: UInt32 = 0x200   // SLPSMode "user generated"

    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private struct Symbols {
        let setFront: SetFrontFn
        let postEvent: PostEventFn
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            Log.write("PrivateFocusFallback: dlopen SkyLight failed")
            return nil
        }
        guard let setFrontSym = dlsym(handle, "_SLPSSetFrontProcessWithOptions"),
              let postSym = dlsym(handle, "SLPSPostEventRecordTo") else {
            Log.write("PrivateFocusFallback: SLPS symbols missing")
            return nil
        }
        return Symbols(
            setFront: unsafeBitCast(setFrontSym, to: SetFrontFn.self),
            postEvent: unsafeBitCast(postSym, to: PostEventFn.self)
        )
    }()

    /// Make `pid`'s window `windowID` frontmost via the private path. Returns
    /// whether the set-front call reported success. Logs each private call's
    /// return value when `debug` is set.
    @discardableResult
    static func raise(pid: pid_t, windowID: CGWindowID, debug: Bool) -> Bool {
        guard let symbols else {
            if debug { Log.write("SLPS: unavailable (SkyLight symbols not resolved)") }
            return false
        }
        var psn = ProcessSerialNumber()
        let status = _GetProcessForPID(pid, &psn)
        if debug { Log.write("SLPS GetProcessForPID: pid=\(pid) status=\(status)") }
        guard status == noErr else { return false }

        let setFront = symbols.setFront(&psn, windowID, slpsUserGenerated)
        let (post1, post2) = postRaiseEvents(symbols, &psn, windowID: windowID)
        if debug {
            Log.write("SLPS raise: pid=\(pid) wid=\(windowID) setFront=\(setFront.rawValue) post1=\(post1.rawValue) post2=\(post2.rawValue)")
        }
        return setFront == .success
    }

    /// Two synthetic WindowServer raise events. A 248-byte (0xf8) record with a
    /// fixed layout; the two events differ only in byte 0x08 (0x01 then 0x02).
    /// The offsets/values are the documented ABI (Hammerspoon #370) and must
    /// match exactly or the WindowServer ignores the event. Returns each post's
    /// CGError.
    private static func postRaiseEvents(_ symbols: Symbols, _ psn: inout ProcessSerialNumber, windowID: CGWindowID) -> (CGError, CGError) {
        var wid = windowID
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &wid, MemoryLayout<CGWindowID>.size)   // target window id (4 bytes)
        memset(&bytes[0x20], 0xff, 0x10)                           // 16 bytes of 0xff
        bytes[0x08] = 0x01
        let e1 = symbols.postEvent(&psn, &bytes)
        bytes[0x08] = 0x02
        let e2 = symbols.postEvent(&psn, &bytes)
        return (e1, e2)
    }
}

// GetProcessForPID (pid → ProcessSerialNumber) is marked unavailable in Swift —
// a pre-10.9 Carbon API — but the symbol ships in HIServices, which the app
// already links, so an @_silgen_name bind resolves at link time (unlike the
// SkyLight SLPS symbols above, which need dlsym).
@_silgen_name("GetProcessForPID")
fileprivate func _GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
