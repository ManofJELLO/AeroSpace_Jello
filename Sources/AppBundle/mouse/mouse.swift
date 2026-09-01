import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil
/// The window being dragged, from the first mouse event until the button is released.
///
/// A tiling drag doesn't touch the tree while it is in flight, it is applied once on mouse-up. That way the window
/// lands where the cursor actually is when you let go, dragging somewhere and back again is a no-op, and a quick
/// flick doesn't depend on the last move notification winning a race against the mouse-up
@MainActor var currentlyDraggedWithMouseWindowId: UInt32? = nil
var isLeftMouseButtonDown: Bool { NSEvent.pressedMouseButtons == 1 }

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    // Don't allow to resize/move windows of hidden workspaces
    if window.isHiddenInCorner || !isLeftMouseButtonDown { return false }
    switch currentlyManipulatedWithMouseWindowId {
        // Which window this manipulation belongs to is already settled. Asking the app which window has focus would
        // cost an AX round-trip into a possibly busy process, on every single mouse event of the drag
        case window.windowId: return true
        case nil: return try await getNativeFocusedWindow(.cancellable) == window
        default: return false
    }
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint { NSEvent.mouseLocation.withYAxisFlipped }
