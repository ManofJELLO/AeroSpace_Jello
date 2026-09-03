@testable import AppBundle
import AppKit

final class TestWindow: Window, CustomStringConvertible {
    private var _rect: Rect?
    var isMacosFullscreenForTest = false

    @MainActor
    private init(_ id: UInt32, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?, _ app: TestApp) {
        _rect = rect
        super.init(id: id, app, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(
        id: UInt32,
        parent: NonLeafTreeNodeObject,
        adaptiveWeight: CGFloat = 1,
        rect: Rect? = nil,
        app: TestApp = .shared,
    ) -> TestWindow {
        let wi = TestWindow(id, parent, adaptiveWeight, rect, app)
        app._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocus(raise: Bool) {
        // The window's own app, not TestApp.shared. A window belonging to TestApp.other would otherwise record its
        // focus against the wrong app, and any cross-app assertion would be checking a state production never has
        let app = self.app as! TestApp
        appForTests = app
        app.focusedWindow = self
    }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        _rect = Rect(
            topLeftX: topLeft?.x ?? _rect?.topLeftX ?? 0,
            topLeftY: topLeft?.y ?? _rect?.topLeftY ?? 0,
            width: size?.width ?? _rect?.width ?? 0,
            height: size?.height ?? _rect?.height ?? 0,
        )
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { description }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        _rect
    }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        _rect.map { CGSize(width: $0.width, height: $0.height) }
    }

    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { isMacosFullscreenForTest }
}
