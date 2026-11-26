/// The rate the display actually delivers, measured from the link (E-RATE-4, pitfall 2.17).
///
/// Low Power Mode, "Limit Frame Rate", Adaptive Power and thermal state can each lower the delivered rate below
/// the requested one without saying so. Each interval is snapped to a cadence of the display (`maximum / n` for a
/// whole `n`: 120, 60, 40, 30, 24, 20 ... on a 120 Hz display), and the estimate is the lower median `n` of the last
/// `window` samples, so jitter cannot produce a rate the display never delivers and a tie favours the faster one.
struct RateEstimator: Sendable, Hashable {
    static let window = 8

    /// The display's maximum rate in frames per second (`maximumFramesPerSecond`), at least 1.
    let maximumFramesPerSecond: Int
    private var divisors: [Int] = []

    init(maximumFramesPerSecond: Int) {
        self.maximumFramesPerSecond = Swift.max(1, maximumFramesPerSecond)
    }

    /// Adds one callback's interval, `targetTimestamp - timestamp`. Non-positive and non-finite intervals are ignored.
    mutating func add(timestamp: Double, targetTimestamp: Double) {
        let interval = targetTimestamp - timestamp
        guard interval.isFinite, interval > 0 else { return }
        let refreshes = (interval * Double(maximumFramesPerSecond)).rounded()
        guard refreshes.isFinite, refreshes < Double(Int32.max) else { return }
        divisors.append(Swift.max(1, Int(refreshes)))
        if divisors.count > RateEstimator.window {
            divisors.removeFirst(divisors.count - RateEstimator.window)
        }
    }

    /// Display refreshes per delivered frame, or nil before the first sample.
    var refreshesPerFrame: Int? {
        guard !divisors.isEmpty else { return nil }
        return divisors.sorted()[(divisors.count - 1) / 2]
    }

    /// The delivered rate in frames per second, or nil before the first sample.
    var rate: Double? {
        refreshesPerFrame.map { Double(maximumFramesPerSecond) / Double($0) }
    }

    /// The interval to present after so frames are evenly paced at the delivered rate, or nil before a sample.
    var presentInterval: Double? {
        refreshesPerFrame.map { Double($0) / Double(maximumFramesPerSecond) }
    }
}
