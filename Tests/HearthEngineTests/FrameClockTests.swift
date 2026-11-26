import HearthHarness
import Testing

@testable import HearthEngine

/// Time from display-link targets and its precision over days. No GPU, no clock: targets are numbers.
@Suite struct FrameClockTests {
    static let day = 86_400.0
    static let thirtyDays = 30 * day
    /// An arbitrary media-time origin, as a device that has been up for a while reports it.
    static let mediaOrigin = 123_456.789

    /// The frame indices of an 8-frame, 12 fps sheet over `seconds` at `rate` Hz, through a `FrameClock`.
    static func indices(start: EngineTime, seconds: Double = 10, rate: Double = 120) -> [Int] {
        var clock = FrameClock(start: start)
        var out = [Int]()
        for k in 0..<Int(seconds * rate) {
            clock.advance(to: mediaOrigin + Double(k) / rate)
            out.append(clock.time.frameIndex(framesPerSecond: 12, count: 8))
        }
        return out
    }

    // MARK: E-TIME-1

    @Test func `E-TIME-1 frame indices at day 0 and day 30 are identical over 10 s at 120 Hz`() {
        let day0 = Self.indices(start: .zero)
        let day30 = Self.indices(start: EngineTime(seconds: Self.thirtyDays))
        #expect(day0.count == 1200)
        #expect(day0 == day30)
        // The sheet advances one frame every 10 ticks and loops every 80.
        #expect(Array(day0.prefix(21)) == Array(repeating: 0, count: 10) + Array(repeating: 1, count: 10) + [2])
        #expect(day0[80] == 0 && day0[79] == 7)
    }

    @Test func `E-TIME-1 negative control float absolute time differs at day 30`() {
        func floatIndices(start: Double) -> [Int] {
            (0..<1200).map { k in
                let t = Float(start) + Float(k) / 120
                return Int((t * 12).rounded(.down)) % 8
            }
        }
        #expect(floatIndices(start: 0) != floatIndices(start: Self.thirtyDays))
    }

    @Test func `E-TIME-1 the GPU time at day 30 is bit-identical to day 0`() {
        var random = SplitMix64(seed: 0x4845_0901)
        for period in [1.0, 2.5, 60] {
            for _ in 0..<1000 {
                // x on a dyadic grid inside the period: exactly representable at day 30, so "the same phase".
                let k = Double(UInt64.random(in: 0..<UInt64(period * 1_048_576), using: &random))
                let x = k / 1_048_576
                let day0 = EngineTime(seconds: x).gpuSeconds(period: period)
                let day30 = EngineTime(seconds: Self.thirtyDays + x).gpuSeconds(period: period)
                #expect(day0.bitPattern == day30.bitPattern)
            }
        }
    }

    @Test func `E-TIME-1 the GPU time at day 30 is within one ulp for any time`() {
        var random = SplitMix64(seed: 0x4845_0902)
        for period in [1.0, 2.5, 60] {
            for _ in 0..<1000 {
                let x = Double.random(in: 0..<period, using: &random)
                let day0 = EngineTime(seconds: x).gpuSeconds(period: period)
                let day30 = EngineTime(seconds: Self.thirtyDays + x).gpuSeconds(period: period)
                // Day 30 rounds x to the Double grid there (2^-31 s) before the Float rounding: one Float ulp plus
                // that grid, measured around the loop (a value at the end of the loop is next to its start).
                let distance = abs(Double(day30) - Double(day0))
                let circular = min(distance, period - distance)
                #expect(circular <= Double(day0.ulp) + 0x1p-31)
                #expect(day0 >= 0 && day0 <= Float(period) && day30 >= 0 && day30 <= Float(period))
            }
        }
    }

    @Test func `E-TIME-1 frame index at boundaries negative and non-finite time`() {
        #expect(EngineTime(seconds: 1.0 / 12).frameIndex(framesPerSecond: 12, count: 8) == 1)
        #expect(EngineTime(seconds: 8.0 / 12).frameIndex(framesPerSecond: 12, count: 8) == 0)
        #expect(EngineTime(seconds: 7.0 / 12).frameIndex(framesPerSecond: 12, count: 8) == 7)
        #expect(EngineTime(seconds: -1.0 / 24).frameIndex(framesPerSecond: 12, count: 8) == 7)
        #expect(EngineTime(seconds: Self.thirtyDays + 1.0 / 12).frameIndex(framesPerSecond: 12, count: 8) == 1)
        for seconds in [Double.nan, .infinity, -.infinity] {
            #expect(EngineTime(seconds: seconds).frameIndex(framesPerSecond: 12, count: 8) == 0)
            #expect(EngineTime(seconds: seconds).gpuSeconds(period: 1) == 0)
        }
        #expect(EngineTime(seconds: 5.3).frameIndex(framesPerSecond: 12, count: 1) == 0)
        for count in [0, -1] {
            #expect(EngineTime(seconds: 5.3).frameIndex(framesPerSecond: 12, count: count) == 0)
        }
        for rate in [0, -12, Double.nan, .infinity] {
            #expect(EngineTime(seconds: 5.3).frameIndex(framesPerSecond: rate, count: 8) == 0)
        }
        #expect(EngineTime(seconds: 1.25).gpuSeconds(period: 1) == 0.25)
        #expect(EngineTime(seconds: -0.25).gpuSeconds(period: 1) == 0.75)
        #expect(EngineTime(seconds: -1e-20).gpuSeconds(period: 1) == 0)
        #expect(EngineTime(seconds: 3).gpuSeconds(period: 0) == 0)
        #expect(EngineTime(seconds: 3).wrapped(period: -1) == nil)
    }

    @Test func `E-TIME-1 frame index is periodic and in range over 1000 seeded times`() {
        var random = SplitMix64(seed: 0x4845_0903)
        for _ in 0..<1000 {
            let count = Int.random(in: 1...64, using: &random)
            let rate = Double(Int.random(in: 1...60, using: &random))
            let loop = Double(count) / rate
            let t = Double.random(in: -Self.day...Self.thirtyDays, using: &random)
            let index = EngineTime(seconds: t).frameIndex(framesPerSecond: rate, count: count)
            #expect(index >= 0 && index < count)
            // A whole loop later: the same frame, unless t sits within the rounding of the shift of a boundary.
            let later = EngineTime(seconds: t + loop).frameIndex(framesPerSecond: rate, count: count)
            let frac = (EngineTime(seconds: t).wrapped(period: loop) ?? 0) * rate
            let nearBoundary = abs(frac - frac.rounded()) < 1e-5
            #expect(later == index || nearBoundary)
            // Inside one loop the index does not decrease.
            let start = t - (EngineTime(seconds: t).wrapped(period: loop) ?? 0)
            var last = -1
            for step in 0..<count {
                let i = EngineTime(seconds: start + (Double(step) + 0.5) / rate).frameIndex(framesPerSecond: rate, count: count)
                #expect(i >= last)
                last = i
            }
        }
    }

    // MARK: E-TIME-2

    @Test func `E-TIME-2 progress equals wall time within one frame over skips and a rate switch`() {
        var clock = FrameClock()
        var target = Self.mediaOrigin
        var tick = 0
        var sampled = 0
        while target < Self.mediaOrigin + 5 {
            let rate = target < Self.mediaOrigin + 2.5 ? 120.0 : 60.0
            target += 1 / rate
            tick += 1
            if tick % 7 == 0 { continue }  // a dropped callback
            clock.advance(to: target)
            sampled += 1
            #expect(abs(clock.time.seconds - (target - Self.mediaOrigin - (1.0 / 120))) <= 1.0 / 60)
        }
        #expect(sampled > 350)
        #expect(clock.steps == sampled)
    }

    @Test func `E-TIME-2 negative control a fixed step drifts under skipped callbacks`() {
        var fixed = 0.0
        var target = 0.0
        for tick in 1...600 {
            target += 1.0 / 120
            if tick % 7 == 0 { continue }
            fixed += 1.0 / 120
        }
        #expect(abs(fixed - target) > 1.0 / 60)
    }

    @Test func `E-TIME-2 dt is clamped to 0.1 s and never negative`() {
        var clock = FrameClock()
        clock.advance(to: 10)
        clock.advance(to: 10.5)
        #expect(clock.dt == 0.1 && clock.discontinuity)
        #expect(clock.time.seconds == 0.5)
        clock.advance(to: 10.25)
        #expect(clock.dt == 0 && clock.discontinuity)
        #expect(clock.time.seconds == 0.25)
        clock.advance(to: 10.25 + 0.1)
        #expect(abs(clock.dt - 0.1) < 1e-12)
        clock.advance(to: 11)
        clock.advance(to: 11.0 + 1.0 / 60)
        #expect(!clock.discontinuity && abs(clock.dt - 1.0 / 60) < 1e-12)
        let before = clock
        for target in [Double.nan, .infinity, -.infinity] {
            clock.advance(to: target)
        }
        #expect(clock == before)
    }

    @Test func `E-TIME-2 the first tick has dt zero`() {
        var clock = FrameClock(start: EngineTime(seconds: 42))
        #expect(clock.time.seconds == 42 && clock.steps == 0)
        clock.advance(to: Self.mediaOrigin)
        #expect(clock.dt == 0 && !clock.discontinuity && clock.time.seconds == 42 && clock.steps == 1)
        clock.advance(to: Self.mediaOrigin + 0.5)
        clock.advance(to: Self.mediaOrigin + 0.5 + 1.0 / 120)
        #expect(!clock.discontinuity)
        #expect(clock.start.seconds == 42)
    }

    // MARK: E-TIME-3

    @Test func `E-TIME-3 after a million random steps the frame index equals the closed form`() {
        var random = SplitMix64(seed: 0x4845_0904)
        let start = EngineTime(seconds: Self.thirtyDays)
        var clock = FrameClock(start: start)
        var target = Self.mediaOrigin
        clock.advance(to: target)
        for _ in 0..<1_000_000 {
            target += Double.random(in: (1.0 / 120)...(1.0 / 10), using: &random)
            clock.advance(to: target)
        }
        let closed = EngineTime(seconds: start.seconds + (target - Self.mediaOrigin))
        #expect(clock.time.frameIndex(framesPerSecond: 12, count: 8) == closed.frameIndex(framesPerSecond: 12, count: 8))
        #expect(clock.time == closed)
        #expect(clock.steps == 1_000_001)
    }

    @Test func `E-TIME-3 negative control an accumulated float dt drifts`() {
        // The accumulation the clock avoids: a Float sum of a million 1/120 s steps ends about 20 s short.
        var sum: Float = 0
        for _ in 0..<1_000_000 {
            sum += Float(1.0 / 120)
        }
        let closed = EngineTime(seconds: 1_000_000.0 / 120)
        #expect(EngineTime(seconds: Double(sum)).frameIndex(framesPerSecond: 12, count: 8)
            != closed.frameIndex(framesPerSecond: 12, count: 8))
        #expect(abs(Double(sum) - closed.seconds) > 1)
    }

    @Test func `E-TIME-3 time is the same with and without intermediate ticks`() {
        var many = FrameClock()
        var once = FrameClock()
        many.advance(to: Self.mediaOrigin)
        once.advance(to: Self.mediaOrigin)
        for k in 1...1000 {
            many.advance(to: Self.mediaOrigin + Double(k) * 0.0173)
        }
        once.advance(to: Self.mediaOrigin + 1000 * 0.0173)
        #expect(many.time == once.time)
    }

    // MARK: E-TIME-4

    @Test func `E-TIME-4 a three-day jump costs one step`() {
        var clock = FrameClock()
        clock.advance(to: Self.mediaOrigin)
        clock.advance(to: Self.mediaOrigin + 1.0 / 60)
        let before = clock.steps
        clock.advance(to: Self.mediaOrigin + 3 * Self.day)
        #expect(clock.steps == before + 1)
        #expect(abs(clock.time.seconds - 3 * Self.day) < 1e-6)
    }

    @Test func `E-TIME-4 progress derived from the clock stays in range after the jump`() {
        var clock = FrameClock()
        clock.advance(to: Self.mediaOrigin)
        let started = clock.time
        clock.advance(to: Self.mediaOrigin + 3 * Self.day)
        #expect(clock.time.progress(since: started, duration: 0.25) == 1)
        let phase = clock.time.phase(period: 4)
        #expect(phase >= 0 && phase < 1)
        #expect(EngineTime(seconds: 0.5).progress(since: .zero, duration: 2) == 0.25)
        #expect(EngineTime(seconds: -1).progress(since: .zero, duration: 2) == 0)
        for duration in [0, -1, Double.nan, .infinity] {
            #expect(EngineTime(seconds: 1).progress(since: .zero, duration: duration) == 1)
        }
        #expect(EngineTime(seconds: .infinity).progress(since: .zero, duration: 1) == 1)
        #expect(EngineTime(seconds: -.infinity).progress(since: .zero, duration: 1) == 0)
        #expect(EngineTime(seconds: .nan).progress(since: .zero, duration: 1) == 0)
    }

    @Test func `E-TIME-4 a three-day jump sets discontinuity and clamps dt`() {
        var clock = FrameClock()
        clock.advance(to: Self.mediaOrigin)
        clock.advance(to: Self.mediaOrigin + 3 * Self.day)
        #expect(clock.discontinuity && clock.dt == 0.1)
        clock.advance(to: Self.mediaOrigin + 3 * Self.day + 1.0 / 60)
        #expect(!clock.discontinuity)
    }

    @Test func `E-TIME-4 a jump at the clamp boundary is not a discontinuity`() {
        var exact = FrameClock()
        exact.advance(to: 0)
        exact.advance(to: 0.1)
        #expect(!exact.discontinuity && exact.dt == 0.1)
        var past = FrameClock()
        past.advance(to: 0)
        past.advance(to: 0.1.nextUp)
        #expect(past.discontinuity && past.dt == 0.1)
    }
}
