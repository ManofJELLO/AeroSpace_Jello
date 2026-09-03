import AppKit

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil
/// The newest pointer position that hasn't been acted on yet. Mouse moves arrive an order of magnitude faster than a
/// focus change can be carried out, so they are coalesced here instead of each one starting its own attempt
@MainActor private var pendingFocusFollowsLocation: CGPoint? = nil
/// The window the pointer is currently over, and when it entered. `delay-ms` is measured against this: how long the
/// pointer has been inside one window's region, not how long it has been holding still
@MainActor private var hoveredSince: (windowId: UInt32, since: ContinuousClock.Instant)? = nil

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
        hoveredSince = nil
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
@MainActor private var focusFollowsGeneration = 0

@MainActor private func startFocusFollowsMouseWorker() {
    if focusFollowsTask != nil { return }
    focusFollowsGeneration += 1
    let generation = focusFollowsGeneration
    focusFollowsTask = Task.startUnstructured { @MainActor in
        // Guarded, because a worker cancelled by a config reload finishes *after* the reload has already started a
        // replacement. Clearing unconditionally would drop the live worker's reference and let a second one start
        // alongside it, the two of them racing over the pending location
        defer { if focusFollowsGeneration == generation { focusFollowsTask = nil } }
        while let location = pendingFocusFollowsLocation {
            pendingFocusFollowsLocation = nil
            guard let remainingDwell = try await focusWindow(under: location) else { continue }
            try await Task.sleep(for: remainingDwell)
            // Re-examine where the pointer is now. It may well have come to rest inside the window, in which case no
            // further event is coming and the loop would otherwise exit with the dwell never finishing
            if pendingFocusFollowsLocation == nil { pendingFocusFollowsLocation = mouseLocation }
        }
    }
}

/// Returns how much longer the pointer has to stay in this window before focus should move, or `nil` when there is
/// nothing left to wait for
@MainActor private func focusWindow(under location: CGPoint) async throws -> Duration? {
    guard let token: RunSessionGuard = .isServerEnabled else { return nil }
    let settings = config.focusFollowsMouse
    if settings.disableKey.isHeld { return nil }
    try checkCancellation()

    // Work out the window from the model before touching the AX API. Hovering tiled windows needs no AX request at
    // all, and that is what lets focus keep up with a pointer that is still moving
    let workspace = location.monitorApproximation.activeWorkspace

    // A window macOS put in its own fullscreen space covers the whole screen, but it is no longer in the tiling
    // tree -- the windows it left behind are, laid out underneath it. Resolving the pointer against that tree would
    // focus one of them, and activating it yanks macOS straight back out of the fullscreen space. Checked per
    // workspace, so a fullscreen app on one monitor doesn't stop focus following the pointer on another
    if !workspace.macOsNativeFullscreenWindowsContainer.children.isEmpty {
        hoveredSince = nil
        return nil
    }

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
    guard let window, window != focus.windowOrNil else {
        hoveredSince = nil
        return nil
    }

    // 'delay-ms' asks the pointer to stay inside the window for that long -- not to stop moving. Waiting on the
    // pointer holding still reads as lag, and it punishes the ordinary way people move a mouse
    if settings.delayMs > 0 {
        let now = ContinuousClock.now
        let sameWindow = hoveredSince?.windowId == window.windowId
        let entered = sameWindow ? hoveredSince.orDie().since : now
        hoveredSince = (window.windowId, entered)
        let required = Duration.milliseconds(settings.delayMs)
        let dwelled = entered.duration(to: now)
        if dwelled < required { return required - dwelled }
    }
    hoveredSince = nil

    // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
    // todo: It would be cool to somehow reuse isWindowHeuristic logic here
    if await isAxWindowUnderMouse(location) == false { return nil }
    try checkCancellation()

    try await runLightSession(.focusFollowsMouse, token) {
        _ = window.focusWindow()
        // Activating the app makes macOS post didActivateApplicationNotification straight back at us. Claim it, so
        // that the observer doesn't answer our own focus change with a full re-layout of every workspace
        expectSelfInflictedActivation(of: window)
        window.nativeFocus(raise: settings.raise)
        noteFocusGivenTo(window)
    }
    return nil
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
