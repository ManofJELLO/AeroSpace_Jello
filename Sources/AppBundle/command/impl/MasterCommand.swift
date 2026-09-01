import AppKit
import Common

struct MasterCommand: Command {
    let args: MasterCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let container = resolveMasterContainer(target) else {
            let msg = "The focused window is not in a 'master' container. " +
                "Tip: run 'aerospace layout master', or set default-root-container-layout = 'master'"
            return .fail(io.err(msg))
        }
        // The direct child of the master container that the focused window lives in. It's the window itself unless
        // the window sits inside a nested container
        let node = target.windowOrNil?.parentsWithSelf.first { $0.parent === container }

        switch args.action.val {
            case .swapWithMaster:
                guard let node else { return .fail(io.err(noWindowIsFocused)) }
                guard let counterpart = container.counterpartGroupMru(of: node) else {
                    return .fail(io.err("There is no window outside of the master area to swap with"))
                }
                swapTreeNodes(mruDominant: node, counterpart)
                return .succ
            case .focusMaster:
                guard let node else { return .fail(io.err(noWindowIsFocused)) }
                // Toggle: jump into the master area, or back out to where you came from
                guard let counterpart = container.counterpartGroupMru(of: node) else {
                    return .fail(io.err("There is no window outside of the master area to focus"))
                }
                guard let windowToFocus = counterpart.mostRecentWindowRecursive else { return .fail(io.err(bugPrompt())) }
                return .from(bool: windowToFocus.focusWindow())
            case .rotateNext:
                return container.rotate(offset: 1, io)
            case .rotatePrev:
                return container.rotate(offset: -1, io)
            case .addMaster:
                return container.setMasterCount(container.master.count + 1, io)
            case .removeMaster:
                return container.setMasterCount(container.master.count - 1, io)
            case .setCount(let units):
                return container.setMasterCount(units.apply(to: container.master.count), io)
            case .setFraction(let units):
                let percent = units.apply(to: Int((container.master.fraction * 100).rounded()))
                container.master.fraction = (CGFloat(percent) / 100)
                    .coerceIn(MASTER_MIN_FRACTION ... MASTER_MAX_FRACTION)
                return .succ
            case .setOrientation(let orientationTarget):
                let orientation = container.resolve(orientationTarget)
                container.master.placement = orientation.placement
                container.setOrientationDirectly(orientation.axis)
                return .succ
        }
    }
}

/// The innermost `master` container the focused window lives in, or the workspace root when it is one
@MainActor private func resolveMasterContainer(_ target: LiveFocus) -> TilingContainer? {
    if let found = target.windowOrNil?.parents
        .filterIsInstance(of: TilingContainer.self)
        .first(where: { $0.layout == .master })
    {
        return found
    }
    let root = target.workspace.rootTilingContainer
    return root.layout == .master ? root : nil
}

extension MasterCmdArgs.Units {
    fileprivate func apply(to current: Int) -> Int {
        switch self {
            case .set(let value): value
            case .add(let value): current + value
            case .subtract(let value): current - value
        }
    }
}

extension TilingContainer {
    /// The most recently focused window of "the other side": the master area for a stack window, and the stack for a
    /// master window. This is what makes `swap-with-master` and `focus-master` toggle
    @MainActor
    fileprivate func counterpartGroupMru(of node: TreeNode) -> TreeNode? {
        let counterpart = isMaster(node) ? stackChildren.toArray() : masterChildren.toArray()
        return mruChild(among: counterpart)
    }

    @MainActor
    fileprivate func setMasterCount(_ count: Int, _ io: CmdIo) -> BinaryExitCode {
        let clamped = count.coerceIn(1 ... max(1, children.count))
        if clamped == master.count {
            return .succ(io.err("Master count is already \(clamped)"))
        }
        master.count = clamped
        return .succ
    }

    /// Shifts every child `offset` slots (wrapping around), so a different window ends up in the master area.
    /// The slots keep their sizes, only their occupants change.
    ///
    /// Focus lands on the master area rather than following the window that just moved out of it, so repeating the
    /// command flips through the windows in the master spot. That matches Hyprland's `rollnext`/`rollprev`
    @MainActor
    fileprivate func rotate(offset: Int, _ io: CmdIo) -> BinaryExitCode {
        let nodes = children
        let count = nodes.count
        if count < 2 {
            return .fail(io.err("Nothing to rotate. The master container holds fewer than two windows"))
        }
        let weights = nodes.map { $0.getWeight(weightOrientation) }
        for node in nodes { node.unbindFromParent() }
        for slot in 0 ..< count {
            let node = nodes[((slot + offset) % count + count) % count]
            node.bind(to: self, adaptiveWeight: weights[slot], index: slot)
        }
        guard let windowToFocus = masterChildren.first?.mostRecentWindowRecursive else {
            return .fail(io.err(bugPrompt()))
        }
        return .from(bool: windowToFocus.focusWindow())
    }

    @MainActor
    fileprivate func resolve(_ target: MasterCmdArgs.OrientationTarget) -> MasterOrientation {
        let cycle = MasterOrientation.cycle
        switch target {
            case .exact(let orientation):
                return orientation
            case .next, .prev:
                let offset = target == .next ? 1 : -1
                let index = cycle.firstIndex(of: masterOrientation) ?? 0
                return cycle[(index + offset + cycle.count) % cycle.count]
        }
    }
}
