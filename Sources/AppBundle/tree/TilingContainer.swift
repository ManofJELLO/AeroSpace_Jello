import AppKit
import Common

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    var orientation: Orientation { _orientation }
    private var _layout: Layout
    var layout: Layout {
        get { _layout }
        set(value) {
            if isDebug && lifeStatus != .alive { die("Can't change layout of not alive TilingContainer") }
            _layout =  value
        }
    }
    var lifeStatus: TilingContainerLifeStatus = .alive // todo tighten its visibility
    /// Only meaningful when ``layout`` is ``Layout/master``. See ``MasterState``
    var master: MasterState

    @MainActor
    init(
        parent: NonLeafTreeNodeObject,
        adaptiveWeight: CGFloat,
        _ orientation: Orientation,
        _ layout: Layout,
        index: Int,
        master: MasterState = MasterState(),
    ) {
        self._orientation = orientation
        self._layout = layout
        self.master = master
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor
    static func newHTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .h, .tiles, index: index)
    }

    @MainActor
    static func newVTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .v, .tiles, index: index)
    }
}

extension TilingContainer {
    /// The axis that the `adaptiveWeight` of this container's children measures.
    ///
    /// - `tiles` stacks children along its own orientation, so weight is the extent along that axis.
    /// - `master` splits its orientation axis between the master area and the stack (that split is governed by
    ///   ``MasterState/fraction``, not by weights), and stacks the children of each column along the *opposite* axis.
    ///   So for `master` the weight applies to the opposite axis, and it is a *relative share* of the column rather
    ///   than an absolute extent, so that a window keeps a sensible size when it changes column.
    /// - `accordion` doesn't use weights at all, but it reports its own orientation so that the weight of its
    ///   children stays well defined.
    @MainActor
    var weightOrientation: Orientation {
        switch layout {
            case .tiles, .accordion: orientation
            case .master: effectiveOrientation.opposite
        }
    }

    var isRootContainer: Bool { parent is Workspace }

    @MainActor
    func changeOrientation(_ targetOrientation: Orientation) {
        if orientation == targetOrientation {
            return
        }
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            for container in parentsWithSelf.filterIsInstance(of: TilingContainer.self) {
                // A master container's orientation is half of its MasterOrientation -- which edge the master area
                // sits on. Rewriting it here would send the master area across the screen rather than reorient a
                // nested container, so the walk stops at one. 'master set-orientation' owns that axis
                if container.layout == .master { break }
                container._orientation.flip()
            }
        } else {
            _orientation = targetOrientation
        }
    }

    /// Unconditionally set the orientation without propagating it to the parents.
    /// `master` containers own their orientation, it's a part of ``MasterOrientation``
    func setOrientationDirectly(_ targetOrientation: Orientation) {
        _orientation = targetOrientation
    }

    /// `parentOrientation` is the axis the parent orders its children along: its ``weightOrientation``. That differs
    /// from its orientation for a master parent, and comparing the wrong one flips a freshly joined container back
    /// onto the stacking axis, making 'join-with' inside a master area do nothing
    @MainActor
    func normalizeOppositeOrientationForNestedContainersRecursive(parentOrientation: Orientation?) {
        switch lifeStatus {
            case .deadOrInvisible: return
            // 'master' containers derive their orientation from their MasterOrientation. Flipping it here would
            // silently undo what the user asked for, so the normalization skips them (but still descends into their
            // children)
            case _ where layout == .master: break
            case .alive: _orientation = parentOrientation?.opposite ?? orientation
            case .mustBeFlattened: _orientation = parentOrientation ?? orientation
        }
        for child in children {
            (child as? TilingContainer)?.normalizeOppositeOrientationForNestedContainersRecursive(parentOrientation: weightOrientation)
        }
    }
}

enum Layout: String, Codable {
    case tiles
    case accordion
    case master
}

extension String {
    func parseLayout() -> Layout? {
        switch Layout(rawValue: self) {
            case let parsed?: parsed
            case nil where self == "list": .tiles
            case nil: nil
        }
    }
}

/// The parameters of the `master` layout. Only meaningful for ``TilingContainer``s whose ``TilingContainer/layout``
/// is ``Layout/master``, but they are kept around for other layouts too, so that toggling a container in and out of
/// `master` doesn't lose the user's tweaks.
struct MasterState: Codable, Equatable, Sendable {
    /// Which side of the container's ``TilingContainer/orientation`` axis holds the master area
    var placement: MasterPlacement = .start
    /// How many leading children form the master group. See ``TilingContainer/effectiveMasterCount``
    var count: Int = 1
    /// Share of the container's extent along its orientation axis that the master area takes. In `(0, 1)`
    var fraction: CGFloat = 0.55

    @MainActor
    static var fromConfig: MasterState {
        MasterState(
            placement: config.master.orientation.placement,
            count: config.master.count,
            fraction: config.master.fraction,
        )
    }
}

let MASTER_MIN_FRACTION: CGFloat = 0.05
let MASTER_MAX_FRACTION: CGFloat = 0.95
/// Floor for a window's share of its `master` column, so that a window can never be squeezed out of existence
let MASTER_MIN_SHARE: CGFloat = 0.05

extension TilingContainer {
    /// ``MasterState/count`` clamped to the number of children the container actually holds.
    ///
    /// When it equals `children.count` there is no stack, and every child shares the whole container.
    /// Tombstones (windows on other macOS Spaces, background native tabs) don't take a slot, so the master math is
    /// done over ``inhabitedChildren`` only
    var effectiveMasterCount: Int { master.count.coerceIn(0 ... inhabitedChildren.count) }

    var masterChildren: ArrSlice<TreeNode> {
        let inhabited = inhabitedChildren
        return inhabited.slice(0 ..< effectiveMasterCount).orDie()
    }
    var stackChildren: ArrSlice<TreeNode> {
        let inhabited = inhabitedChildren
        return inhabited.slice(effectiveMasterCount ..< inhabited.count).orDie()
    }

    /// The weight ``WEIGHT_AUTO`` resolves to for a child bound at `index`: the average of the children it will end
    /// up sharing space with, so that a new window comes out the same size as its neighbours.
    ///
    /// For a `master` container those neighbours are the other windows of the column the child joins. Averaging over
    /// all children instead would make a new stack window larger than the ones already there, because the master
    /// column divides the same extent between fewer windows
    @MainActor
    func autoWeight(forChildInsertedAt index: Int) -> CGFloat {
        let inhabited = inhabitedChildren
        let pool: [TreeNode] = if layout == .master {
            // `index` counts tombstones, the master/stack split doesn't
            (index != INDEX_BIND_LAST ? children.prefix(index).count { $0.tilingTreeNodeCasesOrDie().isInhabited } : inhabited.count) < effectiveMasterCount
                ? masterChildren.toArray()
                : stackChildren.toArray()
        } else {
            inhabited
        }
        let siblings = pool.isEmpty ? inhabited : pool
        return CGFloat(siblings.sumOfDouble { $0.getWeight(weightOrientation) }).div(siblings.count) ?? 1
    }

    /// `true` if `node` is a direct child of this container and belongs to the master group
    func isMaster(_ node: TreeNode) -> Bool {
        guard node.parent === self, let index = node.ownIndex(in: .inhabitedOnly) else { return false }
        return index < effectiveMasterCount
    }

    /// Whether `center` placement is in effect. It needs at least `master.center-stack-threshold` stack windows,
    /// mirroring Hyprland's `slave_count_for_center_master` (so `0` means "always center", even when that leaves one
    /// of the two flanking columns empty). Below the threshold the container falls back to `master.center-fallback`
    @MainActor
    var isCenterPlacementEffective: Bool {
        master.placement == .center && !masterChildren.isEmpty && stackChildren.count >= config.master.centerStackThreshold
    }

    /// The placement the layout actually applies right now
    @MainActor
    var effectivePlacement: MasterPlacement {
        master.placement == .center && !isCenterPlacementEffective
            ? config.master.centerFallback.placement
            : master.placement
    }

    /// The axis the layout actually splits along right now.
    ///
    /// This is the container's own `orientation`, except for a `center` container that has fallen back: the fallback
    /// names a whole orientation, so falling back to `top`/`bottom` flips the axis as well as the side
    @MainActor
    var effectiveOrientation: Orientation {
        layout == .master && master.placement == .center && !isCenterPlacementEffective
            ? config.master.centerFallback.axis
            : orientation
    }

    /// The configured orientation, which is what `master set-orientation` reads and writes.
    /// See ``effectiveOrientation`` for what is actually on screen
    @MainActor
    var masterOrientation: MasterOrientation { MasterOrientation(axis: orientation, placement: master.placement) }

    /// For `center` placement the stack is dealt out alternately into the two flanking columns, so that the two
    /// columns stay balanced as windows come and go.
    /// Returns the stack children that are rendered *before* the master area along the orientation axis
    var leadingStackChildren: [TreeNode] {
        stackChildren.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
    }

    /// See ``leadingStackChildren``. The stack children rendered *after* the master area
    var trailingStackChildren: [TreeNode] {
        stackChildren.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
    }

    /// Every child of a `master` container belongs to exactly one visual column/row. This returns the group that
    /// `node` is laid out in, in visual order
    @MainActor
    func masterGroup(of node: TreeNode) -> [TreeNode] {
        if isMaster(node) { return Array(masterChildren) }
        guard isCenterPlacementEffective else { return Array(stackChildren) }
        return leadingStackChildren.contains(node) ? leadingStackChildren : trailingStackChildren
    }
}
