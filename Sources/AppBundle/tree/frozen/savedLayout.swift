import AppKit
import Common

/// The tiling layout written out when AeroSpace quits, so that a restart can put the windows back.
///
/// Restarting AeroSpace doesn't restart the apps it manages, so their windows keep their `CGWindowID`s across the
/// gap. That is what makes this possible at all: the saved tree refers to windows by id and finds the same windows
/// on the way back up. Without it every window is discovered fresh, assigned to whichever workspace its monitor is
/// showing, and the whole arrangement collapses onto one workspace -- which is what a `brew upgrade` used to do
struct SavedLayout: Codable {
    /// Discarded if the machine has rebooted since. Window ids are only unique within a boot, and a recycled id
    /// would otherwise put an unrelated window into the slot its predecessor held
    let bootTime: Int64
    let workspaces: [SavedWorkspace]
    /// Window id to the app that owned it, as a second check against a recycled id within one boot
    let windowApps: [String: String]
}

struct SavedWorkspace: Codable {
    let name: String
    let root: FrozenContainer
    let floatingWindowIds: [UInt32]
}

private let savedLayoutUrl: URL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(aeroSpaceAppId, isDirectory: true)
    .appendingPathComponent("layout.json")

@MainActor
func saveLayoutForRestart() {
    if !config.restoreLayoutOnRestart || serverArgs.isReadOnly { return }
    var windowApps: [String: String] = [:]
    for window in MacWindow.allWindowsMap.values {
        windowApps[String(window.windowId)] = window.app.identityForRestore
    }
    let saved = SavedLayout(
        bootTime: systemBootTime(),
        workspaces: Workspace.all.map {
            SavedWorkspace(
                name: $0.name,
                root: FrozenContainer($0.rootTilingContainer),
                floatingWindowIds: $0.floatingWindows.map(\.windowId),
            )
        },
        windowApps: windowApps,
    )
    do {
        try FileManager.default.createDirectory(
            at: savedLayoutUrl.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try JSONEncoder().encode(saved).write(to: savedLayoutUrl)
    } catch {
        // Losing the layout is a nuisance, not a reason to hold up a quit
    }
}

/// Puts the windows back where the previous run left them. Returns whether anything was restored, so that the
/// startup heuristic knows to keep its hands off the layout it just rebuilt
@MainActor
func restoreSavedLayout() -> Bool {
    if !config.restoreLayoutOnRestart || serverArgs.isReadOnly { return false }
    guard let saved = readSavedLayout() else { return false }
    // Consume it either way. A snapshot that survived one failed restore would keep being retried against a world
    // that has moved on
    try? FileManager.default.removeItem(at: savedLayoutUrl)
    guard saved.bootTime == systemBootTime() else { return false }

    // An id that now belongs to a different app means ids have been recycled, and nothing in the snapshot can be
    // trusted to refer to the window it was written for. Restoring part of it would scatter windows rather than
    // place them
    for (rawId, app) in saved.windowApps {
        guard let windowId = UInt32(rawId), let window = MacWindow.get(byId: windowId) else { continue }
        if window.app.identityForRestore != app { return false }
    }

    var restoredAnything = false
    for savedWorkspace in saved.workspaces {
        let workspace = Workspace.get(byName: savedWorkspace.name)
        let prevRoot = workspace.rootTilingContainer
        // Rebuild before detaching the old root, for the same reason restoreMacosFullscreenLayout does: the lookup
        // that finds each window walks down from the workspaces, so the windows have to stay reachable meanwhile
        restoreTreeRecursive(
            frozenContainer: savedWorkspace.root,
            parent: workspace,
            index: INDEX_BIND_LAST,
            skipUnrestorableWindows: true,
        )
        prevRoot.unbindFromParent()
        for windowId in savedWorkspace.floatingWindowIds {
            MacWindow.get(byId: windowId)?.bindAsFloatingWindow(to: workspace)
        }
        restoredAnything = restoredAnything
            || !workspace.rootTilingContainer.allLeafWindowsRecursive.isEmpty
            || !savedWorkspace.floatingWindowIds.isEmpty
    }
    return restoredAnything
}

@MainActor
private func readSavedLayout() -> SavedLayout? {
    guard let data = try? Data(contentsOf: savedLayoutUrl) else { return nil }
    return try? JSONDecoder().decode(SavedLayout.self, from: data)
}

extension AbstractApp {
    /// Enough to tell "the same app" from "a different app that inherited this window id"
    fileprivate var identityForRestore: String { rawAppBundleId ?? name ?? String(pid) }
}

/// Seconds since the epoch at which the machine booted
private func systemBootTime() -> Int64 {
    var tv = timeval()
    var size = MemoryLayout<timeval>.stride
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    let ok = unsafe sysctl(&mib, 2, &tv, &size, nil, 0) == 0
    return ok ? Int64(tv.tv_sec) : 0
}
