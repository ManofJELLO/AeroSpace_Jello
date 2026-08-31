import AppKit
import Common

/// Preserves the workspace tiling layout across macOS native fullscreen.
///
/// Entering macOS native fullscreen unbinds the window from its tiling container. Because weights are absolute
/// point sizes that `layoutTiles` rewrites on every pass, the siblings' sizes are permanently changed, and
/// container flattening may delete the parent container outright. So the whole tiling tree is snapshotted on the
/// way in and rebuilt on the way out.
struct MacosFullscreenLayoutSnapshot {
    let workspaceName: String
    let rootTilingNode: FrozenContainer
}

@MainActor private var snapshots: [UInt32: MacosFullscreenLayoutSnapshot] = [:]

/// Moves the window into the workspace's macOS-native-fullscreen container, remembering both where it came from
/// and what the workspace looked like, so that the layout can be restored on exit.
///
/// The `layoutReason` assignment is what makes `exitMacOsNativeUnconventionalState` take the `.tilingContainer`
/// branch later. `MacosNativeFullscreenCommand` used to skip it, which left `prevParentKind` recorded as
/// `.macosFullscreenWindowsContainer` by the next normalization pass.
@MainActor
func enterMacosNativeFullscreen(window: Window, workspace: Workspace, adaptiveWeight: CGFloat) {
    if config.preserveLayoutOnMacosNativeFullscreen && window.parent is TilingContainer {
        snapshots[window.windowId] = MacosFullscreenLayoutSnapshot(
            workspaceName: workspace.name,
            rootTilingNode: FrozenContainer(workspace.rootTilingContainer),
        )
    }
    if case .standard = window.layoutReason, let parent = window.parent {
        window.layoutReason = .macos(prevParentKind: parent.kind)
    }
    window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
}

/// Returns `true` if the layout was restored. Callers fall back to `relayoutWindow` when it returns `false`.
@MainActor
func restoreMacosFullscreenLayout(window: Window, workspace: Workspace, _ cm: CancellationMode) async throws -> Bool {
    guard config.preserveLayoutOnMacosNativeFullscreen else { return false }
    guard let snapshot = snapshots.removeValue(forKey: window.windowId) else { return false }
    guard snapshot.workspaceName == workspace.name else { return false }

    // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
    let prevRoot = workspace.rootTilingContainer
    let potentialOrphans = prevRoot.allLeafWindowsRecursive + [window]
    // Deliberately unbind prevRoot only *after* rebuilding the new tree, not before. `restoreTreeRecursive` looks
    // windows up by id via `MacWindow.get(byId:)`, which under `isUnitTest` finds a window only by walking down
    // from `Workspace.all` - i.e. only windows still reachable from some workspace's tree. Every window that is
    // still genuinely part of the old layout (not itself off in a macOS unconventional state) is, at this point,
    // still a descendant of prevRoot, so prevRoot must stay attached to the workspace while those lookups happen.
    // `restoreTreeRecursive` unbinds each window from prevRoot as it re-binds it into the new tree. Any window still
    // under prevRoot by the time we detach it below is, by construction, not in the snapshot - it's picked up by the
    // orphan loop below instead.
    restoreTreeRecursive(
        frozenContainer: snapshot.rootTilingNode,
        parent: workspace,
        index: INDEX_BIND_LAST,
        skipUnrestorableWindows: true,
    )
    prevRoot.unbindFromParent()

    // Windows that appeared while the app was fullscreen aren't in the snapshot. Tile them rather than drop them.
    for orphan in potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive {
        try await orphan.relayoutWindow(on: workspace, cm, forceTile: true)
    }
    window.markAsMostRecentChild()
    return true
}

@MainActor
func dropMacosFullscreenLayoutSnapshot(windowId: UInt32) {
    snapshots.removeValue(forKey: windowId)
}

/// Any other change to the layout makes every snapshot stale. Called from the same places as
/// ``resetClosedWindowsCache()``.
@MainActor
func resetMacosFullscreenLayoutSnapshots() {
    snapshots = [:]
}
