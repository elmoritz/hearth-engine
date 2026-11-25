/// The engine's only notion of time: absolute seconds, injected by the caller (E-HAR-2).
///
/// Nothing in the engine reads a clock. The display-link adapter (the one file allowed to) and the harness produce
/// values of this type; every animated value is a function of one.
public struct EngineTime: Sendable, Hashable, Comparable {
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public static let zero = EngineTime(seconds: 0)

    public static func < (lhs: EngineTime, rhs: EngineTime) -> Bool {
        lhs.seconds < rhs.seconds
    }

    /// Position inside a loop of `period` seconds, in `[0, 1)`.
    ///
    /// Wrapped on the CPU from the absolute `Double` (E-TIME-1), so precision does not decay with uptime. A
    /// non-finite time or a period that is not positive and finite has no phase and returns 0.
    public func phase(period: Double) -> Double {
        guard seconds.isFinite, period.isFinite, period > 0 else { return 0 }
        let wrapped = seconds.truncatingRemainder(dividingBy: period)
        let positive = wrapped < 0 ? wrapped + period : wrapped
        let phase = positive / period
        // A tiny negative remainder plus the period rounds to the period itself: that is phase 0, not 1.
        return phase < 1 ? phase : 0
    }
}
