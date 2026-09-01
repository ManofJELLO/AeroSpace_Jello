import AppKit
import Common

@MainActor
private var moveWithMouseTask: Task<(), any Error>? = nil

func movedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    let notif = notif as String
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
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
            moveTilingWindow(window, cursor: mouseLocation)
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
            return planTilingDrop(window, cursor: mouseLocation) != nil
        case .floatingWindowsContainer, .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer, .unbound:
            return true
    }
}

/// What a drop at `cursor` would do to the tree, or `nil` if it would leave it untouched
private enum TilingDrop {
    case bind(parent: NonLeafTreeNodeObject, index: Int, adaptiveWeight: CGFloat)
    case swap(with: Window)
}

/// `cursor` is a parameter rather than read from ``mouseLocation`` so that the drop logic can be tested
@MainActor
func moveTilingWindow(_ window: Window, cursor: CGPoint) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
    switch planTilingDrop(window, cursor: cursor) {
        case nil: return
        case .bind(let parent, let index, let adaptiveWeight):
            window.bind(to: parent, adaptiveWeight: adaptiveWeight, index: index)
        case .swap(let target):
            swapTreeNodes(mruDominant: window, target)
    }
}

@MainActor
private func planTilingDrop(_ window: Window, cursor: CGPoint) -> TilingDrop? {
    let targetWorkspace = cursor.monitorApproximation.activeWorkspace
    let dropTarget = cursor
        .findWindowRecursively(in: targetWorkspace.rootTilingContainer, virtual: false, fullscreenCoversAll: false)?
        .takeIf { $0 != window }
    if targetWorkspace != window.nodeWorkspace { // Move window to a different monitor
        let index: Int = if let dropTarget, let parent = dropTarget.parent as? TilingContainer, let targetRect = dropTarget.lastAppliedLayoutPhysicalRect {
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
    return planMasterDrop(window, onto: dropTarget, in: masterParent, cursor: cursor)
}

/// Inserts `window` next to `target`, before or after it depending on which side of `target`'s midpoint the cursor
/// sits on. Dropping onto the master area therefore promotes the window to master and pushes the rest down
@MainActor
private func planMasterDrop(_ window: Window, onto target: Window, in parent: TilingContainer, cursor: CGPoint) -> TilingDrop? {
    guard let targetRect = target.lastAppliedLayoutPhysicalRect, let targetIndex = target.ownIndex else {
        return .swap(with: target)
    }
    let axis = parent.weightOrientation
    var index = cursor.getProjection(axis) > targetRect.center.getProjection(axis) ? targetIndex + 1 : targetIndex
    let cameFromTheSameContainer = window.parent === parent
    if cameFromTheSameContainer, let sourceIndex = window.ownIndex {
        // The window is about to leave this very list, so every slot past it shifts down by one
        if index > sourceIndex { index -= 1 }
        // Already where it would land, so there is nothing to do and no session to pay for
        if index == sourceIndex { return nil }
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
