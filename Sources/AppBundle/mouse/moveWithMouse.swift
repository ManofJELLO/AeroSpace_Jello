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
        moveWithMouseTask?.cancel()
        moveWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
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

/// `cursor` is a parameter rather than read from ``mouseLocation`` so that the drop logic can be tested
@MainActor
func moveTilingWindow(_ window: Window, cursor: CGPoint) {
    currentlyManipulatedWithMouseWindowId = window.windowId
    window.lastAppliedLayoutPhysicalRect = nil
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
        window.bind(
            to: dropTarget?.parent ?? targetWorkspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: index,
        )
    } else if let dropTarget {
        // A 'master' container is an ordered list of slots rather than a spatial tree, so dropping into one inserts
        // the window at the cursor and shifts the rest along, the way Hyprland's 'drop_at_cursor' does. Every other
        // layout keeps AeroSpace's "swap with the window underneath" behavior
        if let masterParent = (dropTarget.parent as? TilingContainer)?.takeIf({ $0.layout == .master }) {
            dropIntoMasterContainer(window, onto: dropTarget, in: masterParent, cursor: cursor)
        } else {
            swapTreeNodes(mruDominant: window, dropTarget)
        }
    }
}

/// Inserts `window` next to `target`, before or after it depending on which side of `target`'s midpoint the cursor
/// sits on. Dropping onto the master area therefore promotes the window to master and pushes the rest down
@MainActor
private func dropIntoMasterContainer(_ window: Window, onto target: Window, in parent: TilingContainer, cursor: CGPoint) {
    guard let targetRect = target.lastAppliedLayoutPhysicalRect, let targetIndex = target.ownIndex else {
        swapTreeNodes(mruDominant: window, target)
        return
    }
    let axis = parent.weightOrientation
    var index = cursor.getProjection(axis) > targetRect.center.getProjection(axis) ? targetIndex + 1 : targetIndex
    let cameFromTheSameContainer = window.parent === parent
    if cameFromTheSameContainer, let sourceIndex = window.ownIndex {
        // The window is about to leave this very list, so every slot past it shifts down by one
        if index > sourceIndex { index -= 1 }
        // Already where it would land. Bailing out keeps the drag from thrashing the layout every mouse event
        if index == sourceIndex { return }
    }
    let binding = window.unbindFromParent()
    window.bind(
        to: parent,
        adaptiveWeight: cameFromTheSameContainer ? binding.adaptiveWeight : WEIGHT_AUTO,
        index: index,
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
