import AppKit
import Common

struct JoinWithCommand: Command {
    let args: JoinWithCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let direction = args.direction.val
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let currentWindow = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        guard let joinWithTarget = currentWindow.closestTilingNeighbour(inDirection: direction) else {
            return .fail(io.err("No windows in the specified direction"))
        }
        guard let parent = joinWithTarget.parent as? TilingContainer else { return .fail(io.err(bugPrompt())) }
        let prevBinding = joinWithTarget.unbindFromParent()
        let newParent = TilingContainer(
            parent: parent,
            adaptiveWeight: prevBinding.adaptiveWeight,
            // Perpendicular to the axis the parent orders its children along, so the two joined windows split the slot
            parent.weightOrientation.opposite,
            .tiles,
            index: prevBinding.index,
        )
        currentWindow.unbindFromParent()

        joinWithTarget.bind(to: newParent, adaptiveWeight: WEIGHT_AUTO, index: 0)
        currentWindow.bind(to: newParent, adaptiveWeight: WEIGHT_AUTO, index: direction.isPositive ? 0 : INDEX_BIND_LAST)
        return .succ
    }
}
