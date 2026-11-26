import HearthHarness
import Testing

@testable import HearthEngine

/// The frame-rate policy of D3 as a pure table. No GPU, no link.
@Suite struct FramePolicyTests {
    static func range(_ minimum: Float, _ maximum: Float, _ preferred: Float) -> FrameRateRange {
        FrameRateRange(minimum: minimum, maximum: maximum, preferred: preferred)
    }

    static func rate(
        interacting: Bool = false, motion: ContentMotion = .still, lowPower: Bool = false,
        thermal: ThermalLevel = .nominal, highRate: Bool = false
    ) -> FrameRate {
        FramePolicy.rate(for: FrameConditions(
            interacting: interacting, motion: motion, lowPower: lowPower, thermal: thermal, highRateAllowed: highRate))
    }

    static var everyCondition: [FrameConditions] {
        var out = [FrameConditions]()
        for interacting in [false, true] {
            for motion in ContentMotion.allCases {
                for lowPower in [false, true] {
                    for thermal in ThermalLevel.allCases {
                        for highRate in [false, true] {
                            out.append(FrameConditions(
                                interacting: interacting, motion: motion, lowPower: lowPower, thermal: thermal,
                                highRateAllowed: highRate))
                        }
                    }
                }
            }
        }
        return out
    }

    static func maximum(_ rate: FrameRate) -> Float {
        switch rate {
        case .paused: 0
        case .running(let range, _): range.maximum
        }
    }

    // MARK: E-RATE-1

    @Test func `E-RATE-1 the policy table gives each situation its rate`() {
        #expect(Self.rate() == .paused)
        #expect(Self.rate(motion: .ambient) == .running(Self.range(10, 30, 20), ambience: true))
        #expect(Self.rate(interacting: true) == .running(Self.range(30, 60, 60), ambience: true))
        #expect(Self.rate(interacting: true, motion: .ambient) == .running(Self.range(30, 60, 60), ambience: true))
        #expect(Self.rate(interacting: true, highRate: true) == .running(Self.range(30, 120, 120), ambience: true))
    }

    @Test func `E-RATE-1 Low Power Mode and serious cap the rate at 30`() {
        for (lowPower, thermal) in [(true, ThermalLevel.nominal), (false, .serious), (true, .serious)] {
            #expect(Self.rate(interacting: true, lowPower: lowPower, thermal: thermal)
                == .running(Self.range(30, 30, 30), ambience: true))
            #expect(Self.rate(interacting: true, lowPower: lowPower, thermal: thermal, highRate: true)
                == .running(Self.range(30, 30, 30), ambience: true))
            #expect(Self.rate(motion: .ambient, lowPower: lowPower, thermal: thermal)
                == .running(Self.range(10, 30, 20), ambience: true))
        }
    }

    @Test func `E-RATE-1 critical caps at 15 and turns ambience off`() {
        #expect(Self.rate(interacting: true, thermal: .critical) == .running(Self.range(15, 15, 15), ambience: false))
        #expect(Self.rate(interacting: true, motion: .ambient, lowPower: true, thermal: .critical, highRate: true)
            == .running(Self.range(15, 15, 15), ambience: false))
        #expect(Self.rate(motion: .ambient, thermal: .critical) == .paused)
        #expect(Self.rate(thermal: .critical) == .paused)
    }

    @Test func `E-RATE-1 nominal and fair change nothing`() {
        for condition in Self.everyCondition where condition.thermal == .fair {
            var nominal = condition
            nominal.thermal = .nominal
            #expect(FramePolicy.rate(for: condition) == FramePolicy.rate(for: nominal))
        }
    }

    @Test func `E-RATE-1 high rate without interaction stays at the ambience rate`() {
        #expect(Self.rate(motion: .ambient, highRate: true) == .running(Self.range(10, 30, 20), ambience: true))
        #expect(Self.rate(highRate: true) == .paused)
    }

    @Test func `E-RATE-1 every range is ordered with preferred inside`() {
        #expect(Self.everyCondition.count == 64)
        for condition in Self.everyCondition {
            if case .running(let range, _) = FramePolicy.rate(for: condition) {
                #expect(range.minimum <= range.preferred && range.preferred <= range.maximum && range.minimum > 0)
            }
        }
    }

    @Test func `E-RATE-1 caps commute and never raise the rate`() {
        for condition in Self.everyCondition {
            let base = Self.maximum(FramePolicy.rate(for: condition))
            var lowPower = condition
            lowPower.lowPower = true
            #expect(Self.maximum(FramePolicy.rate(for: lowPower)) <= base)
            for hotter in ThermalLevel.allCases where hotter >= condition.thermal {
                var warmer = condition
                warmer.thermal = hotter
                #expect(Self.maximum(FramePolicy.rate(for: warmer)) <= base)
            }
            var serious = condition
            serious.thermal = .serious
            var both = serious
            both.lowPower = true
            if !condition.lowPower && condition.thermal == .nominal {
                #expect(FramePolicy.rate(for: both) == FramePolicy.rate(for: serious))
                #expect(FramePolicy.rate(for: both) == FramePolicy.rate(for: lowPower))
            }
        }
        #expect(ThermalLevel.nominal < .critical && !(ThermalLevel.serious < .serious))
    }
}
