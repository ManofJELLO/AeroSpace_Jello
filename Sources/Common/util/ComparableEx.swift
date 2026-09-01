import AppKit

extension Comparable {
    public func until(incl bound: Self) -> ClosedRange<Self>? { self <= bound ? self ... bound : nil }
    public func until(excl bound: Self) -> Range<Self>? { self < bound ? self ..< bound : nil }

    public func coerceIn(_ range: ClosedRange<Self>) -> Self {
        switch true {
            case self > range.upperBound: range.upperBound
            case self < range.lowerBound: range.lowerBound
            default: self
        }
    }
}
