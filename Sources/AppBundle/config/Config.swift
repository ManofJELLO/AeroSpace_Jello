import AppKit
import Common
import HotKey
import OrderedCollections

func getDefaultConfigUrlFromProject() -> URL {
    var url = URL(filePath: #filePath)
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    let projectRoot: URL = url
    return projectRoot.appending(component: "docs/config-examples/default-config.toml")
}

var defaultConfigUrl: URL {
    if isUnitTest {
        return getDefaultConfigUrlFromProject()
    } else {
        return Bundle.main.url(forResource: "default-config", withExtension: "toml")
            // Useful for debug builds that are not app bundles
            ?? getDefaultConfigUrlFromProject()
    }
}
@MainActor let defaultConfig: Config = {
    let parsedConfig = parseConfig(Result { try String(contentsOf: defaultConfigUrl, encoding: .utf8) }.getOrDie())
    if !parsedConfig.errors.isEmpty {
        die("Can't parse default config: \(parsedConfig.errors)")
    }
    return parsedConfig.config
}()
@MainActor var config: Config = defaultConfig // todo move to Ctx?
@MainActor var configUrl: URL = defaultConfigUrl

struct Config: ConvenienceMutable {
    var configVersion: ConfigVersion = ._1
    var _afterLoginCommand: [any Command] = []
    var afterStartupCommand: Shell<any Command> = .empty
    var _indentForNestedContainersWithTheSameOrientation: Void = ()
    var enableNormalizationFlattenContainers: Bool = true
    var _nonEmptyWorkspacesRootContainersLayoutOnStartup: Void = ()
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var startAtLogin: Bool = false
    var autoReloadConfig: Bool = false
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var preserveLayoutOnMacosNativeFullscreen: Bool = true
    var accordionPadding: Int = 30
    /// Rearrange the layout while a window is being dragged, instead of only when the button is released.
    /// The preview is provisional: dragging back to where you started restores the original arrangement
    var liveDragPreview: Bool = false
    /// Keep floating windows above tiled ones, across apps. Off leaves stacking entirely to macOS, which layers by
    /// app, so focusing any window of another app buries every floating window
    var floatingWindowsOnTop: Bool = true
    var master: MasterConfig = MasterConfig()
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var persistentWorkspaces: OrderedSet<String> = []
    var execOnWorkspaceChange: [String] = [] // todo deprecate
    var keyMapping = KeyMapping()
    var execConfig: ExecConfig = ExecConfig()
    var focusFollowsMouse: FocusFollowsMouse = FocusFollowsMouse()

    var onFocusChanged: Shell<any Command> = .empty
    // var onFocusedWorkspaceChanged: [any Command] = []
    var onFocusedMonitorChanged: Shell<any Command> = .empty

    var gaps: Gaps = .zero
    var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]
    var modes: [String: Mode] = [:]
    var onWindowDetected: [WindowDetectedCallback] = []
    var onModeChanged: Shell<any Command> = .empty
}

struct FocusFollowsMouse: ConvenienceMutable {
    var enabled: Bool = false
    /// How long the pointer has to rest over a window before it takes focus. `0` focuses on the first mouse move.
    /// Equivalent to AutoRaise's `focusDelay`, but in milliseconds rather than poll ticks
    var delayMs: Int = 0
    /// Whether the window is also pulled in front of its app's other windows. Equivalent to AutoRaise's `delay`,
    /// where `0` means "focus but never raise"
    var raise: Bool = true
    /// Hold this modifier to suspend focus-follows-mouse. Equivalent to AutoRaise's `disableKey`
    var disableKey: FocusFollowsMouseDisableKey = .none
}

enum FocusFollowsMouseDisableKey: String, CaseIterable, Equatable, Sendable {
    case none, control, option, command, shift
}

extension FocusFollowsMouseDisableKey {
    private var modifier: NSEvent.ModifierFlags? {
        switch self {
            case .none: nil
            case .control: .control
            case .option: .option
            case .command: .command
            case .shift: .shift
        }
    }

    var isHeld: Bool { modifier.map { NSEvent.modifierFlags.contains($0) } ?? false }
}

/// Defaults for the `master` layout. See https://nikitabobko.github.io/AeroSpace/guide#layouts
///
/// These values seed newly created `master` containers. Once a container exists, the `master` command changes it
/// directly, and the container keeps its own values until the config is reloaded
struct MasterConfig: ConvenienceMutable, Equatable, Sendable {
    /// Where the master area sits. Also decides the container orientation
    var orientation: MasterOrientation = .left
    /// How many windows the master area holds
    var count: Int = 1
    /// How much of the container the master area takes, in percent.
    /// An integer because TOML floats aren't supported by the config parser
    var fractionPercent: Int = 55
    /// `center` orientation needs at least this many stack windows before it kicks in.
    /// Mirrors Hyprland's `slave_count_for_center_master`, including that `0` means "always center"
    var centerStackThreshold: Int = 2
    /// Which side `center` falls back to when there are fewer stack windows than `centerStackThreshold`.
    /// Mirrors Hyprland's `center_master_fallback`. Never `center`
    var centerFallback: MasterOrientation = .left
    /// Where a newly detected window is inserted into a `master` container
    var newWindowPosition: MasterNewWindowPosition = .stackEnd

    var fraction: CGFloat { (CGFloat(fractionPercent) / 100).coerceIn(MASTER_MIN_FRACTION ... MASTER_MAX_FRACTION) }
}

enum MasterNewWindowPosition: String, CaseIterable, Equatable, Sendable {
    /// The new window becomes the master, the previous master is pushed to the top of the stack
    case master
    /// The new window is inserted at the top of the stack
    case stackStart = "stack-start"
    /// The new window is appended at the bottom of the stack
    case stackEnd = "stack-end"
    /// The new window is inserted right after the most recently focused window, in whichever group it lives.
    /// This is what non-master layouts do
    case afterFocused = "after-focused"
}

enum ConfigVersion: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible {
    case _1 = 1
    case _2 = 2

    static let max = allCases.max().orDie()
    static let min = allCases.min().orDie()
    static func < (lhs: ConfigVersion, rhs: ConfigVersion) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String { rawValue.description }
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}
