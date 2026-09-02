@testable import AppBundle
import Common
import XCTest

/// The test monitor is 1920x1080. `layoutWorkspace` lays out `height - 1` to work around a macOS quirk
private let screenWidth: CGFloat = 1920
private let screenHeight: CGFloat = 1079

@MainActor
final class MasterLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testMasterOnTheLeft() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 3)

        try await workspace.layoutWorkspace()

        // 55% of the screen for the master, the rest is split evenly between the two stack windows
        assertRect(windows[0], x: 0, y: 0, width: 1056, height: screenHeight)
        assertRect(windows[1], x: 1056, y: 0, width: 864, height: screenHeight / 2)
        assertRect(windows[2], x: 1056, y: screenHeight / 2, width: 864, height: screenHeight / 2)
    }

    func testMasterOnTheRight() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 3, orientation: .right)

        try await workspace.layoutWorkspace()

        assertRect(windows[0], x: 864, y: 0, width: 1056, height: screenHeight)
        assertRect(windows[1], x: 0, y: 0, width: 864, height: screenHeight / 2)
        assertRect(windows[2], x: 0, y: screenHeight / 2, width: 864, height: screenHeight / 2)
    }

    func testMasterOnTop() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 3, orientation: .top)

        try await workspace.layoutWorkspace()

        let masterHeight = screenHeight * 0.55
        assertRect(windows[0], x: 0, y: 0, width: screenWidth, height: masterHeight)
        assertRect(windows[1], x: 0, y: masterHeight, width: screenWidth / 2, height: screenHeight - masterHeight)
        assertRect(windows[2], x: screenWidth / 2, y: masterHeight, width: screenWidth / 2, height: screenHeight - masterHeight)
    }

    func testMasterOnTheBottom() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 2, orientation: .bottom)

        try await workspace.layoutWorkspace()

        let masterHeight = screenHeight * 0.55
        assertRect(windows[0], x: 0, y: screenHeight - masterHeight, width: screenWidth, height: masterHeight)
        assertRect(windows[1], x: 0, y: 0, width: screenWidth, height: screenHeight - masterHeight)
    }

    func testSingleWindowFillsTheWholeContainer() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 1)

        try await workspace.layoutWorkspace()

        assertRect(windows[0], x: 0, y: 0, width: screenWidth, height: screenHeight)
    }

    func testEveryWindowIsAMasterWhenTheCountCoversThemAll() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 2, count: 5)

        try await workspace.layoutWorkspace()

        // There is no stack left, so the master area owns the whole container
        assertRect(windows[0], x: 0, y: 0, width: screenWidth, height: screenHeight / 2)
        assertRect(windows[1], x: 0, y: screenHeight / 2, width: screenWidth, height: screenHeight / 2)
    }

    func testTwoMasters() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 3, count: 2)

        try await workspace.layoutWorkspace()

        assertRect(windows[0], x: 0, y: 0, width: 1056, height: screenHeight / 2)
        assertRect(windows[1], x: 0, y: screenHeight / 2, width: 1056, height: screenHeight / 2)
        assertRect(windows[2], x: 1056, y: 0, width: 864, height: screenHeight)
    }

    func testCenterOrientation() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 5, orientation: .center)

        try await workspace.layoutWorkspace()

        // Stack windows are dealt out alternately, so the two side columns stay balanced
        let side = (screenWidth - 1056) / 2
        assertRect(windows[0], x: side, y: 0, width: 1056, height: screenHeight) // master
        assertRect(windows[1], x: 0, y: 0, width: side, height: screenHeight / 2) // leading column
        assertRect(windows[2], x: side + 1056, y: 0, width: side, height: screenHeight / 2) // trailing column
        assertRect(windows[3], x: 0, y: screenHeight / 2, width: side, height: screenHeight / 2)
        assertRect(windows[4], x: side + 1056, y: screenHeight / 2, width: side, height: screenHeight / 2)
    }

    func testCenterFallsBackToTheLeftWhenThereAreTooFewStackWindows() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 2, orientation: .center)

        try await workspace.layoutWorkspace()

        // One stack window is not enough to flank the master area on both sides
        assertRect(windows[0], x: 0, y: 0, width: 1056, height: screenHeight)
        assertRect(windows[1], x: 1056, y: 0, width: 864, height: screenHeight)
    }

    func testCenterWithAZeroThresholdKeepsBothColumns() async throws {
        config.master = config.master.copy(\.centerStackThreshold, 0)
        let (workspace, windows) = masterWorkspace(name, windowCount: 2, orientation: .center)

        try await workspace.layoutWorkspace()

        // Hyprland's slave_count_for_center_master = 0 means "always center", so the master stays centred and the
        // column opposite the single stack window is simply left empty
        let side = (screenWidth - 1056) / 2
        assertRect(windows[0], x: side, y: 0, width: 1056, height: screenHeight)
        assertRect(windows[1], x: 0, y: 0, width: side, height: screenHeight)
    }

    func testCenterFallbackChoosesTheSide() async throws {
        config.master = config.master.copy(\.centerFallback, .right)
        let (workspace, windows) = masterWorkspace(name, windowCount: 2, orientation: .center)

        try await workspace.layoutWorkspace()

        // Only one stack window, so 'center' falls back. 'right' puts the master area on the right
        assertRect(windows[0], x: 864, y: 0, width: 1056, height: screenHeight)
        assertRect(windows[1], x: 0, y: 0, width: 864, height: screenHeight)
    }

    func testCenterFallbackCanFlipTheAxis() async throws {
        config.master = config.master.copy(\.centerFallback, .top)
        let (workspace, windows) = masterWorkspace(name, windowCount: 2, orientation: .center)

        try await workspace.layoutWorkspace()

        // 'top' names a whole orientation, so the fallback splits vertically even though 'center' is horizontal
        let masterHeight = screenHeight * 0.55
        assertRect(windows[0], x: 0, y: 0, width: screenWidth, height: masterHeight)
        assertRect(windows[1], x: 0, y: masterHeight, width: screenWidth, height: screenHeight - masterHeight)
    }

    func testInnerGapsSplitTheMasterAndTheStack() async throws {
        config.gaps = config.gaps.copy(\.inner, .init(vertical: 10, horizontal: 20))
        let (workspace, windows) = masterWorkspace(name, windowCount: 3)

        try await workspace.layoutWorkspace()

        // 20px of horizontal gap sits between the master and the stack, 10px of vertical gap inside the stack
        assertRect(windows[0], x: 0, y: 0, width: (screenWidth - 20) * 0.55, height: screenHeight)
        let stackX = (screenWidth - 20) * 0.55 + 20
        let stackWidth = screenWidth - stackX
        assertRect(windows[1], x: stackX, y: 0, width: stackWidth, height: screenHeight / 2 - 5)
        assertRect(windows[2], x: stackX, y: screenHeight / 2 + 5, width: stackWidth, height: screenHeight / 2 - 5)
    }

    func testWeightsSizeTheStackWindows() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 3)
        try await workspace.layoutWorkspace()

        assertEquals(TestWindow.focus(windows[1]), true)
        await parseCommand("resize height +200").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertRect(windows[1], x: 1056, y: 0, width: 864, height: screenHeight / 2 + 200)
        assertRect(windows[2], x: 1056, y: screenHeight / 2 + 200, width: 864, height: screenHeight / 2 - 200)
        // The master is in a different column, it keeps the full height
        assertRect(windows[0], x: 0, y: 0, width: 1056, height: screenHeight)
    }

    func testResizeWidthMovesTheMasterStackBoundary() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 2)
        try await workspace.layoutWorkspace()

        assertEquals(TestWindow.focus(windows[0]), true)
        await parseCommand("resize width +192").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertApproxEquals(root(name).master.fraction, 0.65)
        assertRect(windows[0], x: 0, y: 0, width: screenWidth * 0.65, height: screenHeight)
    }

    func testResizeWidthFromTheStackShrinksTheMaster() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 2)
        try await workspace.layoutWorkspace()

        assertEquals(TestWindow.focus(windows[1]), true)
        await parseCommand("resize width +192").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        // The stack grew from 864px to 1056px, so the master area gave up 10% of the screen
        assertApproxEquals(root(name).master.fraction, 0.45)
    }

    func testStackStaysEvenAfterAddingAndRemovingAMaster() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 3)
        try await workspace.layoutWorkspace()
        assertEquals(TestWindow.focus(windows[0]), true)

        // Round-tripping a window through the master area used to leave the stack permanently lopsided, because
        // weights were absolute extents and the layout's normalization preserved the difference
        await parseCommand("master add-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(windows[0], x: 0, y: 0, width: 1056, height: screenHeight / 2)
        assertRect(windows[1], x: 0, y: screenHeight / 2, width: 1056, height: screenHeight / 2)

        await parseCommand("master remove-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertRect(windows[0], x: 0, y: 0, width: 1056, height: screenHeight)
        assertRect(windows[1], x: 1056, y: 0, width: 864, height: screenHeight / 2)
        assertRect(windows[2], x: 1056, y: screenHeight / 2, width: 864, height: screenHeight / 2)
    }

    func testStackStaysEvenAfterPromotingAndDemoting() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 3)
        try await workspace.layoutWorkspace()
        assertEquals(TestWindow.focus(windows[2]), true)

        await parseCommand("master swap-with-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        await parseCommand("master swap-with-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertRect(windows[1], x: 1056, y: 0, width: 864, height: screenHeight / 2)
        assertRect(windows[2], x: 1056, y: screenHeight / 2, width: 864, height: screenHeight / 2)
    }

    func testADeliberateResizeSurvivesAColumnChange() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 3)
        try await workspace.layoutWorkspace()
        assertEquals(TestWindow.focus(windows[1]), true)

        // Make the first stack window twice the height of the second
        await parseCommand("resize height +180").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        let tallBefore = windows[1].lastAppliedLayoutPhysicalRect.orDie().height

        // Promote it and demote it again. Shares are normalized, so it comes back proportionally intact rather than
        // carrying a pixel-scale weight into a differently sized column
        await parseCommand("master add-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        await parseCommand("master remove-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertApproxEquals(windows[1].lastAppliedLayoutPhysicalRect.orDie().height, tallBefore)
        assertApproxEquals(
            windows[1].lastAppliedLayoutPhysicalRect.orDie().height
                + windows[2].lastAppliedLayoutPhysicalRect.orDie().height,
            screenHeight,
        )
    }

    func testBalanceSizesEvensOutEachColumn() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 3)
        try await workspace.layoutWorkspace()
        assertEquals(TestWindow.focus(windows[1]), true)
        await parseCommand("resize height +200").cmdOrDie.run(.defaultEnv, .emptyStdin)

        await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        assertRect(windows[1], x: 1056, y: 0, width: 864, height: screenHeight / 2)
        assertRect(windows[2], x: 1056, y: screenHeight / 2, width: 864, height: screenHeight / 2)
        // 'balance-sizes' evens out the windows, the master/stack split is owned by master.fraction
        assertApproxEquals(root(name).master.fraction, 0.55)
    }
}

@MainActor
final class MasterNavigationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFocusCrossesBetweenTheMasterAndTheStack() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[1]), true) // Make the top of the stack the most recently focused one
        assertEquals(TestWindow.focus(windows[0]), true)

        await parseCommand("focus right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[1])

        await parseCommand("focus left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[0])
    }

    func testFocusWalksTheStackVertically() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[1]), true)

        await parseCommand("focus down").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[2])

        await parseCommand("focus up").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[1])
    }

    func testTheMasterHasNoVerticalNeighbours() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[0]), true)

        // The master area holds a single window, so 'down' hits the container boundary
        await parseCommand("focus down").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[0])
    }

    func testFocusReturnsToTheMostRecentWindowOfTheStack() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[2]), true)
        assertEquals(TestWindow.focus(windows[0]), true)

        await parseCommand("focus right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[2])
    }

    func testFocusInCenterOrientation() async {
        let (_, windows) = masterWorkspace(name, windowCount: 5, orientation: .center)
        // The leading column holds windows[1] and windows[3], the trailing one windows[2] and windows[4]
        assertEquals(TestWindow.focus(windows[2]), true) // Make it the most recently focused of its column
        assertEquals(TestWindow.focus(windows[1]), true)

        await parseCommand("focus right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[0])

        await parseCommand("focus right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[2])

        // windows[3] is below windows[1] in the leading column
        assertEquals(TestWindow.focus(windows[1]), true)
        await parseCommand("focus down").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[3])
    }

    func testMoveDemotesTheMasterAndPromotesAStackWindow() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[0]), true)

        await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).layoutDescription, .h_master([.window(2), .window(1), .window(3)]))

        await parseCommand("move left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).layoutDescription, .h_master([.window(1), .window(2), .window(3)]))
    }

    func testMoveReordersTheStack() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[1]), true)

        await parseCommand("move down").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).layoutDescription, .h_master([.window(1), .window(3), .window(2)]))
    }

    func testMoveKeepsTheColumnInCenterOrientation() async {
        let (_, windows) = masterWorkspace(name, windowCount: 5, orientation: .center)
        // Leading column holds windows[1] and windows[3]. Swapping them must not leak into the trailing column
        assertEquals(TestWindow.focus(windows[1]), true)

        await parseCommand("move down").cmdOrDie.run(.defaultEnv, .emptyStdin)

        let container = root(name)
        assertEquals(container.leadingStackChildren.map { ($0 as! Window).windowId }, [4, 2])
        assertEquals(container.trailingStackChildren.map { ($0 as! Window).windowId }, [3, 5])
    }

    func testMovingOutOfAMasterWorkspaceKeepsTheMasterLayout() async {
        let (_, windows) = masterWorkspace(name, windowCount: 2)
        assertEquals(TestWindow.focus(windows[0]), true)

        // The default boundaries-action is create-implicit-container, which wraps the root in a new *tiles*
        // container. For a master workspace that would silently drop the whole thing out of the master layout
        await parseCommand("move left").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(root(name).layoutDescription, .h_master([.window(1), .window(2)]))
    }

    func testMovingOutOfATilesWorkspaceStillCreatesAnImplicitContainer() async {
        let container = Workspace.get(byName: name).rootTilingContainer
        assertEquals(TestWindow.new(id: 1, parent: container).focusWindow(), true)
        TestWindow.new(id: 2, parent: container)

        await parseCommand("move left").cmdOrDie.run(.defaultEnv, .emptyStdin)

        // Unchanged upstream behavior for non-master layouts
        assertEquals(
            Workspace.get(byName: name).rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .h_tiles([.window(2)])]),
        )
    }

    func testMoveAtTheEdgeHitsTheWorkspaceBoundary() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[0]), true)

        // The master already sits at the left edge of the container, and the container is the workspace root
        await parseCommand("move --boundaries-action stop left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).layoutDescription, .h_master([.window(1), .window(2), .window(3)]))
    }
}

@MainActor
final class MasterCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseMasterCommand() {
        testParseSingleCommandSucc("master swap-with-master", MasterCmdArgs(rawArgs: [], action: .swapWithMaster))
        testParseSingleCommandSucc("master rotate-prev", MasterCmdArgs(rawArgs: [], action: .rotatePrev))
        testParseSingleCommandSucc("master set-count 3", MasterCmdArgs(rawArgs: [], action: .setCount(.set(3))))
        testParseSingleCommandSucc("master set-fraction +5", MasterCmdArgs(rawArgs: [], action: .setFraction(.add(5))))
        testParseSingleCommandSucc("master set-fraction -5", MasterCmdArgs(rawArgs: [], action: .setFraction(.subtract(5))))
        testParseSingleCommandSucc(
            "master set-orientation center",
            MasterCmdArgs(rawArgs: [], action: .setOrientation(.exact(.center))),
        )
        testParseSingleCommandSucc("master set-orientation next", MasterCmdArgs(rawArgs: [], action: .setOrientation(.next)))
        testParseSingleCommandSucc(
            "master --workspace foo add-master",
            MasterCmdArgs(rawArgs: [], action: .addMaster).copy(\.workspaceName, .parse("foo").getOrDie()),
        )
    }

    func testParseMasterCommandFailures() {
        testParseCommandFail(
            "master",
            msg: "ERROR: Argument '\(masterActionPlaceholderForTests)' is mandatory",
            exitCode: 2,
        )
        testParseCommandFail(
            "master set-fraction",
            msg: "ERROR: 'set-fraction' requires an argument. Expected: [+|-]<number>",
            exitCode: 2,
        )
        testParseCommandFail(
            "master set-count abc",
            msg: "ERROR: Can't parse 'abc'. Expected: [+|-]<number>",
            exitCode: 2,
        )
        testParseCommandFail(
            "master set-orientation diagonal",
            msg: "ERROR: Can't parse 'diagonal'\n       Possible values: (left|right|top|bottom|center), next, prev",
            exitCode: 2,
        )
    }

    func testSwapWithMasterTogglesBackAndForth() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[2]), true)

        await parseCommand("master swap-with-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).layoutDescription, .h_master([.window(3), .window(2), .window(1)]))

        await parseCommand("master swap-with-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).layoutDescription, .h_master([.window(1), .window(2), .window(3)]))
    }

    func testFocusMasterTogglesBackAndForth() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[2]), true)

        await parseCommand("master focus-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[0])

        await parseCommand("master focus-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil, windows[2])
    }

    func testAddAndRemoveMaster() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[0]), true)

        await parseCommand("master add-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).master.count, 2)
        assertEquals(root(name).masterChildren.count, 2)

        await parseCommand("master remove-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).master.count, 1)
    }

    func testMasterCountIsClamped() async {
        let (_, windows) = masterWorkspace(name, windowCount: 2)
        assertEquals(TestWindow.focus(windows[0]), true)

        await parseCommand("master set-count 9").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).master.count, 2)

        await parseCommand("master set-count -9").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).master.count, 1)
    }

    func testSetFraction() async {
        let (_, windows) = masterWorkspace(name, windowCount: 2)
        assertEquals(TestWindow.focus(windows[0]), true)

        await parseCommand("master set-fraction 70").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).master.fraction, 0.7)

        await parseCommand("master set-fraction -5").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).master.fraction, 0.65)

        await parseCommand("master set-fraction +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).master.fraction, MASTER_MAX_FRACTION)
    }

    func testSetOrientation() async {
        let (_, windows) = masterWorkspace(name, windowCount: 2)
        assertEquals(TestWindow.focus(windows[0]), true)

        await parseCommand("master set-orientation bottom").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).orientation, .v)
        assertEquals(root(name).master.placement, .end)

        // The cycle is left -> top -> right -> bottom -> center -> left, same as Hyprland's orientationnext
        await parseCommand("master set-orientation next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).masterOrientation, .center)

        await parseCommand("master set-orientation next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).masterOrientation, .left)

        await parseCommand("master set-orientation prev").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).masterOrientation, .center)
    }

    func testRotate() async {
        let (_, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[0]), true)

        await parseCommand("master rotate-next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).layoutDescription, .h_master([.window(2), .window(3), .window(1)]))
        // Focus stays on the master slot, so each press flips a different window into it
        assertEquals(focus.windowOrNil, windows[1])

        await parseCommand("master rotate-prev").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root(name).layoutDescription, .h_master([.window(1), .window(2), .window(3)]))
        assertEquals(focus.windowOrNil, windows[0])
    }

    func testRotateNeedsTwoWindows() async {
        let (_, windows) = masterWorkspace(name, windowCount: 1)
        assertEquals(TestWindow.focus(windows[0]), true)

        let result = await parseCommand("master rotate-next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertNotEquals(result.exitCode.rawValue, 0)
    }

    func testFailsOutsideOfAMasterContainer() async {
        let root = Workspace.get(byName: name).rootTilingContainer
        assertEquals(TestWindow.new(id: 1, parent: root).focusWindow(), true)

        let result = await parseCommand("master swap-with-master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertNotEquals(result.exitCode.rawValue, 0)
    }

    func testStartupDoesNotClobberAConfiguredMasterLayout() {
        config.defaultRootContainerLayout = .master
        let container = Workspace.get(byName: name).rootTilingContainer
        container.layout = .master
        for id in 1 ... 4 { TestWindow.new(id: UInt32(id), parent: container) }
        assertEquals(TestWindow.new(id: 5, parent: container).focusWindow(), true)

        // The startup heuristic would otherwise flip this to accordion, because there are more than 3 windows
        smartLayoutAtStartup()

        assertEquals(focus.workspace.rootTilingContainer.layout, .master)
    }

    func testStartupHeuristicStillAppliesToOtherLayouts() {
        let container = Workspace.get(byName: name).rootTilingContainer
        for id in 1 ... 4 { TestWindow.new(id: UInt32(id), parent: container) }
        assertEquals(TestWindow.new(id: 5, parent: container).focusWindow(), true)

        smartLayoutAtStartup()

        assertEquals(focus.workspace.rootTilingContainer.layout, .accordion)
    }

    func testLayoutCommandTogglesMaster() async {
        let container = Workspace.get(byName: name).rootTilingContainer
        assertEquals(TestWindow.new(id: 1, parent: container).focusWindow(), true)
        TestWindow.new(id: 2, parent: container)

        await parseCommand("layout master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(container.layout, .master)
        assertEquals(container.master, MasterState.fromConfig)

        await parseCommand("layout tiles master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(container.layout, .tiles)

        await parseCommand("layout v_master").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(container.layout, .master)
        assertEquals(container.orientation, .v)
    }
}

@MainActor
final class MasterNewWindowPositionTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testNewWindowGoesToTheBottomOfTheStackByDefault() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 2)
        assertEquals(TestWindow.focus(windows[0]), true)

        try await newTilingWindow(id: 3, on: workspace)

        assertEquals(root(name).layoutDescription, .h_master([.window(1), .window(2), .window(3)]))
    }

    func testANewStackWindowComesOutTheSameSizeAsItsColumnMates() async throws {
        let (workspace, windows) = masterWorkspace(name, windowCount: 3)
        try await workspace.layoutWorkspace()
        assertEquals(TestWindow.focus(windows[0]), true)

        try await newTilingWindow(id: 4, on: workspace)
        try await workspace.layoutWorkspace()

        // The master column divides the same height between fewer windows, so its weight must not drag the new
        // stack window's size up
        for row in 0 ..< 3 {
            assertRect(
                TestApp.shared.windows[row + 1] as! TestWindow,
                x: 1056,
                y: screenHeight / 3 * CGFloat(row),
                width: 864,
                height: screenHeight / 3,
            )
        }
    }

    func testNewWindowCanBecomeTheMaster() async throws {
        config.master = config.master.copy(\.newWindowPosition, .master)
        let (workspace, windows) = masterWorkspace(name, windowCount: 2)
        assertEquals(TestWindow.focus(windows[0]), true)

        try await newTilingWindow(id: 3, on: workspace)

        assertEquals(root(name).layoutDescription, .h_master([.window(3), .window(1), .window(2)]))
    }

    func testNewWindowCanGoToTheTopOfTheStack() async throws {
        config.master = config.master.copy(\.newWindowPosition, .stackStart)
        let (workspace, windows) = masterWorkspace(name, windowCount: 2)
        assertEquals(TestWindow.focus(windows[0]), true)

        try await newTilingWindow(id: 3, on: workspace)

        assertEquals(root(name).layoutDescription, .h_master([.window(1), .window(3), .window(2)]))
    }

    func testNewWindowCanFollowTheFocus() async throws {
        config.master = config.master.copy(\.newWindowPosition, .afterFocused)
        let (workspace, windows) = masterWorkspace(name, windowCount: 3)
        assertEquals(TestWindow.focus(windows[1]), true)

        try await newTilingWindow(id: 4, on: workspace)

        assertEquals(root(name).layoutDescription, .h_master([.window(1), .window(2), .window(4), .window(3)]))
    }
}

@MainActor
final class MasterMouseDropTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// Master on the left at 55%, so the stack column spans x 1056..1920 and its three windows are ~359.67 tall each.
    ///
    /// The workspace has to be the monitor's active one, because a drop maps the cursor back to a workspace through
    /// the monitor. `setUpWorkspacesForTests` already made `focus.workspace` active, so build on that one
    private func stackWorkspace() async throws -> (Workspace, [TestWindow]) {
        let (workspace, windows) = masterWorkspace(focus.workspace.name, windowCount: 4)
        try await workspace.layoutWorkspace()
        return (workspace, windows)
    }

    func testDroppingOnAWindowPutsTheDraggedWindowInItsSlot() async throws {
        let (workspace, windows) = try await stackWorkspace()

        // windows[2], the middle stack window
        moveTilingWindow(windows[1], cursor: CGPoint(x: 1500, y: 600))

        assertEquals(workspace.rootTilingContainer.layoutDescription,
                     .h_master([.window(1), .window(3), .window(2), .window(4)]))
    }

    func testWhichHalfOfTheTargetTheCursorIsInMakesNoDifference() async throws {
        for y in [400, 500, 600, 700] {
            setUpWorkspacesForTests()
            let (workspace, windows) = try await stackWorkspace()

            // Anywhere inside windows[2] means the same thing: put the dragged window there
            moveTilingWindow(windows[3], cursor: CGPoint(x: 1500, y: CGFloat(y)))

            assertEquals(workspace.rootTilingContainer.layoutDescription,
                         .h_master([.window(1), .window(2), .window(4), .window(3)]))
        }
    }

    func testDroppingAnywhereOnTheMasterPromotesTheWindow() async throws {
        // The master column spans the full height, so its midpoint sits halfway down it. A rule that weighed the
        // cursor against that midpoint answered "the slot after the master" for the lower half -- the top of the
        // stack, the opposite of what the cursor was pointing at
        for y in [100, 900] {
            setUpWorkspacesForTests()
            let (workspace, windows) = try await stackWorkspace()

            moveTilingWindow(windows[2], cursor: CGPoint(x: 500, y: CGFloat(y)))

            // The window lands in the master slot and the rest shift along by one. A swap would instead have
            // flung the old master all the way down to windows[2]'s slot
            assertEquals(workspace.rootTilingContainer.layoutDescription,
                         .h_master([.window(3), .window(1), .window(2), .window(4)]))
        }
    }

    func testDroppingAWindowBackOnItsOwnSlotChangesNothing() async throws {
        let (workspace, windows) = try await stackWorkspace()

        // Dragging somewhere and back again has to cancel. A window is never its own drop target, so this resolves
        // to no target at all rather than to a swap
        moveTilingWindow(windows[2], cursor: CGPoint(x: 1500, y: 600))

        assertEquals(workspace.rootTilingContainer.layoutDescription,
                     .h_master([.window(1), .window(2), .window(3), .window(4)]))
    }

    func testDroppingIntoAMasterContainerFromANestedContainer() async throws {
        let (workspace, _) = masterWorkspace(focus.workspace.name, windowCount: 2)
        let nested = TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1)
        let nestedWindow = TestWindow.new(id: 3, parent: nested)
        try await workspace.layoutWorkspace()

        moveTilingWindow(nestedWindow, cursor: CGPoint(x: 500, y: 100))

        // The emptied nested container is left behind for the next normalizeContainers() pass to collect
        assertEquals(workspace.rootTilingContainer.layoutDescription,
                     .h_master([.window(3), .window(1), .window(2), .v_tiles([])]))
    }

    func testADragBackToWhereItStartedChangesNothing() async throws {
        let (workspace, windows) = try await stackWorkspace()
        let before = workspace.rootTilingContainer.layoutDescription

        // The tree isn't touched while the drag is in flight, so wandering over the master area and back again
        // leaves nothing behind. windows[1]'s own slot no longer reports a rect while it is being dragged, so the
        // cursor finds no drop target there
        beginTilingDrag(windows[1])
        commitTilingDragIfNeeded(cursor: CGPoint(x: 1500, y: 200))

        assertEquals(workspace.rootTilingContainer.layoutDescription, before)
    }

    func testTheDragIsAppliedWhereTheCursorIsReleased() async throws {
        let (workspace, windows) = try await stackWorkspace()

        beginTilingDrag(windows[3])
        // Only the release position matters, so a quick flick lands the same as a slow drag
        commitTilingDragIfNeeded(cursor: CGPoint(x: 500, y: 100))

        assertEquals(workspace.rootTilingContainer.layoutDescription,
                     .h_master([.window(4), .window(1), .window(2), .window(3)]))
        assertNil(currentlyDraggedWithMouseWindowId)
    }

    func testLivePreviewRearrangesBeforeRelease() async throws {
        config.liveDragPreview = true
        let (workspace, windows) = try await stackWorkspace()

        beginTilingDrag(windows[3])
        previewTilingDrag(windows[3], cursor: CGPoint(x: 500, y: 100)) // over the master area

        // With the flag on the tree changes while the drag is still in flight
        assertEquals(workspace.rootTilingContainer.layoutDescription,
                     .h_master([.window(4), .window(1), .window(2), .window(3)]))
    }

    func testLivePreviewIsProvisional() async throws {
        config.liveDragPreview = true
        let (workspace, windows) = try await stackWorkspace()
        let before = workspace.rootTilingContainer.layoutDescription

        beginTilingDrag(windows[3])
        previewTilingDrag(windows[3], cursor: CGPoint(x: 500, y: 100)) // promote to master
        assertNotEquals(workspace.rootTilingContainer.layoutDescription, before)

        // Wander back to where the drag started. The cursor is then over the slot the window came from, which
        // resolves to no drop target at all, so only rebuilding the pre-drag arrangement can bring the layout back.
        // (Previews that do land on a target converge on their own, because a drop is expressed relative to the
        // window under the cursor and that window's identity doesn't shift.)
        previewTilingDrag(windows[3], cursor: CGPoint(x: 1500, y: 900))
        commitTilingDragIfNeeded(cursor: CGPoint(x: 1500, y: 900))

        assertEquals(workspace.rootTilingContainer.layoutDescription, before)
    }

    func testLivePreviewIsOffByDefault() async throws {
        let (workspace, windows) = try await stackWorkspace()
        let before = workspace.rootTilingContainer.layoutDescription

        beginTilingDrag(windows[3])
        previewTilingDrag(windows[3], cursor: CGPoint(x: 500, y: 100))

        assertEquals(workspace.rootTilingContainer.layoutDescription, before)
    }

    func testNonMasterContainersStillSwap() async throws {
        let workspace = focus.workspace
        let container = workspace.rootTilingContainer
        let windows = (1 ... 3).map { TestWindow.new(id: UInt32($0), parent: container) }
        try await workspace.layoutWorkspace()

        // 'tiles' keeps the upstream behavior: the two windows trade places, nothing shifts along
        moveTilingWindow(windows[2], cursor: CGPoint(x: 100, y: 500))

        assertEquals(container.layoutDescription, .h_tiles([.window(3), .window(2), .window(1)]))
    }
}

// =========================================================== Helpers

/// Mirrors the placeholder that `MasterCmdArgs` reports for its mandatory positional argument
private let masterActionPlaceholderForTests = """
    (swap-with-master|focus-master|rotate-next|rotate-prev|add-master|remove-master|\
    set-count <count>|set-fraction <percent>|set-orientation <orientation>)
    """


@MainActor
private func root(_ workspaceName: String) -> TilingContainer {
    Workspace.get(byName: workspaceName).rootTilingContainer
}

/// A workspace whose tiling root is a `master` container holding `windowCount` windows with ids `1...windowCount`
@MainActor
final class MasterMinimumSizeTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testAWindowThatRefusesToShrinkGetsItsRoomFromTheOthers() async throws {
        let (workspace, windows) = masterWorkspace(focus.workspace.name, windowCount: 4)
        // Three stack windows share a 1079pt column, so ~360 each. This one won't go below 500
        windows[1].minObservedSize = CGSize(width: 0, height: 500)
        try await workspace.layoutWorkspace()

        assertApproxEquals(windows[1].lastAppliedLayoutPhysicalRect.orDie().height, 500)
        // The other two give up the difference between them, and the column is still exactly filled
        let heights = [windows[2], windows[3]].map { $0.lastAppliedLayoutPhysicalRect.orDie().height }
        assertApproxEquals(heights[0], 289.5)
        assertApproxEquals(heights[1], 289.5)
        assertApproxEquals(heights.reduce(500, +), 1079)
    }

    func testMinimumsThatCannotFitLeaveTheLayoutAlone() async throws {
        let (workspace, windows) = masterWorkspace(focus.workspace.name, windowCount: 3)
        // Two stack windows, each insisting on more than the whole column. Nothing avoids an overlap, so the
        // ordinary proportional split is what they get
        windows[1].minObservedSize = CGSize(width: 0, height: 900)
        windows[2].minObservedSize = CGSize(width: 0, height: 900)
        try await workspace.layoutWorkspace()

        assertApproxEquals(windows[1].lastAppliedLayoutPhysicalRect.orDie().height, 539.5)
        assertApproxEquals(windows[2].lastAppliedLayoutPhysicalRect.orDie().height, 539.5)
    }

    func testAnUnconstrainedColumnIsUnaffected() async throws {
        let (workspace, windows) = masterWorkspace(focus.workspace.name, windowCount: 3)
        try await workspace.layoutWorkspace()

        assertApproxEquals(windows[1].lastAppliedLayoutPhysicalRect.orDie().height, 539.5)
        assertApproxEquals(windows[2].lastAppliedLayoutPhysicalRect.orDie().height, 539.5)
    }
}

@MainActor
private func masterWorkspace(
    _ workspaceName: String,
    windowCount: Int,
    orientation: MasterOrientation = .left,
    count: Int = 1,
    fraction: CGFloat = 0.55,
) -> (Workspace, [TestWindow]) {
    let workspace = Workspace.get(byName: workspaceName)
    let container = workspace.rootTilingContainer
    container.layout = .master
    container.setOrientationDirectly(orientation.axis)
    container.master = MasterState(placement: orientation.placement, count: count, fraction: fraction)
    let windows = (1 ... windowCount).map { TestWindow.new(id: UInt32($0), parent: container) }
    return (workspace, windows)
}

/// Runs the same binding logic that a freshly detected window goes through
@MainActor
private func newTilingWindow(id: UInt32, on workspace: Workspace) async throws {
    // relayoutWindow unbinds the window first, so the initial parent doesn't influence where it lands
    let window = TestWindow.new(id: id, parent: workspace.rootTilingContainer)
    try await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
}

@MainActor
private func assertApproxEquals(
    _ actual: CGFloat,
    _ expected: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line,
) {
    if abs(actual - expected) > 0.0001 {
        failExpectedActual(expected, actual, file: file, line: line)
    }
}

extension TestWindow {
    /// `focusWindow` plus the assertion that it worked, so tests read as one line
    @MainActor
    fileprivate static func focus(_ window: TestWindow) -> Bool { window.focusWindow() }
}

@MainActor
private func assertRect(
    _ window: TestWindow,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line,
) {
    guard let rect = window.lastAppliedLayoutPhysicalRect else {
        failExpectedActual("a laid out window", "\(window) was never laid out", file: file, line: line)
        return
    }
    let actual = [rect.topLeftX, rect.topLeftY, rect.width, rect.height]
    let expected = [x, y, width, height]
    if zip(actual, expected).contains(where: { abs($0 - $1) > 0.001 }) {
        failExpectedActual(
            "\(window) at (x: \(x), y: \(y), width: \(width), height: \(height))",
            "\(window) at (x: \(rect.topLeftX), y: \(rect.topLeftY), width: \(rect.width), height: \(rect.height))",
            file: file,
            line: line,
        )
    }
}
