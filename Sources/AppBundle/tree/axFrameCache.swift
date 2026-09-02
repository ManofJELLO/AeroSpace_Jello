import AppKit

/// A window frame as the AX API deals with it. Either half may be absent, because callers set position and size
/// independently
// periphery:ignore - both fields are read by the synthesized Equatable, which periphery doesn't follow
struct AxFrame: Equatable {
    let topLeft: CGPoint?
    let size: CGSize?
}

/// Whether asking for `request` again would be a no-op.
///
/// Both halves are needed. `request == lastRequest` says the layout wants nothing new. `lastObserved == current`
/// says nothing has moved the window since we last looked, so a window an app resized itself, or that drifted for
/// any other reason, is still put back.
///
/// Comparing the *observed* frame rather than the requested one is what makes this work for an app that can only
/// take certain sizes -- a terminal snapping to whole character cells never lands exactly where it was asked to,
/// and comparing against the request would rewrite it on every single layout pass, forever
func canSkipFrameWrite(request: AxFrame, lastRequest: AxFrame?, lastObserved: AxFrame?, current: AxFrame) -> Bool {
    request == lastRequest && lastObserved == current
}
