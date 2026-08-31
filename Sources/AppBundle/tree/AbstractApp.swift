import Common

protocol AbstractApp: AnyObject, Hashable, AeroAny {
    var pid: Int32 { get }
    var rawAppBundleId: String? { get }

    @MainActor func getFocusedWindow(_ cm: CancellationMode) async throws -> Window?
    var name: String? { get }
    var execPath: String? { get }
    var bundlePath: String? { get }

    /// Whether the owning macOS application is hidden (cmd-h).
    /// Declared on the protocol rather than reached through `macAppUnsafe` so that the
    /// non-fullscreen branches of `normalizeLayoutReason` are reachable from tests.
    var isHiddenApp: Bool { get }
}

extension AbstractApp {
    static func == (lhs: Self, rhs: Self) -> Bool {
        if lhs.pid == rhs.pid {
            check(lhs === rhs)
            return true
        } else {
            check(lhs !== rhs)
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }
}

extension Window {
    var macAppUnsafe: MacApp { app as! MacApp }
}
