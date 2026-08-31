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
}
