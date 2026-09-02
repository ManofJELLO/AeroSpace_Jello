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

/// Where the left button was last pressed, so that a release can tell a drag from a click that wandered a little
@MainActor var lastMouseDown: CGPoint? = nil

/// Where and when the left button was last released, while it is still plausible that a drag notification is on its
/// way for it.
///
/// A drag is only recognised once the app reports that its window moved, and on a quick flick that report loses its
/// race with the release: the notification's handler sees the button already up and throws the drag away. Leaving the
/// release position behind lets the notification land late and still be applied where the button actually came up
@MainActor private var pendingLateDrag: (cursor: CGPoint, at: ContinuousClock.Instant, releaseId: Int)? = nil
/// The release whose drag has already been applied, so that a duplicate of it can't set one up again
@MainActor private var handledReleaseId: Int? = nil

/// How far the pointer has to travel before a release counts as a drag rather than an unsteady click
private let dragThreshold: CGFloat = 10
/// How late a move notification may arrive and still be treated as the tail of the drag that just ended
private let lateDragGrace: Duration = .milliseconds(300)

/// Records a release that might still turn out to have been a drag. Called synchronously from the event monitor, so
/// that a notification arriving before the release has even been processed still finds the position
/// `releaseId` is the event's `eventNumber`. macOS hands a global monitor the same mouse-up twice while a window is
/// being dragged -- same event number, a few milliseconds apart -- and the duplicate must not disturb what the first
/// one set up, nor arm a second drag of its own
@MainActor func armLateDrag(releasedAt cursor: CGPoint, releaseId: Int) {
    if handledReleaseId == releaseId || pendingLateDrag?.releaseId == releaseId { return }
    guard let press = lastMouseDown, press.distance(to: cursor) > dragThreshold else { return }
    pendingLateDrag = (cursor, .now, releaseId)
}

/// Records that this release has been dealt with by the ordinary path, so nothing is left waiting on a notification
@MainActor func markReleaseHandled(_ releaseId: Int) {
    handledReleaseId = releaseId
    if pendingLateDrag?.releaseId == releaseId { pendingLateDrag = nil }
}

/// The position of a release still waiting for its move notification, if there is one. One shot: a second caller,
/// such as the notification our own re-layout provokes, gets nothing
@MainActor func consumeLateDrag() -> CGPoint? {
    guard let pending = pendingLateDrag else { return nil }
    pendingLateDrag = nil
    return pending.at.advanced(by: lateDragGrace) > .now ? pending.cursor : nil
}
