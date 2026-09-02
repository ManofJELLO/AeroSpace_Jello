import AppKit
import Common

enum GlobalObserver {
    private static func onNotif(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if app?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        let pid = app?.processIdentifier
        Task.startUnstructured { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                // An activation we asked for ourselves. The model already reflects it, and the tree is unchanged, so
                // the layout passes would only rewrite the frames that are on screen already
                // Only the duplicate pre-layout pass is dropped. Skipping the layout outright would starve any
                // layout still pending when our own activation arrives, and leave windows where they were put
                let selfInflicted = consumeSelfInflictedActivation(pid)
                scheduleCancellableCompleteRefreshSession(
                    .globalObserver(notifName),
                    optimisticallyPreLayoutWorkspaces: !selfInflicted,
                )
            } else {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.app.isHiddenApp,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { @MainActor event in
            lastMouseDown = event.locationInWindow.withYAxisFlipped
        }

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { @MainActor event in
            // Taken from the event, synchronously. Reading NSEvent.mouseLocation inside the task below gives
            // wherever the pointer has travelled to by the time the main actor gets round to it, which after a quick
            // flick is nowhere near where the button was actually released
            let cursor = event.locationInWindow.withYAxisFlipped
            // Armed synchronously, before the task below runs: a move notification can arrive before the release has
            // even been processed, and it needs to find the position waiting for it
            armLateDrag(releasedAt: cursor)
            // todo reduce number of refreshSession in the callback
            Task.startUnstructured { @MainActor in
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                if currentlyManipulatedWithMouseWindowId != nil {
                    // The drag was recognised in time, so nothing is waiting on a late notification
                    _ = consumeLateDrag()
                    // Apply the drop and lay it out in one session. Merely scheduling the layout would leave it
                    // cancellable, and the pointer is usually still moving right after a drag, so the next
                    // focus-follows-mouse event would cancel it and the dropped window would sit where it was
                    // released until something unrelated happened to trigger a layout
                    _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                        commitTilingDragIfNeeded(cursor: cursor)
                        // Cleared inside the session, before it lays out: the layout skips whichever window the
                        // mouse is holding, so the dropped one would be left behind otherwise
                        clearMouseManipulationState()
                    }
                }
                let clickedMonitor = cursor.monitorApproximation
                switch true {
                    // Detect clicks on desktop of different monitors
                    case clickedMonitor.visibleRect.contains(cursor) && clickedMonitor.activeWorkspace != focus.workspace:
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.activeWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        }
    }
}
