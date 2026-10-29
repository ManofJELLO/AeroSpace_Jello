import AppKit
import Common

enum FrozenTreeNode: Codable, Sendable {
    case container(FrozenContainer)
    case window(FrozenWindow)
}

struct FrozenContainer: Codable, Sendable {
    let children: [FrozenTreeNode]
    let layout: Layout
    let orientation: Orientation
    let weight: CGFloat
    let master: MasterState

    @MainActor init(_ container: TilingContainer) {
        children = container.children.map {
            switch $0.nodeCases {
                case .window(let w): .window(FrozenWindow(w))
                case .tilingContainer(let c): .container(FrozenContainer(c))
                case .workspace,
                     .monitor,
                     .workspacesContainer,
                     .floatingWindowsContainer,
                     .macosMinimizedWindowsContainer,
                     .macosHiddenAppsWindowsContainer,
                     .macosFullscreenWindowsContainer,
                     .macosPopupWindowsContainer:
                    illegalChildParentRelation(child: $0, parent: container)
            }
        }
        layout = container.layout
        orientation = container.orientation
        weight = getWeightOrNil(container) ?? 1
        master = container.master
    }

    private init(children: [FrozenTreeNode], layout: Layout, orientation: Orientation, weight: CGFloat, master: MasterState) {
        self.children = children
        self.layout = layout
        self.orientation = orientation
        self.weight = weight
        self.master = master
    }

    /// Rewrites every window id with `transform`, dropping the windows it returns `nil` for
    func mapWindowIds(_ transform: (OpaqueWindowId) -> OpaqueWindowId?) -> FrozenContainer {
        FrozenContainer(
            children: children.compactMap {
                switch $0 {
                    case .window(let w): transform(w.id).map { .window(FrozenWindow(id: $0, weight: w.weight)) }
                    case .container(let c): .container(c.mapWindowIds(transform))
                }
            },
            layout: layout,
            orientation: orientation,
            weight: weight,
            master: master,
        )
    }
}

struct FrozenWindow: Codable, Sendable {
    let id: OpaqueWindowId
    let weight: CGFloat

    @MainActor init(_ window: Window) {
        id = window.windowId
        weight = getWeightOrNil(window) ?? 1
    }

    fileprivate init(id: OpaqueWindowId, weight: CGFloat) {
        self.id = id
        self.weight = weight
    }
}

@MainActor private func getWeightOrNil(_ node: TreeNode) -> CGFloat? {
    ((node.parent as? TilingContainer)?.weightOrientation).map { node.getWeight($0) }
}
