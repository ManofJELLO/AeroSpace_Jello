import AppKit
import Common

@MainActor
private var resizeWithMouseTask: Task<(), any Error>? = nil

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let windowId = ax.containingWindowId()
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    if currentlyManipulatedWithMouseWindowId != nil {
        currentlyManipulatedWithMouseWindowId = nil
        for workspace in Workspace.all {
            workspace.resetResizeWeightBeforeResizeRecursive()
        }
        scheduleCancellableCompleteRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
    }
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")
private let masterFractionBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "masterFractionBeforeResizeWithMouseKey")

@MainActor
private func resizeWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    resetMacosFullscreenLayoutSnapshots()
    switch window.windowParentCases {
        case .unbound: return
        case .floatingWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer:
            guard let rect = try await window.getAxRect(.cancellable) else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }
            let table: [(CardinalDirection, CGFloat)] = [
                (.left,  lastAppliedLayoutRect.minX - rect.minX), // Horizontal, to the left of the window
                (.down,  rect.maxY - lastAppliedLayoutRect.maxY), // Vertical, to the down of the window
                (.up,    lastAppliedLayoutRect.minY - rect.minY), // Vertical, to the up of the window
                (.right, rect.maxX - lastAppliedLayoutRect.maxX), // Horizontal, to the right of the window
            ]
            for (direction, diff) in table {
                // 5 pixels should be enough to fight with accumulated floating precision error
                guard abs(diff) > 5, let (parent, node) = window.closestResizableParent(inDirection: direction) else { continue }
                switch parent.layout {
                    case .tiles: resizeTilesWithMouse(window, parent: parent, node: node, direction: direction, diff: diff)
                    case .master: resizeMasterWithMouse(window, parent: parent, node: node, direction: direction, diff: diff)
                    case .accordion: break // closestResizableParent never returns accordion containers
                }
            }
            currentlyManipulatedWithMouseWindowId = window.windowId
    }
}

/// Grows the dragged window by `diff` and takes that space away from everything between it and `parent`'s edge in
/// `direction`
@MainActor
private func resizeTilesWithMouse(
    _ window: Window,
    parent: TilingContainer,
    node: TreeNode,
    direction: CardinalDirection,
    diff: CGFloat,
) {
    guard let ownIndex = node.ownIndex else { return }
    let startIndex = direction.isPositive ? ownIndex + 1 : 0
    let pastTheEndIndex = direction.isPositive ? parent.children.count : ownIndex
    guard let siblingDiff = diff.div(pastTheEndIndex - startIndex) else { return }
    let orientation = parent.orientation

    window.parentsWithSelf.lazy
        .prefix(while: { $0 != parent })
        .filter {
            let parent = $0.parent as? TilingContainer
            return parent?.orientation == orientation && parent?.layout == .tiles
        }
        .forEach { $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + diff) }
    for sibling in parent.children[startIndex ..< pastTheEndIndex] {
        sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
    }
}

@MainActor
private func resizeMasterWithMouse(
    _ window: Window,
    parent: TilingContainer,
    node: TreeNode,
    direction: CardinalDirection,
    diff: CGFloat,
) {
    let orientation = direction.orientation
    if orientation == parent.weightOrientation {
        // Dragging along the stacking axis. Only the windows of the same column give up the space.
        //
        // A master column's weights are relative shares, so every window of the column is rewritten from its
        // drag-start pixel size. Touching only some of them would leave the column mixing pixel-scale and
        // share-scale weights, which would blow the ratios apart
        let group = parent.masterGroup(of: node)
        guard let indexInGroup = group.firstIndex(of: node) else { return }
        let absorbing = direction.isPositive ? Array(group[(indexInGroup + 1)...]) : Array(group[..<indexInGroup])
        guard let siblingDiff = diff.div(absorbing.count) else { return }

        let resized = group.map { sibling -> CGFloat in
            let delta: CGFloat = switch true {
                case sibling == node: diff
                case absorbing.contains(sibling): -siblingDiff
                default: 0
            }
            return sibling.getWeightBeforeResize(orientation) + delta
        }
        parent.setColumnShares(group, along: orientation, fromPixelSizes: resized)
        // Nested containers between the dragged window and the column also grow. Only 'tiles' parents, which store
        // absolute extents, are safe to nudge by a raw pixel diff
        window.parentsWithSelf.lazy
            .prefix(while: { $0 != parent })
            .filter { $0 != node }
            .filter {
                let parent = $0.parent as? TilingContainer
                return parent?.orientation == orientation && parent?.layout == .tiles
            }
            .forEach { $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + diff) }
        return
    }
    // Dragging the boundary between the master area and the stack
    guard let extent = parent.lastAppliedLayoutVirtualRect?.getDimension(orientation), extent > 0 else { return }
    let stackColumns = CGFloat(max(1, parent.orderedMasterGroups.count - 1))
    // Growing a stack column shrinks the master area. With 'center' placement the two stack columns split whatever
    // the master area leaves behind, so every pixel gained there costs the master area two
    let fractionDiff = (parent.isMaster(node) ? diff : -diff * stackColumns) / extent
    parent.master.fraction = (parent.masterFractionBeforeResize + fractionDiff)
        .coerceIn(MASTER_MIN_FRACTION ... MASTER_MAX_FRACTION)
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        let currentWeight = getWeight(orientation) // Check assertions
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        cleanUserData(key: masterFractionBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}

extension TilingContainer {
    /// `master.fraction` as it was when the drag started. Each mouse event reports the offset from the layout that was
    /// last applied, so the offsets must not accumulate
    @MainActor
    fileprivate var masterFractionBeforeResize: CGFloat {
        getUserData(key: masterFractionBeforeResizeWithMouseKey)
            ?? master.fraction.also { putUserData(key: masterFractionBeforeResizeWithMouseKey, data: $0) }
    }
}
