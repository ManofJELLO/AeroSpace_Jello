import AppKit

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil
/// The newest pointer position that hasn't been acted on yet. Mouse moves arrive an order of magnitude faster than a
/// focus change can be carried out, so they are coalesced here instead of each one starting its own attempt
@MainActor private var pendingFocusFollowsLocation: CGPoint? = nil

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    if config.focusFollowsMouse.enabled == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse.enabled {
        NSEvent.removeMonitor(focusFollowsMouseMonitor.orDie())
        focusFollowsMouseMonitor = nil
        focusFollowsTask?.cancel()
        focusFollowsTask = nil
        pendingFocusFollowsLocation = nil
        return
    }

    // Interestingly, this callback seems to not fire when the mouse is down which is good,
    // because this is how I want it to work for windows/tabs/files dragging
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @MainActor event in
        pendingFocusFollowsLocation = event.locationInWindow.withYAxisFlipped
        startFocusFollowsMouseWorker()
    }
}

/// Runs focus attempts one at a time, each one for the latest pointer position known when it starts.
///
/// A mouse move deliberately does *not* cancel the attempt already in flight. Cancelling meant an attempt only ever
/// ran to completion once the pointer came to a stop, because the next move always arrived first, so focus waited for
/// the pointer to stop instead of tracking where it was
@MainActor private func startFocusFollowsMouseWorker() {
    if focusFollowsTask != nil { return }
    focusFollowsTask = Task.startUnstructured { @MainActor in
        defer { focusFollowsTask = nil }
        while let location = pendingFocusFollowsLocation {
            pendingFocusFollowsLocation = nil
            try await focusWindow(under: location)
        }
    }
}

@MainActor private func focusWindow(under location: CGPoint) async throws {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    let settings = config.focusFollowsMouse
    if settings.delayMs > 0 {
        try await Task.sleep(for: .milliseconds(settings.delayMs))
        // A newer position arrived while we waited, so the pointer hasn't come to rest yet. Drop this attempt; the
        // worker loop immediately starts the wait over on the position that did arrive
        if pendingFocusFollowsLocation != nil { return }
    }
    // Checked after the delay, so releasing the key doesn't retroactively focus whatever you passed over
    if settings.disableKey.isHeld { return }
    try checkCancellation()

    // Work out the window from the model before touching the AX API. Hovering tiled windows needs no AX request at
    // all, and that is what lets focus keep up with a pointer that is still moving
    let workspace = location.monitorApproximation.activeWorkspace
    var window: Window? = nil
    for child in workspace.floatingWindowsContainer.mruChildren {
        try checkCancellation()
        guard let child = child as? Window else { continue }
        guard let rect = try await child.getAxRect(.cancellable) else { continue }
        if rect.contains(location) {
            window = child
            break
        }
    }
    if window == nil {
        window = location.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: true)
    }
    // Checked before the AX round trip below, because while the pointer crosses the window it is already on, this is
    // the answer almost every time
    guard let window, window != focus.windowOrNil else { return }

    // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
    // todo: It would be cool to somehow reuse isWindowHeuristic logic here
    if await isAxWindowUnderMouse(location) == false { return }
    try checkCancellation()

    try await runLightSession(.focusFollowsMouse, token) {
        _ = window.focusWindow()
        // Activating the app makes macOS post didActivateApplicationNotification straight back at us. Claim it, so
        // that the observer doesn't answer our own focus change with a full re-layout of every workspace
        expectSelfInflictedActivation(of: window)
        window.nativeFocus(raise: settings.raise)
        noteFocusGivenTo(window)
    }
}

@concurrent
private nonisolated func isAxWindowUnderMouse(_ location: CGPoint) async -> Bool? {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return nil
    }
    guard let element else { return nil }
    return element.get(Ax.parentWindowRecursive) != nil || element.get(Ax.roleAttr) == kAXWindowRole
}
