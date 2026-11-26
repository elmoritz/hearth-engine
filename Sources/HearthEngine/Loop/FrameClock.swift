/// Engine time from display-link targets: absolute, never accumulated (E-TIME-2..4, pitfalls 4.1 and 4.2).
///
/// `time` is `start + (target - origin)`, where `origin` is the first target the clock saw, recomputed from the
/// absolute values on every step, so a million steps carry no summed rounding. `dt` is the difference of
/// successive targets, clamped to `0...maximumStep`. A gap past the clamp, or a target that goes backwards, sets
/// `discontinuity` for that step: whatever keeps cosmetic state between frames (particles, tweens) resets on it
/// instead of replaying the gap. One call is one step whatever the gap: there is no catch-up loop.
public struct FrameClock: Sendable, Hashable {
    /// The largest `dt` a step reports, in seconds.
    public static let maximumStep = 0.1

    /// Engine time at the first target.
    public let start: EngineTime
    /// Engine time at the latest target.
    public private(set) var time: EngineTime
    /// Seconds since the previous target, clamped; 0 on the first step.
    public private(set) var dt: Double = 0
    /// The latest step jumped (past `maximumStep`) or went backwards.
    public private(set) var discontinuity = false
    /// Steps taken, for audits: one per accepted target.
    public private(set) var steps = 0

    private var origin: Double?
    private var previous: Double?

    public init(start: EngineTime = .zero) {
        self.start = start
        time = start
    }

    /// Takes one step to `target`, a display-link target timestamp in seconds. A non-finite target is ignored.
    public mutating func advance(to target: Double) {
        guard target.isFinite else { return }
        steps += 1
        guard let origin, let previous else {
            self.origin = target
            self.previous = target
            time = start
            dt = 0
            discontinuity = false
            return
        }
        let raw = target - previous
        discontinuity = raw < 0 || raw > FrameClock.maximumStep
        dt = Swift.min(Swift.max(raw, 0), FrameClock.maximumStep)
        time = EngineTime(seconds: start.seconds + (target - origin))
        self.previous = target
    }
}
