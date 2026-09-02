@testable import AppBundle
import XCTest

final class AxFrameCacheTest: XCTestCase {
    private let frame = AxFrame(topLeft: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 100))
    private let other = AxFrame(topLeft: CGPoint(x: 50, y: 50), size: CGSize(width: 100, height: 100))

    func testASettledWindowIsLeftAlone() {
        XCTAssertTrue(canSkipFrameWrite(request: frame, lastRequest: frame, lastObserved: frame, current: frame))
    }

    func testANewRequestIsAlwaysWritten() {
        XCTAssertFalse(canSkipFrameWrite(request: other, lastRequest: frame, lastObserved: frame, current: frame))
    }

    func testAWindowThatDriftedIsPutBack() {
        // Same request as last time, but the window is no longer where we last saw it: an app moved or resized
        // itself, and the layout has to correct it
        XCTAssertFalse(canSkipFrameWrite(request: frame, lastRequest: frame, lastObserved: frame, current: other))
    }

    func testAWindowThatRoundedTheSizeItselfStillSettles() {
        // A terminal snapping to whole character cells never lands exactly on the requested size. Comparing the
        // request against the observed frame would rewrite it on every pass; comparing observed against observed
        // recognises that it has settled
        let rounded = AxFrame(topLeft: frame.topLeft, size: CGSize(width: 93, height: 97))
        XCTAssertTrue(canSkipFrameWrite(request: frame, lastRequest: frame, lastObserved: rounded, current: rounded))
    }

    func testTheFirstWriteToAWindowIsNeverSkipped() {
        XCTAssertFalse(canSkipFrameWrite(request: frame, lastRequest: nil, lastObserved: nil, current: frame))
    }
}
