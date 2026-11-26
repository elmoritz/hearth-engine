import HearthHarness
import Testing

@testable import HearthEngine

/// The delivered rate, measured from fake link callbacks. No link, no clock.
@Suite struct RateEstimatorTests {
    /// Feeds `count` callbacks at `rate` Hz, as a link reports them: `targetTimestamp - timestamp = 1 / rate`.
    static func feed(_ estimator: inout RateEstimator, rate: Double, count: Int, from start: inout Double) {
        for _ in 0..<count {
            estimator.add(timestamp: start, targetTimestamp: start + 1 / rate)
            start += 1 / rate
        }
    }

    static func cadences(of maximum: Int) -> Set<Double> {
        Set((1...maximum).map { Double(maximum) / Double($0) })
    }

    // MARK: E-RATE-4

    @Test func `E-RATE-4 the estimator reports 120 60 40 and 30 from a fake link`() {
        for rate in [120.0, 60, 40, 30] {
            var estimator = RateEstimator(maximumFramesPerSecond: 120)
            var t = 1000.0
            Self.feed(&estimator, rate: rate, count: RateEstimator.window, from: &t)
            #expect(estimator.rate == rate)
            #expect(estimator.presentInterval.map { abs($0 - 1 / rate) < 1e-12 } == true)
        }
    }

    @Test func `E-RATE-4 non-positive and non-finite intervals are ignored`() {
        var estimator = RateEstimator(maximumFramesPerSecond: 120)
        for (timestamp, target) in [(1.0, 1.0), (1.0, 1.0 - 1.0 / 60), (1.0, .nan), (1.0, .infinity), (.nan, 2.0), (0, 1e300)] {
            estimator.add(timestamp: timestamp, targetTimestamp: target)
        }
        #expect(estimator.rate == nil)
        var t = 5.0
        Self.feed(&estimator, rate: 60, count: 3, from: &t)
        estimator.add(timestamp: 1, targetTimestamp: 1)
        estimator.add(timestamp: 1, targetTimestamp: .nan)
        #expect(estimator.rate == 60)
    }

    @Test func `E-RATE-4 a rate switch is followed within the window`() {
        var estimator = RateEstimator(maximumFramesPerSecond: 120)
        var t = 0.0
        Self.feed(&estimator, rate: 120, count: 20, from: &t)
        #expect(estimator.rate == 120)
        Self.feed(&estimator, rate: 60, count: 4, from: &t)
        #expect(estimator.rate == 120)
        Self.feed(&estimator, rate: 60, count: 1, from: &t)
        #expect(estimator.rate == 60)
    }

    @Test func `E-RATE-4 no reported rate leaves the cadence set during a switch`() {
        let allowed = Self.cadences(of: 120)
        var estimator = RateEstimator(maximumFramesPerSecond: 120)
        var t = 0.0
        var seen = Set<Double>()
        for rate in [120.0, 60, 40] {
            for _ in 0..<12 {
                Self.feed(&estimator, rate: rate, count: 1, from: &t)
                if let reported = estimator.rate {
                    #expect(allowed.contains(reported))
                    seen.insert(reported)
                }
            }
        }
        #expect(seen == [120, 60, 40])
        // A 60 Hz display delivers a 40 Hz request at 30.
        var sixty = RateEstimator(maximumFramesPerSecond: 60)
        var u = 0.0
        for _ in 0..<8 {
            sixty.add(timestamp: u, targetTimestamp: u + 2.0 / 60)
            u += 2.0 / 60
        }
        #expect(sixty.rate == 30)
    }

    @Test func `E-RATE-4 jitter does not move the snapped rate`() {
        var random = SplitMix64(seed: 0x4845_0905)
        var estimator = RateEstimator(maximumFramesPerSecond: 120)
        var t = 0.0
        for _ in 0..<1000 {
            let interval = 1.0 / 60 + Double.random(in: -0.0005...0.0005, using: &random)
            estimator.add(timestamp: t, targetTimestamp: t + interval)
            t += interval
            #expect(estimator.rate == 60)
        }
    }

    @Test func `E-RATE-4 an empty window reports nil`() {
        let estimator = RateEstimator(maximumFramesPerSecond: 120)
        #expect(estimator.rate == nil && estimator.presentInterval == nil && estimator.refreshesPerFrame == nil)
        // A display reporting no maximum is treated as 1 Hz, never a division by zero.
        var broken = RateEstimator(maximumFramesPerSecond: 0)
        broken.add(timestamp: 0, targetTimestamp: 0.25)
        #expect(broken.maximumFramesPerSecond == 1 && broken.rate == 1)
    }
}
