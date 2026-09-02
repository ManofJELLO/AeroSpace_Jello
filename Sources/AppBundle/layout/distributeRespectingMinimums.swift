import AppKit
import Common

/// Splits `available` between slots whose relative sizes are `shares`, while giving any slot at least its entry in
/// `minimums`.
///
/// A window can refuse to be made smaller -- Chrome will not go below about 375pt tall -- and an app that refuses
/// simply overlaps whatever is laid out after it. Handing that window the space it insists on, and taking it from
/// the windows that don't mind, is the only way to keep the column from overlapping itself.
///
/// Returns `nil` when there is nothing to do or nothing that can be done: no slot has a minimum, or the minimums
/// don't fit in `available` at all. The caller then splits the space proportionally, which overlaps -- but no
/// arrangement avoids overlapping once the minimums exceed the space, so it may as well be the ordinary one
func distributeRespectingMinimums(shares: [CGFloat], minimums: [CGFloat], available: CGFloat) -> [CGFloat]? {
    check(shares.count == minimums.count)
    if shares.isEmpty || available <= 0 { return nil }
    if minimums.allSatisfy({ $0 <= 0 }) { return nil }
    if minimums.reduce(0, +) > available { return nil }

    var pinned = [Bool](repeating: false, count: shares.count)
    var sizes = [CGFloat](repeating: 0, count: shares.count)
    // Pinning one slot takes space from the others, which can push another below its own minimum, so this repeats
    // until a pass pins nothing new. It terminates because `pinned` only ever grows
    while true {
        let takenByPinned = zip(minimums, pinned).filter { $0.1 }.map(\.0).reduce(0, +)
        let shareOfUnpinned = zip(shares, pinned).filter { !$0.1 }.map(\.0).reduce(0, +)
        guard shareOfUnpinned > 0 else {
            // Every slot is pinned. They fit, so hand out what is left over in proportion to the shares rather
            // than leaving the column short
            let slack = available - takenByPinned
            let totalShare = shares.reduce(0, +)
            guard totalShare > 0 else { return nil }
            return zip(shares, minimums).map { $1 + slack * $0 / totalShare }
        }
        let freeExtent = available - takenByPinned
        var pinnedSomething = false
        for i in shares.indices where !pinned[i] {
            sizes[i] = freeExtent * shares[i] / shareOfUnpinned
            if sizes[i] < minimums[i] {
                pinned[i] = true
                pinnedSomething = true
            }
        }
        for i in shares.indices where pinned[i] { sizes[i] = minimums[i] }
        if !pinnedSomething { return sizes }
    }
}
