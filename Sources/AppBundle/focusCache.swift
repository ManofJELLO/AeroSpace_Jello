@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    // A focus change we asked for is still on its way. Taking macOS at its word here would undo it
    if isAwaitingSelfInflictedFocus(insteadOf: nativeFocused) {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}

/// Records a focus change that AeroSpace made itself.
///
/// The data flows the other way around here: we already know which window we handed focus to, so there is no need to
/// ask the outgoing app which window it thinks is focused. Skipping that round trip keeps focus-follows-mouse off the
/// AX thread of an app that may be busy
@MainActor func noteFocusGivenTo(_ window: Window) {
    lastKnownNativeFocusedWindowId = window.windowId
    window.macAppUnsafe.lastNativeFocusedWindowId = window.windowId
}
