@testable import AppBundle
import XCTest

@MainActor
final class FloatingWindowsOnTopTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFocusingATiledWindowRaisesItsAppsFloatingWindows() {
        let workspace = Workspace.get(byName: name)
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)

        assertEquals(tiled.floatingWindowsToRaise.map(\.windowId), [floating.windowId])
    }

    func testFloatingWindowsOfOtherAppsAreLeftAlone() {
        let workspace = Workspace.get(byName: name)
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        // macOS stacks by app, so this one is out of reach: no AX request can lift it above 'tiled'
        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer, app: .other)

        assertEquals(tiled.floatingWindowsToRaise, [])
    }

    func testFocusingAFloatingWindowRaisesNothing() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)

        assertEquals(floating.floatingWindowsToRaise, [])
    }

    func testNothingIsRaisedOverAMacosNativeFullscreenWindow() {
        let workspace = Workspace.get(byName: name)
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        TestWindow.new(id: 3, parent: workspace.macOsNativeFullscreenWindowsContainer)

        assertEquals(tiled.floatingWindowsToRaise, [])
    }

    func testFloatingWindowsOnTopOffLeavesStackingToMacos() {
        config.floatingWindowsOnTop = false
        let workspace = Workspace.get(byName: name)
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)

        assertEquals(tiled.floatingWindowsToRaise, [])
    }
}
