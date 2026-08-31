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
}
