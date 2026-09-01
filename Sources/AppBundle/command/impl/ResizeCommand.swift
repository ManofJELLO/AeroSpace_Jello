import AppKit
import Common

struct ResizeCommand: Command {
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        // Nodes whose parent divides its space between its children. 'accordion' doesn't, its children all get the
        // full container
        let candidates = target.windowOrNil?.parentsWithSelf
            .filter {
                switch ($0.parent as? TilingContainer)?.layout {
                    case .tiles, .master: true
                    case .accordion, nil: false
                }
            }
            ?? []

        // A 'tiles' container only distributes space along its own orientation. A 'master' container distributes both
        // axes: the master/stack split along its orientation, and the window sizes within a column along the other
        func candidate(along orientation: Orientation) -> TreeNode? {
            candidates.first {
                switch ($0.parent as? TilingContainer)?.layout {
                    case .master: true
                    case .tiles: ($0.parent as? TilingContainer)?.orientation == orientation
                    case .accordion, nil: false
                }
            }
        }

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidate(along: .h)
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidate(along: .v)
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.effectiveOrientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.effectiveOrientation.opposite
                node = orientation.flatMap(candidate(along:))
                parent = node?.parent as? TilingContainer
        }
        guard let parent else {
            return .fail(io.err("resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9"))
        }
        guard let orientation else { return .fail }
        guard let node else { return .fail }

        if parent.layout == .master {
            return resizeMaster(io, node: node, parent: parent, orientation: orientation, units: args.units.val)
        }

        let diff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        guard let childDiff = diff.div(parent.children.count - 1) else { return .fail }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return .succ
    }
}

@MainActor private func resizeMaster(
    _ io: CmdIo,
    node: TreeNode,
    parent: TilingContainer,
    orientation: Orientation,
    units: ResizeCmdArgs.Units,
) -> BinaryExitCode {
    if orientation == parent.weightOrientation {
        // Resizing along the stacking axis. Only the windows of the same column give up the space, the other column
        // is normalized independently and wouldn't notice the change anyway
        let group = parent.masterGroup(of: node)
        let diff: CGFloat = switch units {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }
        guard let siblingDiff = diff.div(group.count - 1) else {
            return .fail(io.err("The window is the only one in its column, there is nothing to resize it against"))
        }
        for sibling in group where sibling != node {
            sibling.setWeight(orientation, sibling.getWeight(orientation) - siblingDiff)
        }
        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return .succ
    }

    // Resizing along the master/stack axis, which means moving the boundary between the two areas
    let columns = parent.orderedMasterGroups.count
    guard columns > 1 else {
        return .fail(io.err("The master container has no stack to resize the master area against"))
    }
    guard let extent = parent.lastAppliedLayoutVirtualRect?.getDimension(orientation), extent > 0 else {
        return .fail(io.err("Can't resize the master area before the workspace has been laid out at least once"))
    }
    // With 'center' placement the two stack columns split whatever the master area leaves behind
    let stackColumns = CGFloat(columns - 1)
    let isMasterArea = parent.isMaster(node)
    let currentPixels = (isMasterArea ? parent.master.fraction : (1 - parent.master.fraction) / stackColumns) * extent
    let targetPixels: CGFloat = switch units {
        case .set(let unit): CGFloat(unit)
        case .add(let unit): currentPixels + CGFloat(unit)
        case .subtract(let unit): currentPixels - CGFloat(unit)
    }
    let fraction = isMasterArea
        ? targetPixels / extent
        : 1 - (targetPixels * stackColumns) / extent
    parent.master.fraction = fraction.coerceIn(MASTER_MIN_FRACTION ... MASTER_MAX_FRACTION)
    return .succ
}
