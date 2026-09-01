/// User facing description of how a `master` layout container is arranged.
///
/// It encodes both the axis along which the master area and the stack are split
/// (``Orientation``) and on which side of that axis the master area sits (``MasterPlacement``).
///
/// The names mirror Hyprland's `master:orientation` setting.
public enum MasterOrientation: String, CaseIterable, Equatable, Sendable {
    /// Master area on the left, stack on the right
    case left
    /// Master area on the right, stack on the left
    case right
    /// Master area on top, stack at the bottom
    case top
    /// Master area at the bottom, stack on top
    case bottom
    /// Master area in the middle, stack is split into a left and a right column
    case center
}

/// Where the master area sits along the container's ``Orientation`` axis
public enum MasterPlacement: String, CaseIterable, Equatable, Sendable {
    /// Left (for `.h`) or top (for `.v`)
    case start
    /// Right (for `.h`) or bottom (for `.v`)
    case end
    /// In the middle. The stack is split into two groups that flank the master area
    case center
}

extension MasterOrientation {
    public var axis: Orientation {
        switch self {
            case .left, .right, .center: .h
            case .top, .bottom: .v
        }
    }

    public var placement: MasterPlacement {
        switch self {
            case .left, .top: .start
            case .right, .bottom: .end
            case .center: .center
        }
    }

    public init(axis: Orientation, placement: MasterPlacement) {
        self = switch (placement, axis) {
            case (.center, _): .center
            case (.start, .h): .left
            case (.end, .h): .right
            case (.start, .v): .top
            case (.end, .v): .bottom
        }
    }

    /// The cycle that `aerospace master set-orientation next|prev` walks through, clockwise.
    /// Matches the order of Hyprland's `orientationnext`/`orientationprev`, which includes `center`
    public static let cycle: [MasterOrientation] = [.left, .top, .right, .bottom, .center]

    /// The orientations that `center` may fall back to. `center` itself is not one of them
    public static let fallbacks: [MasterOrientation] = [.left, .right, .top, .bottom]
}
