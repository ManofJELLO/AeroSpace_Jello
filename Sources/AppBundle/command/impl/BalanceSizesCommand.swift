import AppKit
import Common
import Foundation

struct BalanceSizesCommand: Command {
    let args: BalanceSizesCmdArgs
    // Doesn't change the tree, so a window closed just before this still belongs in its old slot when it reopens.
    // It does rewrite the weights that a fullscreen snapshot captured, so that snapshot has to go
    /*conforms*/ let shouldResetClosedWindowsCache = false
    /*conforms*/ let shouldResetMacosFullscreenSnapshots = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        balance(target.workspace.rootTilingContainer)
        return .succ
    }
}

@MainActor
private func balance(_ parent: TilingContainer) {
    for child in parent.children {
        switch parent.layout {
            // For 'master' this evens out the windows within the master area and within the stack. The split between
            // the two areas is governed by 'master.fraction', not by weights, so it is left untouched
            case .tiles, .master: child.setWeight(parent.weightOrientation, 1)
            case .accordion: break // Do nothing
        }
        if let child = child as? TilingContainer {
            balance(child)
        }
    }
}
