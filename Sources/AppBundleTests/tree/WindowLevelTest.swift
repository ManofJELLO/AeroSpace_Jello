@testable import AppBundle
import XCTest

@MainActor
final class WindowLevelTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFloatingWindowsAreRaisedAboveTiledOnesByDefault() {
        let workspace = Workspace.get(byName: name)
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)

        assertEquals(tiled.desiredWindowLevel, .normal)
        assertEquals(floating.desiredWindowLevel, .floating)
    }

    func testFloatingWindowsOnTopOffLeavesStackingToMacos() {
        config.floatingWindowsOnTop = false
        let workspace = Workspace.get(byName: name)
        let floating = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer)

        assertEquals(floating.desiredWindowLevel, .normal)
    }

    func testAWindowThatStopsFloatingDropsBackDown() {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer)
        assertEquals(window.desiredWindowLevel, .floating)

        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        assertEquals(window.desiredWindowLevel, .normal)
    }
}
