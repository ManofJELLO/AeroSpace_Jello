import AppKit
import Common

/// How a window crossing between the master area and the stack picks its counterpart
enum MasterCrossColumnPolicy {
    /// The most recently focused window of the target column. Focus uses this, the same way focus into a
    /// perpendicular `tiles` container follows the MRU
    case mostRecent
    /// The window at the same position within the target column, clamped to its last window. Moving a window uses
    /// this, so that repeating the command doesn't shuffle the layout unpredictably
    case sameRow
}

/// One column (for `.h` orientation) or one row (for `.v`) of a `master` container, in visual order along the
/// container's orientation axis
struct MasterGroup {
    let nodes: [TreeNode]
    let isMasterArea: Bool
}

extension TilingContainer {
    /// The visual grouping of this `master` container's children, ordered along the container's orientation axis.
    ///
    /// This is the single source of truth shared by the layout math and by directional focus/move, so that "the
    /// window to the right" always means the same thing as "the column drawn to the right".
    ///
    /// - Two groups for `start`/`end` placement, three for an effective `center` placement, and one when either the
    ///   master area or the stack is empty (then the populated group owns the whole container).
    @MainActor
    var orderedMasterGroups: [MasterGroup] {
        let masters = masterChildren.toArray()
        let stack = stackChildren.toArray()
        if children.isEmpty { return [] }
        // Checked before the "single populated group" shortcut below: an effective `center` keeps all three columns
        // even when one of them is empty, so the master area stays centred. That is also what Hyprland does once
        // `slave_count_for_center_master` is low enough to let a single stack window through
        if isCenterPlacementEffective {
            return [
                MasterGroup(nodes: leadingStackChildren, isMasterArea: false),
                MasterGroup(nodes: masters, isMasterArea: true),
                MasterGroup(nodes: trailingStackChildren, isMasterArea: false),
            ]
        }
        if masters.isEmpty || stack.isEmpty {
            return [MasterGroup(nodes: children, isMasterArea: !masters.isEmpty)]
        }
        let masterGroup = MasterGroup(nodes: masters, isMasterArea: true)
        let stackGroup = MasterGroup(nodes: stack, isMasterArea: false)
        return effectivePlacement == .end ? [stackGroup, masterGroup] : [masterGroup, stackGroup]
    }

    /// The child of this `master` container that sits next to `child` in `direction`, or `nil` when `child` already
    /// sits at the container's edge in that direction.
    ///
    /// Along the stacking axis (the axis opposite to the container orientation) that is the next window *within the
    /// same column*. Along the orientation axis it is a window of the neighbouring column, which is how a window
    /// crosses between the master area and the stack. Which one is picked depends on `crossColumn`
    @MainActor
    func masterNeighbour(
        of child: TreeNode,
        inDirection direction: CardinalDirection,
        crossColumn: MasterCrossColumnPolicy = .mostRecent,
    ) -> TreeNode? {
        check(layout == .master)
        let groups = orderedMasterGroups
        guard let groupIndex = groups.firstIndex(where: { $0.nodes.contains(child) }) else { return nil }
        if direction.orientation == effectiveOrientation.opposite {
            let nodes = groups[groupIndex].nodes
            guard let indexInGroup = nodes.firstIndex(of: child) else { return nil }
            return nodes.getOrNil(atIndex: indexInGroup + direction.focusOffset)
        }
        let targetGroup = groupIndex + direction.focusOffset
        guard groups.indices.contains(targetGroup) else { return nil }
        let target = groups[targetGroup].nodes
        switch crossColumn {
            case .mostRecent:
                return mruChild(among: target)
            case .sameRow:
                let indexInGroup = groups[groupIndex].nodes.firstIndex(of: child) ?? 0
                return target.getOrNil(atIndex: indexInGroup) ?? target.last
        }
    }

    /// The most recently focused of `nodes`, falling back to the first one
    @MainActor
    func mruChild(among nodes: [TreeNode]) -> TreeNode? {
        mruChildren.first(where: { nodes.contains($0) }) ?? nodes.first
    }
}

extension TilingContainer {
    /// Where `master.new-window-position` says a newly detected window should be inserted
    @MainActor
    func newWindowIndex(afterFocused mruWindow: Window) -> Int {
        switch config.master.newWindowPosition {
            // Index 0 is the first master slot: the new window takes over the master area, and the window that used
            // to be there is pushed to the top of the stack
            case .master: 0
            case .stackStart: effectiveMasterCount
            case .stackEnd: children.count
            case .afterFocused: (mruWindow.ownIndex ?? children.count - 1) + 1
        }
    }
}

extension TreeNode {
    /// The node that `self` is adjacent to in `direction`, searching upward through the tiling tree until a container
    /// that can express the move is found.
    ///
    /// Replaces walking `closestParent(hasChildrenInDirection:)` and indexing into `children` by hand: in a `master`
    /// container the neighbour is not simply the sibling at index ±1
    @MainActor
    func closestTilingNeighbour(inDirection direction: CardinalDirection) -> TreeNode? {
        for node in parentsWithSelf {
            switch node.parent?.cases {
                case .tilingContainer(let parent):
                    if let neighbour = parent.directNeighbour(of: node, inDirection: direction) {
                        return neighbour
                    }
                // Stop searching. We hit the top of the tiling tree, or something that isn't tiled at all
                case .workspace, nil, .macosMinimizedWindowsContainer, .floatingWindowsContainer,
                     .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer:
                    return nil
            }
        }
        return nil
    }
}

extension TilingContainer {
    /// The direct child of this container adjacent to `child` in `direction`, or `nil` if there is none
    @MainActor
    func directNeighbour(of child: TreeNode, inDirection direction: CardinalDirection) -> TreeNode? {
        switch layout {
            case .master:
                return masterNeighbour(of: child, inDirection: direction)
            case .tiles, .accordion:
                guard orientation == direction.orientation, let index = child.ownIndex else { return nil }
                return children.getOrNil(atIndex: index + direction.focusOffset)
        }
    }
}

extension TreeNode {
    /// The innermost ancestor container that can absorb a resize in `direction`, together with the child of that
    /// container that `self` lives in.
    ///
    /// `accordion` containers are skipped: they overlap their children instead of distributing size between them
    @MainActor
    func closestResizableParent(inDirection direction: CardinalDirection) -> (parent: TilingContainer, node: TreeNode)? {
        for node in parentsWithSelf {
            switch node.parent?.cases {
                case .tilingContainer(let parent):
                    if parent.layout != .accordion, parent.directNeighbour(of: node, inDirection: direction) != nil {
                        return (parent, node)
                    }
                // Stop searching. We hit the top of the tiling tree, or something that isn't tiled at all
                case .workspace, nil, .macosMinimizedWindowsContainer, .floatingWindowsContainer,
                     .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer:
                    return nil
            }
        }
        return nil
    }
}

/// Exchanges the positions of two nodes. Weights stay with the slot, not with the node, so the windows keep the sizes
/// that were on screen before the swap.
///
/// `mruDominant` ends up as the most recently used of the two
@MainActor
func swapTreeNodes(mruDominant node1: TreeNode, _ node2: TreeNode) {
    if node1 == node2 { return }

    let binding2 = node2.unbindFromParent()
    let binding1 = node1.unbindFromParent()

    node2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    node1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
}
