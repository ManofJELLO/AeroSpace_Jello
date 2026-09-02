@testable import AppBundle
import XCTest

final class DistributeRespectingMinimumsTest: XCTestCase {
    private func assertSizes(_ actual: [CGFloat]?, _ expected: [CGFloat], line: UInt = #line) {
        guard let actual else { return XCTFail("expected a distribution, got nil", line: line) }
        XCTAssertEqual(actual.count, expected.count, line: line)
        for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 0.01, line: line) }
    }

    func testNoMinimumsFallsBackToTheOrdinarySplit() {
        XCTAssertNil(distributeRespectingMinimums(shares: [1, 1, 1], minimums: [0, 0, 0], available: 900))
    }

    func testTheConstrainedSlotGetsItsMinimumAndTheRestGiveItUp() {
        // Chrome's case: 1050 split three ways is 350 each, but the first refuses to go below 375
        assertSizes(distributeRespectingMinimums(shares: [1, 1, 1], minimums: [375, 0, 0], available: 1050),
                    [375, 337.5, 337.5])
    }

    func testASlotAlreadyBigEnoughIsLeftAlone() {
        // The minimum is under its proportional size, so nothing needs pinning
        assertSizes(distributeRespectingMinimums(shares: [1, 1], minimums: [300, 0], available: 1000),
                    [500, 500])
    }

    func testPinningOneSlotCanForceAnother() {
        // 900 across three is 300 each. Pinning the first at 500 leaves 400 for two, i.e. 200 each -- which pushes
        // the second below its own 250 minimum, so it has to be pinned too on a later pass
        assertSizes(distributeRespectingMinimums(shares: [1, 1, 1], minimums: [500, 250, 0], available: 900),
                    [500, 250, 150])
    }

    func testUnequalSharesAreHonouredAmongTheUnpinned() {
        // 1000 with the first pinned at 400 leaves 600, split 2:1 between the others
        assertSizes(distributeRespectingMinimums(shares: [1, 2, 1], minimums: [400, 0, 0], available: 1000),
                    [400, 400, 200])
    }

    func testMinimumsThatDontFitFallBack() {
        // No arrangement avoids an overlap here, so the caller may as well lay out the ordinary way
        XCTAssertNil(distributeRespectingMinimums(shares: [1, 1], minimums: [600, 600], available: 1000))
    }

    func testEverySlotPinnedStillFillsTheColumn() {
        // Both minimums fit but leave 200 spare; it goes out in proportion rather than leaving the column short
        assertSizes(distributeRespectingMinimums(shares: [1, 1], minimums: [400, 400], available: 1000),
                    [500, 500])
    }
}
