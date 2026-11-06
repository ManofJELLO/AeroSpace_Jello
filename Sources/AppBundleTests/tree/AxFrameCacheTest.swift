@testable import AppBundle
import AppKit
import Testing

@MainActor
@Suite(.serializedGlobally)
struct AxFrameCacheTest {
    private let frame = AxFrame(topLeft: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 100))
    private let other = AxFrame(topLeft: CGPoint(x: 50, y: 50), size: CGSize(width: 100, height: 100))

    @Test func testASettledWindowIsLeftAlone() {
        assertTrue(canSkipFrameWrite(request: frame, lastRequest: frame, lastObserved: frame, current: frame))
    }

    @Test func testANewRequestIsAlwaysWritten() {
        assertFalse(canSkipFrameWrite(request: other, lastRequest: frame, lastObserved: frame, current: frame))
    }

    @Test func testAWindowThatDriftedIsPutBack() {
        // Same request as last time, but the window is no longer where we last saw it: an app moved or resized
        // itself, and the layout has to correct it
        assertFalse(canSkipFrameWrite(request: frame, lastRequest: frame, lastObserved: frame, current: other))
    }

    @Test func testAWindowThatRoundedTheSizeItselfStillSettles() {
        // A terminal snapping to whole character cells never lands exactly on the requested size. Comparing the
        // request against the observed frame would rewrite it on every pass; comparing observed against observed
        // recognises that it has settled
        let rounded = AxFrame(topLeft: frame.topLeft, size: CGSize(width: 93, height: 97))
        assertTrue(canSkipFrameWrite(request: frame, lastRequest: frame, lastObserved: rounded, current: rounded))
    }

    @Test func testTheFirstWriteToAWindowIsNeverSkipped() {
        assertFalse(canSkipFrameWrite(request: frame, lastRequest: nil, lastObserved: nil, current: frame))
    }
}
