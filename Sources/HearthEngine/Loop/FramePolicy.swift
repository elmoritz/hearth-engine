/// How hot the device is, as `ProcessInfo.ThermalState` reports it. Ordered: a later case is hotter.
public enum ThermalLevel: Int, Sendable, Hashable, Comparable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What the content on screen does when nobody touches it.
public enum ContentMotion: Sendable, Hashable, CaseIterable {
    /// Nothing changes until the host says so (`FrameLoop.setNeedsFrame`).
    case still
    /// Slow ambience moves: sway, smoke, grade drift.
    case ambient
}

/// A frame-rate request in frames per second, as `CAFrameRateRange` takes it. `minimum <= preferred <= maximum`.
public struct FrameRateRange: Sendable, Hashable {
    public var minimum: Float
    public var maximum: Float
    public var preferred: Float

    public init(minimum: Float, maximum: Float, preferred: Float) {
        self.minimum = minimum
        self.maximum = maximum
        self.preferred = preferred
    }

    /// The same range with every bound at most `cap`.
    func capped(at cap: Float) -> FrameRateRange {
        FrameRateRange(minimum: Swift.min(minimum, cap), maximum: Swift.min(maximum, cap), preferred: Swift.min(preferred, cap))
    }
}

/// What the content needs from the display: nothing, or a range. `ambience` says whether ambient effects run.
public enum FrameRate: Sendable, Hashable {
    case paused
    case running(FrameRateRange, ambience: Bool)
}

/// The inputs of the frame-rate policy (D3).
public struct FrameConditions: Sendable, Hashable {
    public var interacting: Bool
    public var motion: ContentMotion
    public var lowPower: Bool
    public var thermal: ThermalLevel
    /// The host allows above 60 Hz while interacting (ProMotion; on iPhone it also needs the plist key, E-PLIST-1).
    public var highRateAllowed: Bool

    public init(
        interacting: Bool = false, motion: ContentMotion = .still, lowPower: Bool = false,
        thermal: ThermalLevel = .nominal, highRateAllowed: Bool = false
    ) {
        self.interacting = interacting
        self.motion = motion
        self.lowPower = lowPower
        self.thermal = thermal
        self.highRateAllowed = highRateAllowed
    }
}

/// The frame-rate policy of D3 (`research/performance-and-power.md` section 2): a pure table (E-RATE-1).
public enum FramePolicy {
    public static let ambience = FrameRateRange(minimum: 10, maximum: 30, preferred: 20)
    public static let interaction = FrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    public static let highRateInteraction = FrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    /// The cap under Low Power Mode and thermal `.serious`.
    public static let reducedCap: Float = 30
    /// The cap under thermal `.critical`, where ambient effects stop.
    public static let criticalCap: Float = 15

    public static func rate(for conditions: FrameConditions) -> FrameRate {
        let ambience = conditions.thermal < .critical
        let base: FrameRateRange
        if conditions.interacting {
            base = conditions.highRateAllowed ? highRateInteraction : interaction
        } else if conditions.motion == .ambient && ambience {
            base = FramePolicy.ambience
        } else {
            return .paused
        }
        var cap = Float.infinity
        if conditions.lowPower || conditions.thermal >= .serious {
            cap = reducedCap
        }
        if conditions.thermal >= .critical {
            cap = criticalCap
        }
        return .running(base.capped(at: cap), ambience: ambience)
    }
}
