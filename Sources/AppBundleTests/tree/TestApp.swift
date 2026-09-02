@testable import AppBundle
import Common

final class TestApp: AbstractApp {
    let pid: Int32
    let rawAppBundleId: String?
    let name: String?
    let execPath: String? = nil
    let bundlePath: String? = nil
    @MainActor
    static let shared = TestApp(pid: 0)
    /// A second app, for the tests that care which app a window belongs to
    @MainActor
    static let other = TestApp(pid: 1)

    private init(pid: Int32) {
        self.pid = pid
        self.rawAppBundleId = pid == 0 ? "bobko.AeroSpace.test-app" : "bobko.AeroSpace.test-app-\(pid)"
        self.name = rawAppBundleId
    }

    var isHiddenApp: Bool = false

    var _windows: [Window] = []
    var windows: [Window] {
        get { _windows }
        set {
            if let focusedWindow {
                check(newValue.contains(focusedWindow))
            }
            _windows = newValue
        }
    }

    private var _focusedWindow: Window? = nil
    var focusedWindow: Window? {
        get { _focusedWindow }
        set {
            if let window = newValue {
                check(windows.contains(window))
            }
            _focusedWindow = newValue
        }
    }
    @MainActor func getFocusedWindow(_ cm: CancellationMode) -> Window? { _focusedWindow }
}
