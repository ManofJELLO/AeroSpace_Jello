import AppKit
import Common

extension Window {
    /// Puts the floating windows of this window's app back on top after focusing a tiled one.
    ///
    /// Only the same app: macOS stacks windows by app, so `kAXRaiseAction` can reorder windows within an app but can
    /// never lift one above a different app's windows. Doing that means setting the window's level, and WindowServer
    /// ignores level changes to windows owned by another connection unless SIP is disabled -- which is the one thing
    /// AeroSpace exists to avoid. So an app's own dialog is what this can keep visible
    @MainActor
    func raiseFloatingWindowsOfTheSameApp() {
        for window in floatingWindowsToRaise { window.nativeRaise() }
    }

    /// Which floating windows ought to be put back on top once this window has the focus
    @MainActor
    var floatingWindowsToRaise: [Window] {
        if !config.floatingWindowsOnTop { return [] }
        // Focusing a floating window already brings it forward, and raising the others would bury the one asked for
        if isFloating { return [] }
        guard let workspace = visualWorkspace else { return [] }
        // A window macOS put in its own fullscreen space owns that space outright. Covering it with a dialog the user
        // never asked for is worse than the burial this is trying to prevent
        if !workspace.macOsNativeFullscreenWindowsContainer.children.isEmpty { return [] }
        return workspace.floatingWindows.filter { $0.app.pid == app.pid && $0 != self }
    }
}
