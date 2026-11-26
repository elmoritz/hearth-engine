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
        guard let wrapped = wrapped(period: period) else { return 0 }
        let phase = wrapped / period
        return phase < 1 ? phase : 0
    }

    /// Seconds into the current loop of `period`, in `[0, period)`, or nil when there is no loop.
    ///
    /// `fmod` on the absolute `Double` is exact, so a time `k * period` later gives the same value whenever both
    /// times are representable (E-TIME-1).
    func wrapped(period: Double) -> Double? {
        guard seconds.isFinite, period.isFinite, period > 0 else { return nil }
        let remainder = seconds.truncatingRemainder(dividingBy: period)
        let positive = remainder < 0 ? remainder + period : remainder
        // A tiny negative remainder plus the period rounds to the period itself: that is the loop's start.
        return positive < period ? positive : 0
    }

    /// The time a shader sees for a loop of `period` seconds: wrapped on the CPU, then `Float`, never `half`.
    ///
    /// The GPU never receives absolute time, so its precision does not decay with uptime (E-TIME-1, pitfall 4.1).
    /// No loop (a non-finite time, a period that is not positive and finite) gives 0.
    public func gpuSeconds(period: Double) -> Float {
        Float(wrapped(period: period) ?? 0)
    }

    /// The frame of a `count`-frame loop played at `framesPerSecond`, in `0..<count` (E-TIME-1).
    ///
    /// Computed from the absolute time, never accumulated. The `1e-6` frame epsilon absorbs the rounding of the
    /// wrap (under `1e-7` frames at 30 days and 120 fps), so a time exactly on a frame boundary is that frame at any
    /// uptime. A count below 1, a rate that is not positive and finite, or a non-finite time gives 0.
    public func frameIndex(framesPerSecond: Double, count: Int) -> Int {
        guard count > 0, framesPerSecond.isFinite, framesPerSecond > 0 else { return 0 }
        let period = Double(count) / framesPerSecond
        guard let wrapped = wrapped(period: period) else { return 0 }
        let frame = Int((wrapped * framesPerSecond + 1e-6).rounded(.down))
        return frame < count ? frame : 0
    }

    /// Progress of something that started at `start` and lasts `duration` seconds, clamped to `0...1`.
    ///
    /// However far time jumps, progress never passes 1 (E-TIME-4). A duration that is not positive and finite is
    /// already done (1); a non-finite time before or after the start gives 0 or 1.
    public func progress(since start: EngineTime, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 1 }
        let raw = (seconds - start.seconds) / duration
        guard !raw.isNaN else { return 0 }
        return Swift.min(Swift.max(raw, 0), 1)
    }
}
