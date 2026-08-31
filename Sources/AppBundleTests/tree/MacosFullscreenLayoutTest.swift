@testable import AppBundle
import Common
import XCTest

@MainActor
final class MacosFullscreenLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testExitingFullscreenPutsTheWindowBackInTheTilingTree() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2],
        )
    }

    func testRestoresSlotAndWeights() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3)]))

        // Stand in for the layout pass that rewrites sibling weights while the window is away
        w1.hWeight = 600
        w3.hWeight = 600

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2), .window(3)]),
        )
        assertEquals(w1.hWeight, 200)
        assertEquals(w2.hWeight, 500)
        assertEquals(w3.hWeight, 500)
    }

    func testRestoresContainerThatWasFlattenedAway() async throws {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        let nested = TilingContainer(parent: root, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        let w2 = TestWindow.new(id: 2, parent: nested)
        TestWindow.new(id: 3, parent: nested)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        workspace.normalizeContainers()
        // The two-window container was left with one child and flattened away
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(3)]))

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]),
        )
    }

    /// Regression test: `restoreTreeRecursive` builds brand new `TilingContainer`s whose MRU stacks start empty, and
    /// every `window.bind` call inside it marks itself as the most recent child of its (new) ancestor chain. Left
    /// unfixed, that resets every container's MRU to plain document order on every restore - the sibling the user
    /// was actually last working in gets forgotten in favor of whichever sibling happens to be last in the
    /// container's children array.
    func testRestorePreservesSiblingsMru() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let accordion = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 2, parent: accordion)
        let w3 = TestWindow.new(id: 3, parent: accordion)
        TestWindow.new(id: 4, parent: accordion)
        assertEquals(w1.focusWindow(), true)

        // The user was last working in w3, so it - not w4, the last child in document order - is the accordion's
        // MRU child.
        w3.markAsMostRecentChild()
        assertTrue(accordion.mostRecentChild === w3)

        w1.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        w1.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        // `restoreTreeRecursive` rebuilds the accordion as a brand new `TilingContainer`, so `accordion` above is
        // now a detached, stale object - re-derive the live one via a window that is still in it.
        assertTrue(w3.parent?.mostRecentChild === w3)
    }

    /// Regression test for the config guard returning before the snapshot is consumed: with the guards in the wrong
    /// order, toggling the config option off right as a window exits fullscreen leaves that window's snapshot in
    /// the cache forever - neither this exit (config off, so the restore is skipped) nor a config reload (which
    /// doesn't touch this cache) consumes it. A later, wholly unrelated fullscreen cycle for the same window can
    /// then have that stale snapshot misapplied to it.
    func testStaleSnapshotDoesNotLeakAcrossConfigToggle() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 300)
        assertEquals(w1.focusWindow(), true)

        // Cycle 1: fullscreen with the feature on, so a snapshot gets recorded for w2...
        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        // ...but exit with the feature off. The snapshot must still be consumed here, even though the restore
        // itself is skipped and falls back to the old-style relayout.
        config.preserveLayoutOnMacosNativeFullscreen = false
        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()
        assertTrue(w2.parent === workspace.rootTilingContainer) // old-style relayout, not restored from the snapshot

        // The layout is now completely different from what cycle 1's snapshot captured.
        w1.hWeight = 999

        // Cycle 2: fullscreen again while still off (so no new snapshot is recorded for w2), then exit with the
        // feature back on. If cycle 1's snapshot leaked, it gets misapplied here, clobbering the weight set above.
        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        config.preserveLayoutOnMacosNativeFullscreen = true
        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(w1.hWeight, 999) // cycle 1's stale snapshot must not have been applied
    }

    func testConfigOptionOffKeepsOldBehavior() async throws {
        config.preserveLayoutOnMacosNativeFullscreen = false
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        w1.hWeight = 600

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2],
        )
        assertEquals(w1.hWeight, 600) // not restored
    }

    func testWindowOpenedDuringFullscreenIsKept() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 300)

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2, 3],
        )
        assertEquals(w1.hWeight, 200)
        assertEquals(w2.hWeight, 500)
    }

    func testWindowClosedDuringFullscreenIsSkipped() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 300)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        w3.closeAxWindow() // TestWindow.closeAxWindow just unbinds

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2)]),
        )
        assertEquals(w1.hWeight, 200)
        assertEquals(w2.hWeight, 500)
    }

    func testExitingOneFullscreenLeavesTheOtherFullscreen() async throws {
        let workspace = Workspace.get(byName: name)
        // Unequal weights so this test actually discriminates: with the default weight of 1 on every window, a
        // relayout with no restore at all (i.e. the feature removed) produces this exact same tree shape, so an
        // all-equal-weights version of this test would pass either way.
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 300)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        w3.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        // Stand in for the layout pass that rewrites sibling weights while w2 is away
        w1.hWeight = 600

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertTrue(w3.parent === workspace.macOsNativeFullscreenWindowsContainer)
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2)]),
        )
        assertEquals(w1.hWeight, 200)
        assertEquals(w2.hWeight, 500)
    }

    /// The `snapshot.workspaceName == workspace.name` guard in `restoreMacosFullscreenLayout` is the safety net for
    /// cross-workspace/multi-monitor cases: a window can end up exiting its macOS unconventional state on a
    /// different workspace than the one whose tree was snapshotted (e.g. after a workspace/monitor reassignment
    /// while it was away in its own macOS Space). When that happens, the restore must decline and fall back to a
    /// plain relayout on the workspace the window actually returned to - it must never splice a snapshot taken on
    /// one workspace into another workspace's tree.
    func testMismatchedWorkspaceDeclinesTheRestore() async throws {
        let workspaceA = Workspace.get(byName: name)
        let workspaceB = Workspace.get(byName: "other")
        let w1 = TestWindow.new(id: 1, parent: workspaceA.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspaceA.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        // Simulate w2 having ended up parented under a different workspace's fullscreen container while it was
        // away, without going through the normal restore path.
        w2.unbindFromParent()
        w2.bind(to: workspaceB.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        // The restore must have declined: workspace A's tree is untouched (w2 never came back to it), and w2
        // landed in workspace B via the plain-relayout fallback instead.
        assertEquals(workspaceA.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
        assertTrue(w2.parent === workspaceB.rootTilingContainer)
    }

    /// `restoreTreeRecursive` always constructs the container for a snapshot node, even when every child other than
    /// the returning window gets skipped. This proves that doesn't corrupt or crash: the rebuilt tree gets a
    /// leftover single-child `v_tiles` container wrapping the returning window right after exit (because
    /// `normalizeLayoutReason` alone never calls `normalizeContainers`), and that artifact self-heals on the next
    /// normalization pass under the (production-default) flatten-containers setting, same as any other
    /// single-child container would.
    func testNestedContainerSurvivesWhenItsOtherWindowClosed() async throws {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        let nested = TilingContainer(parent: root, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        let w2 = TestWindow.new(id: 2, parent: nested)
        let w3 = TestWindow.new(id: 3, parent: nested)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        w3.closeAxWindow() // The nested container's other snapshot child becomes unrestorable while w2 is away

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        // Right after exit: the nested container survives with only the returning window in it.
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(2)])]),
        )

        // The next normalization pass flattens it away like any other single-child container.
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2)]),
        )
    }

    /// Unlike `testNestedContainerSurvivesWhenItsOtherWindowClosed`, here the nested container is disjoint from the
    /// returning window: it holds two windows that are both closed while the fullscreen window is away. So every
    /// child of that snapshot container gets skipped by `restoreTreeRecursive`, and the container it already
    /// constructed for that snapshot node is left in the rebuilt tree with no children at all.
    func testNestedContainerLeftEmptyIsCleanedUpByNormalization() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        let w2 = TestWindow.new(id: 2, parent: root)
        let nested = TilingContainer(parent: root, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        let w4 = TestWindow.new(id: 4, parent: nested)
        let w5 = TestWindow.new(id: 5, parent: nested)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        // Both of the nested container's windows become unrestorable while w2 is away
        w4.closeAxWindow() // TestWindow.closeAxWindow just unbinds
        w5.closeAxWindow()

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        // Right after exit: the nested container was rebuilt (restoreTreeRecursive always constructs the
        // container before it knows whether any child will survive), but both of its children were skipped as
        // unrestorable, so it comes back genuinely empty.
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2), .v_tiles([])]),
        )

        // `unbindEmptyAndAutoFlatten`'s else-branch unbinds empty non-root containers unconditionally - that path
        // doesn't depend on `config.enableNormalizationFlattenContainers` (left at the test default of `false`
        // here) - so the next normalization pass removes the leftover empty container.
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2)]),
        )
    }

    func testLayoutChangingCommandInvalidatesTheSnapshot() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 300)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        // flatten-workspace-tree has shouldResetClosedWindowsCache = true and rebinds
        // every tiled window with adaptiveWeight 1, so it both invalidates and is observable
        _ = await parseCommand("flatten-workspace-tree").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(w1.hWeight, 1)

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2, 3],
        )
        assertEquals(w1.hWeight, 1) // the command's sizes won, the snapshot did not come back
    }

    /// `BalanceSizesCommand` rewrites every tiling weight in the workspace (`child.setWeight(parent.orientation, 1)`
    /// recursively), which is plainly a layout change, so it must invalidate the snapshot exactly like
    /// `testLayoutChangingCommandInvalidatesTheSnapshot` demonstrates for `flatten-workspace-tree`.
    func testBalanceSizesInvalidatesTheSnapshot() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: 300)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3)]))

        // balance-sizes sets every remaining tiled sibling's weight to 1, deliberately rebalancing the layout
        // while w2 is away in fullscreen.
        _ = await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(w1.hWeight, 1)
        assertEquals(w3.hWeight, 1)

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2, 3],
        )
        assertEquals(w1.hWeight, 1) // balance-sizes's weights won, the snapshot did not come back
        assertEquals(w3.hWeight, 1)
    }

    func testResettingSnapshotsFallsBackToOldBehavior() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        w1.hWeight = 600

        resetMacosFullscreenLayoutSnapshots()

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(
            workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId).toSet(),
            [1, 2],
        )
        assertEquals(w1.hWeight, 600) // not restored
    }

    func testDroppingOneSnapshotFallsBackToOldBehavior() async throws {
        let workspace = Workspace.get(byName: name)
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: 200)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 500)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        dropMacosFullscreenLayoutSnapshot(windowId: w2.windowId)
        w1.hWeight = 600

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertEquals(w1.hWeight, 600) // not restored
    }
}
