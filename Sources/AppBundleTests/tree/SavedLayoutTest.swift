@testable import AppBundle
import XCTest

@MainActor
final class SavedLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testTheTreeSurvivesARoundTripThroughJson() throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        root.layout = .master
        root.master = MasterState(placement: .end, count: 2, fraction: 0.63)
        TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
        let nested = TilingContainer(parent: root, adaptiveWeight: 2, .v, .tiles, index: INDEX_BIND_LAST)
        TestWindow.new(id: 2, parent: nested, adaptiveWeight: 1)
        TestWindow.new(id: 3, parent: nested, adaptiveWeight: 3)

        let saved = SavedWorkspace(name: workspace.name, root: FrozenContainer(root), floatingWindowIds: [9])
        let decoded = try JSONDecoder().decode(SavedWorkspace.self, from: JSONEncoder().encode(saved))

        assertEquals(decoded.name, workspace.name)
        assertEquals(decoded.floatingWindowIds, [9])
        assertEquals(decoded.root.layout, .master)
        // The master settings are the part most easily lost in serialization, and losing them silently reverts a
        // configured master layout to its defaults on every restart
        assertEquals(decoded.root.master, MasterState(placement: .end, count: 2, fraction: 0.63))
        assertEquals(decoded.root.children.count, 2)
        switch decoded.root.children[1] {
            case .container(let c):
                assertEquals(c.orientation, .v)
                assertEquals(c.weight, 2)
                assertEquals(c.children.count, 2)
                switch c.children[1] {
                    case .window(let w):
                        assertEquals(w.id, 3)
                        assertEquals(w.weight, 3)
                    case .container: XCTFail("expected a window")
                }
            case .window: XCTFail("expected a container")
        }
    }

    func testARebuiltTreeMatchesTheOneItWasSavedFrom() throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        root.layout = .tiles
        TestWindow.new(id: 1, parent: root)
        let nested = TilingContainer(parent: root, adaptiveWeight: 1, .v, .tiles, index: INDEX_BIND_LAST)
        TestWindow.new(id: 2, parent: nested)
        TestWindow.new(id: 3, parent: nested)

        let frozen = FrozenContainer(root)
        let encoded = try JSONEncoder().encode(frozen)
        let decoded = try JSONDecoder().decode(FrozenContainer.self, from: encoded)

        // Flatten both to the same shape: what matters is that the ids come back in the same nesting
        func shape(_ node: FrozenTreeNode) -> String {
            switch node {
                case .window(let w): "\(w.id)"
                case .container(let c): "(" + c.children.map(shape).joined(separator: " ") + ")"
            }
        }
        assertEquals(shape(.container(decoded)), shape(.container(frozen)))
        assertEquals(shape(.container(decoded)), "(1 (2 3))")
    }
}
