import Foundation
import HearthHarness
import Metal
import QuartzCore
import Testing

@testable import HearthEngine

/// The frame loop over a fake link, layer, GPU and host: render on demand, the policy, lifecycle and errors.
@MainActor
@Suite struct LoopTests {
    // MARK: E-RATE-2

    @Test func `E-RATE-2 a still scene requests no frames over many ticks`() {
        let rig = LoopRig()
        rig.settle()
        #expect(rig.frames == 1)
        rig.link.fire(times: 1000)
        #expect(rig.frames == 1)
        #expect(rig.link.isPaused)
        #expect(rig.loop.contentRate == .paused)
    }

    @Test func `E-RATE-2 negative control ambient content requests frames`() {
        let rig = LoopRig()
        rig.source.motion = .ambient
        rig.settle()
        for _ in 0..<10 {
            rig.link.fire()
            rig.submitter.completeAll()
        }
        #expect(rig.frames == 11)
        #expect(!rig.link.isPaused)
        #expect(rig.source.contexts.allSatisfy { $0.ambience })
    }

    @Test func `E-RATE-2 one setNeedsFrame draws exactly one frame`() {
        let rig = LoopRig()
        rig.settle()
        rig.loop.setNeedsFrame()
        #expect(!rig.link.isPaused)
        rig.loop.setNeedsFrame()
        rig.link.fire(times: 5)
        #expect(rig.frames == 2)
        #expect(rig.link.isPaused)
    }

    @Test func `E-RATE-2 interaction ending returns to paused`() {
        let rig = LoopRig()
        rig.settle()
        rig.loop.interacting = true
        for _ in 0..<3 {
            rig.link.fire()
            rig.submitter.completeAll()
        }
        #expect(rig.frames == 4)
        rig.loop.interacting = false
        rig.link.fire(times: 10)
        #expect(rig.frames == 4)
        #expect(rig.link.isPaused)
    }

    // MARK: E-RATE-3

    @Test func `E-RATE-3 the reported rate equals the policy result`() {
        for highRate in [false, true] {
            let rig = LoopRig(configuration: FrameLoopConfiguration(highRateAllowed: highRate, idiom: .mac))
            rig.settle()
            for interacting in [false, true] {
                for motion in ContentMotion.allCases {
                    for lowPower in [false, true] {
                        for thermal in ThermalLevel.allCases {
                            rig.source.motion = motion
                            rig.loop.setSystem(lowPower: lowPower, thermal: thermal)
                            rig.loop.interacting = interacting
                            let expected = FramePolicy.rate(for: FrameConditions(
                                interacting: interacting, motion: motion, lowPower: lowPower, thermal: thermal,
                                highRateAllowed: highRate))
                            #expect(rig.loop.contentRate == expected)
                            #expect(rig.loop.conditions == FrameConditions(
                                interacting: interacting, motion: motion, lowPower: lowPower, thermal: thermal,
                                highRateAllowed: highRate))
                            if case .running(let range, _) = expected {
                                #expect(rig.link.preferredRange == range && !rig.link.isPaused)
                            } else {
                                #expect(rig.link.isPaused)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func `E-RATE-3 a thermal change updates the reported rate without a frame`() {
        let rig = LoopRig()
        rig.source.motion = .ambient
        rig.settle()
        rig.loop.setSystem(lowPower: false, thermal: .critical)
        #expect(rig.loop.contentRate == .paused)
        #expect(rig.frames == 1 && rig.link.isPaused)
        rig.loop.setSystem(lowPower: true, thermal: .nominal)
        #expect(rig.loop.contentRate == .running(FramePolicy.ambience, ambience: true))
        #expect(rig.frames == 1)
    }

    @Test func `E-RATE-3 paused is reported as paused, not as a zero range`() {
        let rig = LoopRig()
        rig.settle()
        #expect(rig.loop.contentRate == .paused)
        #expect(rig.link.isPaused)
        #expect(rig.link.preferredRange == FramePolicy.interaction)
    }

    // MARK: E-RATE-4, through the loop

    @Test func `E-RATE-4 the fallback link presents after the measured duration`() {
        let rig = LoopRig(configuration: FrameLoopConfiguration(link: .displayLink, idiom: .mac))
        rig.loop.interacting = true
        for _ in 0..<8 {
            rig.link.fire(interval: 1.0 / 40)
            rig.submitter.completeAll()
        }
        #expect(rig.link.preferredRange.preferred == 60)
        let intervals = rig.submitter.submitted.compactMap(\.presentAfter)
        #expect(intervals.count == 8)
        #expect(intervals.allSatisfy { abs($0 - 1.0 / 40) < 1e-12 })

        let metal = LoopRig()
        metal.loop.interacting = true
        metal.link.fire(interval: 1.0 / 40)
        #expect(metal.submitter.submitted.map(\.presentAfter) == [nil])
    }

    // MARK: E-TIME-2, E-TIME-4 through the loop

    @Test func `E-TIME-2 the loop samples the source at the target timestamp`() {
        let rig = LoopRig(configuration: FrameLoopConfiguration(start: EngineTime(seconds: 50), idiom: .mac))
        rig.loop.interacting = true
        rig.link.onTick?(LinkTick(timestamp: 10, targetTimestamp: 10.5, drawable: nil))
        rig.submitter.completeAll()
        rig.link.onTick?(LinkTick(timestamp: 11, targetTimestamp: 11.25, drawable: nil))
        #expect(rig.source.contexts.map(\.time.seconds) == [50, 50.75])
        #expect(rig.source.contexts.last?.clock.dt == 0.1 && rig.source.contexts.last?.clock.discontinuity == true)
    }

    @Test func `E-TIME-4 the loop draws one ordinary frame after a three-day jump`() {
        let rig = LoopRig()
        rig.loop.interacting = true
        rig.link.fire()
        rig.submitter.completeAll()
        rig.link.fire(interval: 3 * 86_400)
        #expect(rig.source.contexts.count == 2)
        #expect(rig.submitter.submitted.count == 2)
        #expect(rig.submitter.submitted[0].frame == rig.submitter.submitted[1].frame)
        #expect(rig.source.contexts[1].clock.discontinuity && rig.source.contexts[1].clock.steps == 2)
    }

    @Test func `Perf E-TIME-4 jump frame CPU time`() {
        func cost(interval: Double) -> Double {
            var best = Double.infinity
            for _ in 0..<5 {
                let rig = LoopRig()
                rig.loop.interacting = true
                let clock = ContinuousClock()  // lint:allow clock - a PERF time probe measures, it decides nothing
                let elapsed = clock.measure {
                    for _ in 0..<1000 {
                        rig.link.fire(interval: interval)
                        rig.submitter.completeAll()
                    }
                }
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                best = min(best, seconds)
            }
            return best
        }
        let ratio = cost(interval: 3 * 86_400) / cost(interval: 1.0 / 60)
        print("PERF loop.jump-frame-ratio \(ratio) ratio time")
        #expect(ratio <= 2)
    }

    // MARK: E-LIFE-1

    @Test func `E-LIFE-1 no commit after deactivate`() {
        let rig = LoopRig()
        rig.loop.interacting = true
        rig.link.fire()
        rig.submitter.completeAll()
        rig.loop.lifecycle = .inactive
        #expect(rig.link.isPaused)
        rig.loop.setNeedsFrame()
        rig.link.fire(times: 1000)
        #expect(rig.frames == 1)
        #expect(rig.link.isPaused)
    }

    @Test func `E-LIFE-1 entering background waits until scheduled on the last buffer`() {
        let rig = LoopRig()
        rig.loop.interacting = true
        rig.link.fire()
        rig.link.fire()
        let last = rig.submitter.lastID
        rig.loop.lifecycle = .background
        #expect(rig.submitter.waits == [last].compactMap { $0 })
        #expect(rig.submitter.waits.map(\.value) == [1])
        rig.loop.lifecycle = .background
        #expect(rig.submitter.waits.count == 1)
        rig.loop.lifecycle = .inactive
        rig.loop.lifecycle = .background
        #expect(rig.submitter.waits.count == 2 && rig.loop.stats.waitsUntilScheduled == 2)
    }

    @Test func `E-LIFE-1 the gate rejects encode in inactive and background`() {
        let orders: [[Lifecycle]] = [
            [.inactive, .background], [.background, .inactive], [.inactive], [.background], [.background, .background],
        ]
        for order in orders {
            var gate = LifecycleGate()
            #expect(gate.canEncode)
            for state in order {
                _ = gate.enter(state)
                #expect(!gate.canEncode)
            }
            _ = gate.enter(.active)
            #expect(gate.canEncode)
        }
        var revoked = LifecycleGate()
        revoked.revoke()
        #expect(!revoked.canEncode && revoked.state == .active)
        let toInactive = revoked.enter(.inactive)
        let toBackground = revoked.enter(.background)
        let toActive = revoked.enter(.active)
        #expect(!toInactive && toBackground && !toActive && revoked.canEncode)
    }

    @Test func `E-LIFE-1 background with nothing committed waits on nothing`() {
        let rig = LoopRig(layout: false)
        rig.loop.lifecycle = .background
        #expect(rig.submitter.waits.isEmpty && rig.loop.stats.waitsUntilScheduled == 0)
    }

    @Test func `E-LIFE-1 a request while inactive is drawn once on return`() {
        let rig = LoopRig()
        rig.settle()
        rig.loop.lifecycle = .inactive
        rig.loop.setNeedsFrame()
        rig.link.fire(times: 3)
        #expect(rig.frames == 1)
        rig.loop.lifecycle = .active
        #expect(!rig.link.isPaused)
        rig.link.fire(times: 3)
        #expect(rig.frames == 2)
    }

    @Test func `E-LIFE-1 a tick delivered in the same turn as deactivate commits nothing`() {
        let rig = LoopRig()
        rig.loop.interacting = true
        rig.loop.lifecycle = .inactive
        rig.link.fire()
        #expect(rig.frames == 0)
    }

    // MARK: E-LIFE-2

    @Test func `E-LIFE-2 notPermitted and accessRevoked completions are logged`() {
        for failure in [CommandBufferFailure.notPermitted, .accessRevoked] {
            let rig = LoopRig()
            rig.link.fire()
            rig.submitter.completeAll(.failed(failure))
            #expect(rig.events == [.commandBufferFailed(failure)])
        }
        let domain = MTLCommandBufferErrorDomain
        let cases: [(MTLCommandBufferStatus, (any Error)?, CommandBufferOutcome)] = [
            (.completed, nil, .completed),
            (.error, NSError(domain: domain, code: Int(MTLCommandBufferError.Code.notPermitted.rawValue)), .failed(.notPermitted)),
            (.error, NSError(domain: domain, code: Int(MTLCommandBufferError.Code.accessRevoked.rawValue)), .failed(.accessRevoked)),
            (.error, NSError(domain: domain, code: 42), .failed(.other(code: 42))),
            (.error, nil, .failed(.other(code: -1))),
            (.completed, NSError(domain: domain, code: Int(MTLCommandBufferError.Code.timeout.rawValue)),
             .failed(.other(code: Int(MTLCommandBufferError.Code.timeout.rawValue)))),
        ]
        for (status, error, outcome) in cases {
            #expect(CommandBufferOutcome(status: status, error: error) == outcome)
        }
    }

    @Test func `E-LIFE-2 accessRevoked pauses until the next activation`() {
        for failure in [CommandBufferFailure.notPermitted, .accessRevoked] {
            let rig = LoopRig()
            rig.loop.interacting = true
            rig.link.fire()
            rig.submitter.completeAll(.failed(failure))
            #expect(rig.link.isPaused)
            rig.loop.setNeedsFrame()
            rig.link.fire(times: 10)
            #expect(rig.frames == 1)
            rig.loop.lifecycle = .active
            rig.link.fire()
            #expect(rig.frames == 2)
        }
    }

    @Test func `E-LIFE-2 an unknown error code is logged not trapped`() {
        let rig = LoopRig()
        rig.loop.interacting = true
        rig.link.fire()
        rig.submitter.completeAll(.failed(.other(code: 42)))
        #expect(rig.events == [.commandBufferFailed(.other(code: 42))])
        rig.link.fire()
        #expect(rig.frames == 2)
    }

    @Test func `E-LIFE-2 errors on several in-flight buffers are each logged once`() {
        let rig = LoopRig()
        rig.loop.interacting = true
        rig.link.fire(times: 4)
        #expect(rig.frames == FrameLoop.maximumInFlight)
        rig.submitter.completeAll(.failed(.other(code: 9)))
        #expect(rig.events == Array(repeating: .commandBufferFailed(.other(code: 9)), count: 3))
        rig.link.fire()
        #expect(rig.frames == 4)
    }

    @Test func `E-LIFE-2 a refused frame is reported and commits nothing`() {
        let rig = LoopRig()
        rig.submitter.refusal = .missingTexture("absent")
        rig.link.fire()
        #expect(rig.events == [.frameRefused(.missingTexture("absent"))])
        #expect(rig.frames == 0 && rig.loop.stats.framesEncoded == 0)
        #expect(rig.link.isPaused)
    }

    // MARK: E-LIFE-3

    @Test func `E-LIFE-3 background and return keep the host's pause flag and frame counter`() {
        let rig = LoopRig()
        rig.source.motion = .ambient
        rig.settle()
        rig.loop.isPaused = true
        let calls = rig.source.contexts.count
        for state in [Lifecycle.inactive, .background, .inactive, .active] {
            rig.loop.lifecycle = state
            rig.link.fire(times: 5)
        }
        #expect(rig.loop.isPaused)
        #expect(rig.source.contexts.count == calls)
        #expect(rig.loop.stats.framesEncoded == 1)
    }

    @Test func `E-LIFE-3 a paused host gets no ambience frames but still draws on request`() {
        let rig = LoopRig()
        rig.source.motion = .ambient
        rig.loop.isPaused = true
        rig.settle()
        rig.link.fire(times: 100)
        #expect(rig.frames == 1)
        rig.loop.setNeedsFrame()
        rig.link.fire()
        #expect(rig.frames == 2)
        rig.submitter.completeAll()
        rig.loop.interacting = true
        rig.link.fire()
        #expect(rig.frames == 3)
        #expect(rig.source.contexts.allSatisfy { !$0.ambience })
        #expect(rig.loop.isPaused)
    }

    @Test func `E-LIFE-3 an unpaused host stays unpaused`() {
        let rig = LoopRig()
        for state in [Lifecycle.inactive, .background, .active] {
            rig.loop.lifecycle = state
        }
        #expect(!rig.loop.isPaused)
    }

    // MARK: E-LIFE-4

    @Test func `E-LIFE-4 a drawable of the old size is skipped not stretched`() {
        let rig = LoopRig()
        rig.layer.stale = CGSize(width: 100, height: 50)
        rig.link.fire()
        #expect(rig.frames == 0)
        #expect(rig.loop.stats.staleDrawablesSkipped == 1)
        #expect(!rig.link.isPaused)
        rig.layer.stale = nil
        rig.link.fire()
        #expect(rig.frames == 1)
        rig.layer.vends = false
        rig.loop.setNeedsFrame()
        rig.link.fire()
        #expect(rig.frames == 1)
    }

    @Test func `E-LIFE-4 drawable size is written only on layout`() {
        let rig = LoopRig()
        #expect(rig.layer.drawableSize == CGSize(width: 200, height: 100))
        #expect(rig.loop.stats.drawableSizeWrites == 1)
        rig.loop.interacting = true
        for _ in 0..<100 {
            rig.link.fire()
            rig.submitter.completeAll()
        }
        #expect(rig.loop.stats.drawableSizeWrites == 1)
        rig.loop.layoutChanged(size: CGSize(width: 120, height: 50), scale: 2)
        #expect(rig.loop.stats.drawableSizeWrites == 2 && rig.layer.drawableSize == CGSize(width: 240, height: 100))
        rig.loop.layoutChanged(size: CGSize(width: 120, height: 50), scale: 2)
        #expect(rig.loop.stats.drawableSizeWrites == 2)
    }

    @Test func `E-LIFE-4 zero non-finite and oversized layouts`() {
        let cases: [(CGSize, CGFloat, Int, PixelSize?)] = [
            (CGSize(width: 0, height: 0), 2, 16384, nil),
            (CGSize(width: 10, height: 0), 2, 16384, nil),
            (CGSize(width: 0, height: 10), 2, 16384, nil),
            (CGSize(width: -10, height: 10), 2, 16384, nil),
            (CGSize(width: 10, height: 10), 0, 16384, nil),
            (CGSize(width: CGFloat.nan, height: 10), 2, 16384, nil),
            (CGSize(width: 10, height: CGFloat.infinity), 2, 16384, nil),
            (CGSize(width: 0.2, height: 0.2), 2, 16384, PixelSize(width: 1, height: 1)),
            (CGSize(width: 9000, height: 10), 2, 16384, PixelSize(width: 16384, height: 20)),
            (CGSize(width: 9000, height: 9000), 2, 8192, PixelSize(width: 8192, height: 8192)),
            (CGSize(width: 333.5, height: 1), 3, 16384, PixelSize(width: 1001, height: 3)),
            (CGSize(width: 100, height: 50), 2, 0, PixelSize(width: 1, height: 1)),
        ]
        for (points, scale, limit, expected) in cases {
            #expect(PixelSize(points: points, scale: scale, maxSide: limit) == expected)
        }
        let rig = LoopRig(layout: false)
        rig.loop.interacting = true
        rig.loop.layoutChanged(size: .zero, scale: 2)
        rig.link.fire(times: 3)
        #expect(rig.frames == 0 && rig.link.isPaused && rig.loop.stats.drawableSizeWrites == 0)
        rig.submitter.maxTextureSide = 8192
        rig.loop.layoutChanged(size: CGSize(width: 9000, height: 10), scale: 1)
        #expect(rig.layer.drawableSize == CGSize(width: 8192, height: 10))
        rig.link.fire()
        #expect(rig.frames == 1)
        rig.loop.layoutChanged(size: .zero, scale: 1)
        rig.link.fire(times: 3)
        #expect(rig.frames == 1 && rig.link.isPaused)
    }

    // MARK: E-API-2

    @Test func `E-API-2 mutating the source mid-frame has no effect on the frame`() {
        let rig = LoopRig()
        let sampled = FrameDescription(clearColor: .black, quads: rig.source.quads)
        rig.submitter.duringSubmit = { rig.source.quads = [Quad(x: 1, y: 1, width: 1, height: 1, color: .blue)] }
        rig.link.fire()
        #expect(rig.submitter.submitted.map(\.frame) == [sampled])
    }

    @Test func `E-API-2 negative control a sampled reference would see the mutation`() {
        let rig = LoopRig()
        let sampled = FrameDescription(clearColor: .black, quads: rig.source.quads)
        rig.submitter.duringSubmit = { rig.source.quads = [] }
        rig.link.fire()
        let reread = rig.source.frame(for: FrameContext(clock: FrameClock(), ambience: false))
        #expect(reread != sampled)
    }

    @Test func `E-API-2 the source is sampled once per frame`() {
        let rig = LoopRig()
        rig.loop.interacting = true
        for _ in 0..<5 {
            rig.link.fire()
            rig.submitter.completeAll()
        }
        rig.link.fire(times: 4)
        #expect(rig.loop.stats.sourceCalls == rig.loop.stats.framesEncoded)
        #expect(rig.source.contexts.count == 8 && rig.frames == 8)
        #expect(rig.loop.stats.ticks == 9)
    }

    @Test func `E-API-2 the frame description is Sendable`() async {
        let frame = FrameDescription(clearColor: .red, quads: [Quad(x: 0, y: 0, width: 1, height: 1, color: .green)])
        let context = FrameContext(clock: FrameClock(), ambience: true)
        let echoed = await Task.detached { (frame, context) }.value
        #expect(echoed.0 == frame && echoed.1 == context)
    }

    // MARK: E-PLIST-1

    @Test func `E-PLIST-1 a phone asking for 120 without the key warns at startup`() {
        #expect(HostChecks.startupWarnings(info: nil, idiom: .phone, highRateAllowed: true) == [.highRateWithoutPlistKey])
        #expect(HostChecks.startupWarnings(info: ["Other": true], idiom: .phone, highRateAllowed: true) == [.highRateWithoutPlistKey])
        let rig = LoopRig(configuration: FrameLoopConfiguration(highRateAllowed: true, idiom: .phone), info: [:])
        #expect(rig.events == [.warning(.highRateWithoutPlistKey)])
    }

    @Test func `E-PLIST-1 the key present means no warning`() {
        let key = HostChecks.minimumFrameDurationKey
        #expect(key == "CADisableMinimumFrameDurationOnPhone")
        #expect(HostChecks.startupWarnings(info: [key: true], idiom: .phone, highRateAllowed: true) == [])
        #expect(HostChecks.startupWarnings(info: [key: NSNumber(value: true)], idiom: .phone, highRateAllowed: true) == [])
        let rig = LoopRig(configuration: FrameLoopConfiguration(highRateAllowed: true, idiom: .phone), info: [key: true])
        #expect(rig.events == [])
    }

    @Test func `E-PLIST-1 the key false or not a boolean still warns`() {
        let key = HostChecks.minimumFrameDurationKey
        for value in [false, "YES", 1.5] as [Any] {
            #expect(HostChecks.startupWarnings(info: [key: value], idiom: .phone, highRateAllowed: true) == [.highRateWithoutPlistKey])
        }
    }

    @Test func `E-PLIST-1 a pad or a Mac and a host not asking for 120 never warn`() {
        for idiom in [DeviceIdiom.pad, .mac] {
            #expect(HostChecks.startupWarnings(info: nil, idiom: idiom, highRateAllowed: true) == [])
        }
        #expect(HostChecks.startupWarnings(info: nil, idiom: .phone, highRateAllowed: false) == [])
        #expect(DeviceIdiom.idiom(model: "iPhone15,2") == .phone)
        #expect(DeviceIdiom.idiom(model: "iPad13,4") == .pad)
        #expect(DeviceIdiom.idiom(model: "arm64") == .mac)
        #expect(DeviceIdiom.modelName(Array("iPhone17,1".utf8CString)) == "iPhone17,1")
        #expect(DeviceIdiom.modelName([0, 65]) == "")
        #expect(DeviceIdiom.modelName([]) == "")
        #expect(DeviceIdiom.current == .mac)
    }

    // MARK: Adapters

    @Test func `E-RATE-1 system conditions map every thermal state and report changes`() {
        #expect([ProcessInfo.ThermalState.nominal, .fair, .serious, .critical].map { ThermalLevel($0) } == ThermalLevel.allCases)
        let center = NotificationCenter()
        let conditions = SystemConditions(center: center)
        #expect(conditions.thermal == ThermalLevel(ProcessInfo.processInfo.thermalState))
        var seen: [(Bool, ThermalLevel)] = []
        conditions.onChange = { seen.append(($0, $1)) }
        conditions.update(lowPower: true, thermal: .serious)
        #expect(conditions.lowPower && conditions.thermal == .serious)
        conditions.refresh(from: .processInfo)
        #expect(seen.count == 2 && seen[0].0 && seen[0].1 == .serious)
        // A notification posted on the main thread reaches the main-queue observer before `post` returns.
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(seen.count == 4)
        conditions.invalidate()

        let rig = LoopRig()
        let fed = SystemConditions(center: center)
        let loop = FrameLoop(
            link: rig.link, layer: rig.layer, submitter: rig.submitter, source: rig.source,
            configuration: FrameLoopConfiguration(idiom: .mac), info: nil, systemConditions: fed, events: { _ in })
        rig.source.motion = .ambient
        fed.update(lowPower: false, thermal: .critical)
        #expect(loop.conditions.thermal == .critical)
        loop.invalidate()
        #expect(rig.link.invalidated)
    }
}
