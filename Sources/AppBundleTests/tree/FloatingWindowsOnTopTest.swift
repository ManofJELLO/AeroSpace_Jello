@testable import AppBundle
import Testing

@MainActor
@Suite(.serializedGlobally)
struct FloatingWindowsOnTopTest {
    init() { setUpWorkspacesForTests() }

    @Test func testFocusingATiledWindowRaisesItsAppsFloatingWindows() {
        let workspace = Workspace.get(byName: name)
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)

        assertEquals(tiled.floatingWindowsToRaise.map(\.windowId), [floating.windowId])
    }

    @Test func testFloatingWindowsOfOtherAppsAreLeftAlone() {
        let workspace = Workspace.get(byName: name)
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        // macOS stacks by app, so this one is out of reach: no AX request can lift it above 'tiled'
        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer, app: .other)

        assertEquals(tiled.floatingWindowsToRaise, [])
    }

    @Test func testFocusingAFloatingWindowRaisesNothing() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)

        assertEquals(floating.floatingWindowsToRaise, [])
    }

    @Test func testNothingIsRaisedOverAMacosNativeFullscreenWindow() {
        let workspace = Workspace.get(byName: name)
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        TestWindow.new(id: 3, parent: workspace.macOsNativeFullscreenWindowsContainer)

        assertEquals(tiled.floatingWindowsToRaise, [])
    }

    @Test func testFloatingWindowsOnTopOffLeavesStackingToMacos() {
        config.floatingWindowsOnTop = false
        let workspace = Workspace.get(byName: name)
        let tiled = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)

        assertEquals(tiled.floatingWindowsToRaise, [])
    }
}
