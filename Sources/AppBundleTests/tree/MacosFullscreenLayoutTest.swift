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
        let w1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let w2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let w3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        assertEquals(w1.focusWindow(), true)

        w2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        w3.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()

        w2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()

        assertTrue(w3.parent === workspace.macOsNativeFullscreenWindowsContainer)
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .window(2)]),
        )
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
