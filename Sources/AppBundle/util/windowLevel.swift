import AppKit

/// How high a window sits in the global stacking order.
///
/// macOS layers windows by *app* first, so `kAXRaiseAction` can only reorder a window among its own app's windows --
/// it can never lift a floating dialog above a different app's tiled window, because activating that app puts all of
/// its windows above all of the dialog's. The window's level is the only knob that crosses app boundaries
enum WindowLevel: Equatable, Sendable {
    case normal
    case floating

    fileprivate var cgLevel: Int32 {
        switch self {
            case .normal: CGWindowLevelForKey(.normalWindow)
            case .floating: CGWindowLevelForKey(.floatingWindow)
        }
    }
}

private typealias SLSMainConnectionIDFn = @convention(c) () -> Int32
private typealias SLSSetWindowLevelFn = @convention(c) (Int32, UInt32, Int32) -> CGError

/// SkyLight is private, so it is resolved at run time rather than linked. A macOS release that renames or drops
/// these symbols costs the feature, not the app: `setWindowLevel` then reports failure and every window keeps the
/// level macOS gave it
private let skyLight: (connectionId: Int32, setWindowLevel: SLSSetWindowLevelFn)? = {
    let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let handle = unsafe dlopen(path, RTLD_LAZY) else { return nil }
    guard let mainConnectionId = unsafe dlsym(handle, "SLSMainConnectionID"),
          let setWindowLevel = unsafe dlsym(handle, "SLSSetWindowLevel")
    else { return nil }
    let getConnectionId = unsafe unsafeBitCast(mainConnectionId, to: SLSMainConnectionIDFn.self)
    return unsafe (getConnectionId(), unsafeBitCast(setWindowLevel, to: SLSSetWindowLevelFn.self))
}()

/// Moves `windowId` to `level`. Returns whether it worked
@MainActor func setWindowLevel(_ windowId: UInt32, _ level: WindowLevel) -> Bool {
    guard let skyLight else { return false }
    return skyLight.setWindowLevel(skyLight.connectionId, windowId, level.cgLevel) == .success
}
