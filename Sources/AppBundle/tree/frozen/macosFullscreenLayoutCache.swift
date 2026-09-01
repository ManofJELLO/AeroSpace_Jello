import AppKit
import Common

/// Preserves the workspace tiling layout across macOS native fullscreen.
///
/// Entering macOS native fullscreen unbinds the window from its tiling container. Because weights are absolute
/// point sizes that `layoutTiles` rewrites on every pass, the siblings' sizes are permanently changed, and
/// container flattening may delete the parent container outright. So the whole tiling tree is snapshotted on the
/// way in and rebuilt on the way out.
struct MacosFullscreenLayoutSnapshot: Sendable {
    let workspaceName: String
    let rootTilingNode: FrozenContainer
    /// The workspace's tiling windows at the moment of entering fullscreen, most-recent-first. Replayed in reverse
    /// on the way out (see `restoreMacosFullscreenLayout`) so that every ancestor container's MRU stack ends up in
    /// its original relative order, instead of collapsing to document order the way a freshly-rebuilt tree would.
    let mruWindowIds: [UInt32]
}

@MainActor private var snapshots: [UInt32: MacosFullscreenLayoutSnapshot] = [:]

extension TreeNode {
    /// Leaf windows in most-recent-first order, obtained by walking `mruChildren` (not `children`) at every level.
    var mruOrderedLeafWindowsRecursive: [Window] {
        if let window = self as? Window { return [window] }
        return mruChildren.flatMap { $0.mruOrderedLeafWindowsRecursive }
    }
}

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
            mruWindowIds: workspace.rootTilingContainer.mruOrderedLeafWindowsRecursive.map(\.windowId),
        )
    }
    if case .standard = window.layoutReason, let parent = window.parent {
        window.layoutReason = .macos(prevParentKind: parent.kind)
    }
    window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
}

/// Returns `true` if the layout was restored. Callers fall back to `relayoutWindow` when it returns `false`.
///
/// Contract: the caller must have already set `window.layoutReason = .standard` before calling this. `restoreTreeRecursive`
/// re-binds a snapshotted window only when `MacWindow.get(byId:).layoutReason == .standard`; if the returning window's own
/// `layoutReason` hasn't been flipped back yet, it looks unrestorable to its own restore pass, gets silently skipped, and
/// falls through to the orphan loop below instead of landing back in its original slot. `exitMacOsNativeUnconventionalState`
/// upholds this today by assigning `.standard` before its `switch` on `prevParentKind`.
@MainActor
func restoreMacosFullscreenLayout(window: Window, workspace: Workspace, _ cm: CancellationMode) async throws -> Bool {
    // Consume the snapshot unconditionally, before either guard below can return early, so a stale snapshot never
    // survives to be misapplied to a later, unrelated fullscreen cycle for the same window.
    guard let snapshot = snapshots.removeValue(forKey: window.windowId) else { return false }
    guard config.preserveLayoutOnMacosNativeFullscreen else { return false }
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
    // Deliberately not followed by `workspace.normalizeContainers()`: in the app-initiated path,
    // `runHeavyCompleteRefreshSession` runs `normalizeLayoutReason()` (which is what gets us here) and then
    // `layoutWorkspaces()`, with no `normalizeContainers()` call in between. So a container whose every window
    // closed while it was away can be laid out empty for one frame before the next refresh cleans it up. That's
    // accepted - see `testNestedContainerLeftEmptyIsCleanedUpByNormalization` for the same artifact via a
    // deliberate `normalizeContainers()` call instead.
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

    // `restoreTreeRecursive` rebuilds every container from scratch, so every container's MRU stack starts empty and
    // gets reset to document order by `bind`'s automatic `markAsMostRecentChild` call, no matter what it was before
    // entering fullscreen. Replay the captured order - oldest first - to put every ancestor container's MRU stack
    // back in its original relative order: `markAsMostRecentChild` pushes to the top of every ancestor's stack, so
    // replaying oldest-to-newest leaves the newest replayed entry on top, matching the pre-fullscreen snapshot.
    let restoredWindowIds = workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet()
    for windowId in snapshot.mruWindowIds.reversed() where windowId != window.windowId {
        if restoredWindowIds.contains(windowId), let mruWindow = MacWindow.get(byId: windowId) {
            mruWindow.markAsMostRecentChild()
        }
    }
    // The returning window goes last so it ends up the most recent regardless of where it sat in the old order.
    window.markAsMostRecentChild()
    return true
}

@MainActor
func dropMacosFullscreenLayoutSnapshot(windowId: UInt32) {
    snapshots.removeValue(forKey: windowId)
}

/// Any other change to the layout makes every snapshot stale. Called from mostly the same places as
/// ``resetClosedWindowsCache()`` - except in `Shell.swift`, where it deliberately runs *before* the command instead
/// of after, so that a command which itself takes a snapshot (e.g. `eval 'macos-native-fullscreen'`) doesn't have
/// that snapshot destroyed by its own `shouldResetClosedWindowsCache`.
@MainActor
func resetMacosFullscreenLayoutSnapshots() {
    snapshots = [:]
}
