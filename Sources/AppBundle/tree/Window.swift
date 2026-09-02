import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard
    /// Set while the mouse has this window out from under the layout.
    ///
    /// An app reports its window's position through AX asynchronously, so just after a drag the frame cache can
    /// still be holding the position from before it. Skipping the write on that basis would leave the window
    /// wherever the drag dropped it, off the grid, until something else happened to move it
    var needsUnconditionalFrameWrite: Bool = false
    /// The size this window has been seen to refuse to shrink below, learned by asking for less and reading back
    /// what actually happened. Chrome will not go below about 375pt tall, and an app that refuses simply overlaps
    /// whatever is laid out after it
    var minObservedSize: CGSize = .zero

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { die("Not implemented") }
    func getTitle(_ cm: CancellationMode) async throws -> String { die("Not implemented") }
    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    var isHiddenInCorner: Bool { die("Not implemented") }
    @MainActor func nativeFocus() { nativeFocus(raise: true) }
    /// `raise: false` gives the window keyboard focus without pulling it in front of its app's other windows.
    /// Used by focus-follows-mouse, where raising on hover is usually unwanted
    @MainActor func nativeFocus(raise: Bool) { die("Not implemented") }
    /// Puts this window back on top of its app's other windows, without touching focus
    @MainActor func nativeRaise() { die("Not implemented") }
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? { die("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }
}

/// How far off a requested size has to land before it counts as the app refusing rather than rounding
let axSizeRefusalTolerance: CGFloat = 2

extension Window {
    /// Records what came back from asking this window for `requested`.
    ///
    /// Bigger than asked for means the app has a minimum here. Anything it does accept is an upper bound on that
    /// minimum, so a window whose minimum shrinks -- a browser losing its bookmarks bar, say -- stops being given
    /// space it no longer needs
    @MainActor
    func noteSizeResponse(requested: CGSize, observed: CGSize) {
        func learn(_ requested: CGFloat, _ observed: CGFloat, _ recorded: CGFloat) -> CGFloat {
            observed > requested + axSizeRefusalTolerance ? observed : min(recorded, observed)
        }
        minObservedSize = CGSize(
            width: learn(requested.width, observed.width, minObservedSize.width),
            height: learn(requested.height, observed.height, minObservedSize.height),
        )
    }

    /// What this window insists on along `orientation`
    @MainActor
    func minObservedExtent(_ orientation: Orientation) -> CGFloat {
        orientation == .h ? minObservedSize.width : minObservedSize.height
    }
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: NonLeafTreeNodeKind)
}

extension Window {
    var isFloating: Bool { // todo drop. It will be a source of bugs when sticky is introduced
        switch windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .tilingContainer: false
            case .unbound: false
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}
