import AppKit
import Common

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        guard try await isManipulatedWithMouse(window) else {
            // The button is already up. If it only just came up after travelling, this is the tail of a drag whose
            // notifications lost their race with the release -- which is what a very quick flick looks like. Apply
            // it where the button actually came up, rather than throwing the drag away
            if window.parent is TilingContainer, let cursor = consumeLateDrag() {
                try await runLightSession(.ax(notif), token) {
                    moveTilingWindow(window, cursor: cursor)
                    // moveTilingWindow marks the window as mouse-manipulated, and the layout at the end of this
                    // session skips whichever window that names
                    clearMouseManipulationState()
                }
            } else {
                scheduleCancellableCompleteRefreshSession(.ax(notif))
            }
            return
        }
        // Most events of a drag land inside the slot the window already occupies. Running a session for those costs
        // two AX round-trips and a re-layout of every window, to end up exactly where we started
        guard moveWithMouseWouldChangeLayout(window) else { return }
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token, scheduleCompleteRefresh: false) {
                try await moveWithMouse(window)
            }
        }
    }
}

@MainActor
private func moveWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    resetMacosFullscreenLayoutSnapshots()
    switch window.windowParentCases {
        case .floatingWindowsContainer:
            try await moveFloatingWindow(window)
        case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Unconventional windows can't be moved with mouse
        case .tilingContainer:
            if currentlyManipulatedWithMouseWindowId == window.windowId {
                previewTilingDrag(window, cursor: mouseLocation)
            } else {
                beginTilingDrag(window)
            }
        case .unbound: return
    }
}

@MainActor
private func moveFloatingWindow(_ window: Window) async throws {
    guard let targetWorkspace = try await window.getCenter(.cancellable)?.monitorApproximation.activeWorkspace else { return }
    guard let parent = window.parent else { return }
    if targetWorkspace != parent {
        window.bindAsFloatingWindow(to: targetWorkspace)
    }
}

/// Whether this mouse event has anything to do, checked before paying for a whole refresh session
@MainActor
private func moveWithMouseWouldChangeLayout(_ window: Window) -> Bool {
    switch window.windowParentCases {
        case .tilingContainer:
            // The first event of a drag always runs. It marks the window as manipulated, which is what stops the
            // layout from fighting the drag, and lets the other windows settle around it
            if currentlyManipulatedWithMouseWindowId != window.windowId { return true }
            // By default the tree isn't touched again until the button is released. With a live preview, only the
            // events that resolve to a different drop are worth a session
            guard let preview = dragPreview else { return false }
            return preview.intent(at: mouseLocation, dragged: window) != preview.appliedIntent
        case .floatingWindowsContainer, .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer, .unbound:
            return true
    }
}

/// Marks a window as being dragged. The tree is left alone until ``commitTilingDragIfNeeded(cursor:)``, unless
/// `live-drag-preview` is on, in which case a snapshot is taken so previews can be applied and taken back
@MainActor
func beginTilingDrag(_ window: Window) {
    dragPreview = config.liveDragPreview ? TilingDragPreview(dragged: window) : nil
    currentlyManipulatedWithMouseWindowId = window.windowId
    currentlyDraggedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
    window.needsUnconditionalFrameWrite = true
}

/// Shows where the window would land if it were released now. Does nothing unless `live-drag-preview` is on
@MainActor
func previewTilingDrag(_ window: Window, cursor: CGPoint) {
    dragPreview?.apply(dragged: window, cursor: cursor)
}

/// Applies a tiling drag at the position the cursor was released at. Call on mouse-up, before the manipulation state
/// is cleared, so that the refresh it schedules lays out the result
@MainActor
func commitTilingDragIfNeeded(cursor: CGPoint) {
    guard let windowId = currentlyDraggedWithMouseWindowId else { return }
    currentlyDraggedWithMouseWindowId = nil
    defer { dragPreview = nil }
    guard let window = Window.get(byId: windowId) else { return }
    switch dragPreview {
        case let preview?: preview.apply(dragged: window, cursor: cursor)
        case nil: moveTilingWindow(window, cursor: cursor)
    }
}

/// Forgets an in-flight preview without applying it
@MainActor
func resetTilingDragPreview() { dragPreview = nil }

@MainActor private var dragPreview: TilingDragPreview? = nil

/// The arrangement a drag started from, kept so that a live preview can be replaced rather than compounded.
///
/// Every preview is computed from this snapshot, never from whatever the previous preview left behind. That is what
/// makes the preview provisional: bring the cursor back to where it started and the drop resolves to the original
/// slot again, so the original arrangement comes back. Planning against the snapshot's rects rather than the
/// rendered ones is the other half of it, otherwise the drop targets would slide around under the cursor as the
/// preview rearranges the windows.
@MainActor
private final class TilingDragPreview {
    private let workspaceName: String
    private let rootTilingNode: FrozenContainer
    private let mruWindowIds: [UInt32]
    private let rects: [UInt32: Rect]
    /// The drop currently on screen, so that an event resolving to the same one can be skipped
    private(set) var appliedIntent: DragIntent? = nil

    init(dragged: Window) {
        let workspace = dragged.nodeWorkspace ?? focus.workspace
        let root = workspace.rootTilingContainer
        workspaceName = workspace.name
        rootTilingNode = FrozenContainer(root)
        mruWindowIds = root.mruOrderedLeafWindowsRecursive.map(\.windowId)
        rects = root.allLeafWindowsRecursive.reduce(into: [:]) { rects, window in
            rects[window.windowId] = window.lastAppliedLayoutPhysicalRect
        }
    }

    /// A coarse description of where the cursor is in the pre-drag arrangement. Used only to tell one mouse event
    /// from the next, so erring towards "changed" merely costs a redundant re-apply
    func intent(at cursor: CGPoint, dragged: Window) -> DragIntent {
        let target = rects.first { $0.key != dragged.windowId && $0.value.contains(cursor) }
        return DragIntent(
            workspaceName: cursor.monitorApproximation.activeWorkspace.name,
            targetWindowId: target?.key,
            pastHorizontalMidpoint: target.map { cursor.x > $0.value.center.x } ?? false,
            pastVerticalMidpoint: target.map { cursor.y > $0.value.center.y } ?? false,
        )
    }

    func apply(dragged: Window, cursor: CGPoint) {
        restore(dragged: dragged)
        currentlyManipulatedWithMouseWindowId = dragged.windowId
        dragged.lastAppliedLayoutPhysicalRect = nil
        if let drop = planTilingDrop(dragged, cursor: cursor, rects: rects) {
            drop.apply(to: dragged)
        }
        appliedIntent = intent(at: cursor, dragged: dragged)
    }

    /// Rebuilds the pre-drag arrangement, the same way the macOS fullscreen restore does
    private func restore(dragged: Window) {
        let workspace = Workspace.get(byName: workspaceName)
        // Keep prevRoot attached until the new tree is built: restoreTreeRecursive looks windows up by id, which
        // under tests only finds windows still reachable from a workspace
        let prevRoot = workspace.rootTilingContainer
        restoreTreeRecursive(
            frozenContainer: rootTilingNode,
            parent: workspace,
            index: INDEX_BIND_LAST,
            skipUnrestorableWindows: true,
        )
        // Windows that appeared mid-drag aren't in the snapshot. Tile them rather than drop them
        for orphan in prevRoot.allLeafWindowsRecursive {
            orphan.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        prevRoot.unbindFromParent()
        // A rebuilt tree's MRU stacks collapse to document order, so replay the captured order oldest-first
        for windowId in mruWindowIds.reversed() where windowId != dragged.windowId {
            MacWindow.get(byId: windowId)?.markAsMostRecentChild()
        }
        dragged.markAsMostRecentChild()
    }
}

// periphery:ignore - every field is read by the synthesized Equatable, which periphery doesn't follow
private struct DragIntent: Equatable {
    let workspaceName: String
    let targetWindowId: UInt32?
    let pastHorizontalMidpoint: Bool
    let pastVerticalMidpoint: Bool
}

/// What a drop at `cursor` would do to the tree, or `nil` if it would leave it untouched
private enum TilingDrop {
    case bind(parent: NonLeafTreeNodeObject, index: Int, adaptiveWeight: CGFloat)
    case swap(with: Window)

    @MainActor
    func apply(to window: Window) {
        switch self {
            case .bind(let parent, let index, let adaptiveWeight):
                window.bind(to: parent, adaptiveWeight: adaptiveWeight, index: index)
            case .swap(let target):
                swapTreeNodes(mruDominant: window, target)
        }
    }
}

/// `cursor` is a parameter rather than read from ``mouseLocation`` so that the drop logic can be tested
@MainActor
func moveTilingWindow(_ window: Window, cursor: CGPoint) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
    window.needsUnconditionalFrameWrite = true
    planTilingDrop(window, cursor: cursor)?.apply(to: window)
}

/// `rects` overrides where each window is taken to be. A live preview passes the pre-drag rects so that the drop
/// targets stay still while the preview rearranges the windows underneath the cursor
@MainActor
private func planTilingDrop(_ window: Window, cursor: CGPoint, rects: [UInt32: Rect]? = nil) -> TilingDrop? {
    let targetWorkspace = cursor.monitorApproximation.activeWorkspace
    let dropTarget = dropTargetWindow(at: cursor, in: targetWorkspace, excluding: window, rects: rects)
    if targetWorkspace != window.nodeWorkspace { // Move window to a different monitor
        let index: Int = if let dropTarget, let parent = dropTarget.parent as? TilingContainer, let targetRect = dropTarget.rectForDrop(rects) {
            // weightOrientation is the axis along which the parent orders its children. It differs from 'orientation'
            // for master containers, whose children are stacked across the master/stack split
            cursor.getProjection(parent.weightOrientation) >= targetRect.center.getProjection(parent.weightOrientation)
                ? dropTarget.ownIndex.orDie() + 1
                : dropTarget.ownIndex.orDie()
        } else {
            0
        }
        return .bind(
            parent: dropTarget?.parent ?? targetWorkspace.rootTilingContainer,
            index: index,
            adaptiveWeight: WEIGHT_AUTO,
        )
    }
    guard let dropTarget else { return nil }
    // A 'master' container is an ordered list of slots rather than a spatial tree, so dropping into one inserts the
    // window at the cursor and shifts the rest along, the way Hyprland's 'drop_at_cursor' does. Every other layout
    // keeps AeroSpace's "swap with the window underneath" behavior
    guard let masterParent = (dropTarget.parent as? TilingContainer)?.takeIf({ $0.layout == .master }) else {
        return .swap(with: dropTarget)
    }
    return planMasterDrop(window, onto: dropTarget, in: masterParent, cursor: cursor, rects: rects)
}

/// The window the cursor is over, ignoring the dragged one. A dragged window has no rect of its own, so hovering
/// over the slot it came from resolves to nothing and leaves the layout alone
@MainActor
private func dropTargetWindow(
    at cursor: CGPoint,
    in workspace: Workspace,
    excluding window: Window,
    rects: [UInt32: Rect]?,
) -> Window? {
    guard let rects else {
        return cursor
            .findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?
            .takeIf { $0 != window }
    }
    return workspace.rootTilingContainer.allLeafWindowsRecursive
        .first { $0 != window && rects[$0.windowId]?.contains(cursor) == true }
}

extension Window {
    @MainActor
    fileprivate func rectForDrop(_ rects: [UInt32: Rect]?) -> Rect? {
        rects.map { $0[windowId] } ?? lastAppliedLayoutPhysicalRect
    }
}

/// Inserts `window` next to `target`, before or after it depending on which side of `target`'s midpoint the cursor
/// sits on. Dropping onto the master area therefore promotes the window to master and pushes the rest down
@MainActor
private func planMasterDrop(
    _ window: Window,
    onto target: Window,
    in parent: TilingContainer,
    cursor: CGPoint,
    rects: [UInt32: Rect]?,
) -> TilingDrop? {
    guard let targetRect = target.rectForDrop(rects), let targetIndex = target.ownIndex else {
        return .swap(with: target)
    }
    let axis = parent.weightOrientation
    var index = cursor.getProjection(axis) > targetRect.center.getProjection(axis) ? targetIndex + 1 : targetIndex
    let cameFromTheSameContainer = window.parent === parent
    if cameFromTheSameContainer, let sourceIndex = window.ownIndex {
        // The window is about to leave this very list, so every slot past it shifts down by one
        if index > sourceIndex { index -= 1 }
        // Landing on the near half of a neighbour resolves to the slot the window already occupies. Inserting there
        // would be a no-op, but the drop was deliberately made onto another window, so trade places with it instead
        // of quietly doing nothing -- otherwise swapping two stacked windows means dragging past the far window's
        // midpoint, which for a tall window is most of its height. Dropping a window back on its own slot is the
        // case that cancels a drag, and that is caught earlier: a window is never its own drop target
        if index == sourceIndex { return .swap(with: target) }
    }
    return .bind(
        parent: parent,
        index: index,
        // Keep the size it already had in this column. Arriving from elsewhere, take an even share
        adaptiveWeight: cameFromTheSameContainer ? window.getWeight(axis) : WEIGHT_AUTO,
    )
}

extension CGPoint {
    @MainActor
    func findWindowRecursively(
        in tree: TilingContainer,
        virtual: Bool,
        fullscreenCoversAll: Bool,
    ) -> Window? {
        if fullscreenCoversAll {
            if let window = tree.mostRecentWindowRecursive, window.isFullscreen {
                return window
            }
        }
        return _findWindowRecursively(in: tree, virtual: virtual)
    }

    @MainActor
    private func _findWindowRecursively(in tree: TilingContainer, virtual: Bool) -> Window? {
        let point = self
        let target: TreeNode? = switch tree.layout {
            case .tiles, .master:
                tree.children.first(where: {
                    (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(point) == true
                })
            case .accordion:
                tree.mostRecentChild
        }
        guard let target else { return nil }
        return switch target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): _findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
