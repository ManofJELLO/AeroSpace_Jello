@testable import AppBundle
import Testing

@MainActor
@Suite(.serializedGlobally)
struct NativeTabSwapTest {
    @Test func testSwitchingToUnseenTabIsASwap() {
        let swap = detectNativeTabSwap(
            lastRefresh: [1: .alive],
            thisRefresh: [1: .invisible, 2: .alive],
            hasOpaqueWindowId: { $0 == 1 },
        )
        assertEquals(swap?.backgroundTabId, 1)
        assertEquals(swap?.frontmostTabId, 2)
    }

    /// The tab swapped out earlier gave its identity to its replacement, so coming back it has none
    @Test func testSwitchingBackToPreviousTabIsASwap() {
        let swap = detectNativeTabSwap(
            lastRefresh: [2: .alive],
            thisRefresh: [1: .alive, 2: .invisible],
            hasOpaqueWindowId: { $0 == 2 },
        )
        assertEquals(swap?.backgroundTabId, 2)
        assertEquals(swap?.frontmostTabId, 1)
    }

    /// Regression test: Chrome's throwaway window for the animation out of macOS native fullscreen (2) dies as the
    /// real window (1) comes back. Treating that as a swap gave the real window a new identity, and the layout
    /// snapshot went down with the old one
    @Test func testRealWindowReturningAsThrowawayWindowDiesIsNotASwap() {
        let swap = detectNativeTabSwap(
            lastRefresh: [1: .invisible, 2: .alive],
            thisRefresh: [1: .alive],
            hasOpaqueWindowId: { _ in true },
        )
        assertNil(swap)
    }

    /// The same shape comes from switching macOS Spaces between two windows of one app
    @Test func testTwoKnownWindowsTradingVisibilityIsNotASwap() {
        let swap = detectNativeTabSwap(
            lastRefresh: [1: .alive, 2: .invisible],
            thisRefresh: [1: .invisible, 2: .alive],
            hasOpaqueWindowId: { _ in true },
        )
        assertNil(swap)
    }

    @Test func testNothingChangedIsNotASwap() {
        let swap = detectNativeTabSwap(
            lastRefresh: [1: .alive],
            thisRefresh: [1: .alive],
            hasOpaqueWindowId: { _ in true },
        )
        assertNil(swap)
    }

    @Test func testAmbiguousChangeIsNotASwap() {
        let swap = detectNativeTabSwap(
            lastRefresh: [1: .alive, 2: .alive],
            thisRefresh: [1: .invisible, 2: .invisible, 3: .alive],
            hasOpaqueWindowId: { $0 != 3 },
        )
        assertNil(swap)
    }
}
