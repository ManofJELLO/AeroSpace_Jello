import AppKit
import Common

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws {
        if isEffectivelyEmpty { return }
        let rect = workspaceMonitor.visibleRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height - 1, virtual: rect, LayoutContext(self))
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                try await workspace.rootTilingContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                for window in container.children.filterIsInstance(of: Window.self) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    try await window.layoutFloatingWindow(context)
                }
            case .window(let window):
                if window.windowId != currentlyManipulatedWithMouseWindowId {
                    lastAppliedLayoutVirtualRect = virtual
                    if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                        lastAppliedLayoutPhysicalRect = nil
                        window.layoutFullscreen(context)
                    } else {
                        lastAppliedLayoutPhysicalRect = physicalRect
                        window.isFullscreen = false
                        window.setAxFrame(point, CGSize(width: width, height: height))
                    }
                }
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                switch container.layout {
                    case .tiles:
                        try await container.layoutTiles(point, width: width, height: height, virtual: virtual, context)
                    case .accordion:
                        try await container.layoutAccordion(point, width: width, height: height, virtual: virtual, context)
                    case .master:
                        try await container.layoutMaster(point, width: width, height: height, virtual: virtual, context)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let resolvedGaps: ResolvedGaps

    @MainActor
    init(_ workspace: Workspace) {
        self.workspace = workspace
        self.resolvedGaps = ResolvedGaps(gaps: config.gaps, monitor: workspace.workspaceMonitor)
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext) async throws {
        let workspace = context.workspace
        let windowRect = try await getAxRect(.cancellable) // Probably not idempotent
        let currentMonitor = windowRect?.center.monitorApproximation
        if let currentMonitor, let windowRect, workspace != currentMonitor.activeWorkspace {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitor.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let monitorRect = noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitor.visibleRect
            : context.workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        setAxFrame(monitorRect.topLeftCorner, CGSize(width: monitorRect.width, height: monitorRect.height))
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutTiles(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        try await layoutSequentially(children, along: orientation, point, width: width, height: height, virtual: virtual, context)
    }

    @MainActor
    fileprivate func layoutAccordion(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        guard let mruIndex: Int = mostRecentChild?.ownIndex else { return }
        for (index, child) in children.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where children.count == 1: (0, 0)
                case 0:                           (0, padding)
                case children.indices.last:       (padding, 0)
                case mruIndex - 1:                (0, 2 * padding)
                case mruIndex + 1:                (2 * padding, 0)
                default:                          (padding, padding)
            }
            switch orientation {
                case .h:
                    try await child.layoutRecursive(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                    )
                case .v:
                    try await child.layoutRecursive(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                    )
            }
        }
    }
}

/// Lays `nodes` out one after another along `orientation`, dividing the available extent between them proportionally
/// to their weights, and inserting inner gaps in between.
///
/// This is the workhorse of both the `tiles` layout (called once with all children) and the `master` layout
/// (called once per column/row group).
@MainActor
private func layoutSequentially(
    _ nodes: [TreeNode],
    along orientation: Orientation,
    _ point: CGPoint,
    width: CGFloat,
    height: CGFloat,
    virtual: Rect,
    _ context: LayoutContext,
) async throws {
    var point = point
    var virtualPoint = virtual.topLeftCorner

    guard let delta = ((orientation == .h ? width : height) - CGFloat(nodes.sumOfDouble { $0.getWeight(orientation) }))
        .div(nodes.count) else { return }

    let lastIndex = nodes.indices.last
    for (i, child) in nodes.enumerated() {
        child.setWeight(orientation, child.getWeight(orientation) + delta)
        let weight = child.getWeight(orientation)
        let rawGap = context.resolvedGaps.inner.get(orientation).toDouble()
        // Gaps. Consider 4 cases:
        // 1. Multiple children. Layout first child
        // 2. Multiple children. Layout last child
        // 3. Multiple children. Layout child in the middle
        // 4. Single child
        let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
        try await child.layoutRecursive(
            i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
            width: orientation == .h ? weight - gap : width,
            height: orientation == .v ? weight - gap : height,
            virtual: Rect(
                topLeftX: virtualPoint.x,
                topLeftY: virtualPoint.y,
                width: orientation == .h ? weight : width,
                height: orientation == .v ? weight : height,
            ),
            context,
        )
        virtualPoint = orientation == .h ? virtualPoint.addingXOffset(weight) : virtualPoint.addingYOffset(weight)
        point = orientation == .h ? point.addingXOffset(weight) : point.addingYOffset(weight)
    }
}

/// One column (for `.h` orientation) or row (for `.v`) of a `master` container
private struct MasterSlot {
    let nodes: [TreeNode]
    /// Offset from the container's top left corner along the container's orientation axis
    let physicalOffset: CGFloat
    let physicalExtent: CGFloat
    let virtualOffset: CGFloat
    let virtualExtent: CGFloat
}

extension TilingContainer {
    @MainActor
    fileprivate func layoutMaster(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let axis = effectiveOrientation
        let physicalExtent = axis == .h ? width : height
        let virtualExtent = virtual.getDimension(axis)
        let gap = context.resolvedGaps.inner.get(axis).toDouble()

        for slot in masterSlots(physicalExtent: physicalExtent, virtualExtent: virtualExtent, gap: gap) {
            let slotVirtual = Rect(
                topLeftX: axis == .h ? virtual.topLeftX + slot.virtualOffset : virtual.topLeftX,
                topLeftY: axis == .v ? virtual.topLeftY + slot.virtualOffset : virtual.topLeftY,
                width: axis == .h ? slot.virtualExtent : virtual.width,
                height: axis == .v ? slot.virtualExtent : virtual.height,
            )
            try await layoutSequentially(
                slot.nodes,
                along: axis.opposite,
                point.addingOffset(axis, slot.physicalOffset),
                width: axis == .h ? slot.physicalExtent : width,
                height: axis == .v ? slot.physicalExtent : height,
                virtual: slotVirtual,
                context,
            )
        }
    }

    /// Splits the container's extent along its orientation axis between the columns of ``orderedMasterGroups``.
    ///
    /// The master area takes ``MasterState/fraction`` of the space, and the remaining column(s) share what is left.
    /// How each column then divides its own slot among its windows is left to ``layoutSequentially``, which uses the
    /// per-window weights.
    @MainActor
    private func masterSlots(physicalExtent: CGFloat, virtualExtent: CGFloat, gap: CGFloat) -> [MasterSlot] {
        let groups = orderedMasterGroups
        if groups.isEmpty { return [] }
        // Only one column is populated: it owns the whole container and there is nothing to split
        if groups.count == 1 {
            return [MasterSlot(
                nodes: groups[0].nodes,
                physicalOffset: 0,
                physicalExtent: physicalExtent,
                virtualOffset: 0,
                virtualExtent: virtualExtent,
            )]
        }
        let fraction = master.fraction.coerceIn(MASTER_MIN_FRACTION ... MASTER_MAX_FRACTION)
        let stackColumns = CGFloat(groups.count - 1)
        let physicalAvailable = max(0, physicalExtent - stackColumns * gap)
        let physicalMaster = physicalAvailable * fraction
        let physicalStack = (physicalAvailable - physicalMaster) / stackColumns
        let virtualMaster = virtualExtent * fraction
        let virtualStack = (virtualExtent - virtualMaster) / stackColumns

        var slots: [MasterSlot] = []
        var physicalOffset: CGFloat = 0
        var virtualOffset: CGFloat = 0
        for group in groups {
            let physical = group.isMasterArea ? physicalMaster : physicalStack
            let virtual = group.isMasterArea ? virtualMaster : virtualStack
            slots.append(MasterSlot(
                nodes: group.nodes,
                physicalOffset: physicalOffset,
                physicalExtent: physical,
                virtualOffset: virtualOffset,
                virtualExtent: virtual,
            ))
            physicalOffset += physical + gap
            virtualOffset += virtual
        }
        return slots
    }
}
