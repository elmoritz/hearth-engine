import HearthEngine
import HearthHarness
import Metal
import Testing

/// E-HAR-5: without a Metal device the GPU suite skips, and a skip is never a pass.
@Suite struct DeviceGateTests {
    @Test(.requiresGPU) func `E-HAR-5 with a device the GPU suite runs`() async throws {
        let availability = HarnessGPU.probe()
        #expect(availability.isAvailable)
        #expect(HarnessGPU.isAvailable)
        let device = try #require(availability.device)
        #expect(!device.name.isEmpty)
        #expect(try await HarnessGPU.makeRenderer(availability).deviceName == device.name)
    }

    @Test func `E-HAR-5 the GPU trait skips on a nil device and on HEARTH_NO_GPU and runs with a device`() async throws {
        // The condition every GPU test carries, evaluated as the test runner evaluates it.
        let noDevice = HarnessGPU.probe(environment: [:], provider: { nil })
        #expect(try await !ConditionTrait.requiresGPU(noDevice).evaluate())
        let hidden = HarnessGPU.probe(environment: ["HEARTH_NO_GPU": "1"], provider: { MTLCreateSystemDefaultDevice() })
        #expect(try await !ConditionTrait.requiresGPU(hidden).evaluate())
        // The trait the tests use is the one for what this process probed, whatever that is.
        #expect(try await ConditionTrait.requiresGPU.evaluate() == HarnessGPU.current.isAvailable)
        #expect(HarnessGPU.isAvailable == HarnessGPU.current.isAvailable)
        #expect(HarnessGPU.current.isAvailable == HarnessGPU.probe().isAvailable)
    }

    @Test(.requiresGPU) func `E-HAR-5 the GPU trait runs with a device`() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        #expect(try await ConditionTrait.requiresGPU(.available(device)).evaluate())
        #expect(try await ConditionTrait.requiresGPU(HarnessGPU.probe(environment: [:], provider: { device })).evaluate())
    }

    @Test func `E-HAR-5 a nil device makes the GPU suite skip not fail`() async {
        let availability = HarnessGPU.probe(environment: [:], provider: { nil })
        #expect(!availability.isAvailable)
        #expect(availability.device == nil)
        guard case .unavailable(let reason) = availability else {
            Issue.record("a nil device must be unavailable")
            return
        }
        #expect(reason == "no Metal device")
        // What a GPU test would do without the trait: a typed error, not a crash.
        await #expect(throws: EngineError.noDevice) { try await HarnessGPU.makeRenderer(availability) }
    }

    @Test func `E-HAR-5 HEARTH_NO_GPU simulates a runner without a device`() {
        #expect(HarnessGPU.noGPUVariable == "HEARTH_NO_GPU")
        var asked = 0
        let hidden = HarnessGPU.probe(environment: ["HEARTH_NO_GPU": "1"], provider: {
            asked += 1
            return MTLCreateSystemDefaultDevice()
        })
        #expect(!hidden.isAvailable)
        #expect(asked == 0)
        guard case .unavailable(let reason) = hidden else {
            Issue.record("HEARTH_NO_GPU=1 must hide the device")
            return
        }
        #expect(reason == "HEARTH_NO_GPU=1")

        // Anything but "1" leaves the answer to the provider.
        for environment in [[:], ["HEARTH_NO_GPU": ""], ["HEARTH_NO_GPU": "0"], ["OTHER": "1"]] {
            var calls = 0
            let availability = HarnessGPU.probe(environment: environment, provider: {
                calls += 1
                return nil
            })
            #expect(calls == 1)
            #expect(!availability.isAvailable)
        }
    }

    @Test func `E-HAR-5 a receipt lists every skipped id and is incomplete`() {
        let receipt = Receipt.skippingGPUSuite(ids: ["E-HAR-3", "E-HAR-1", "E-VAL-1"])
        #expect(receipt.skippedIDs == ["E-HAR-1", "E-HAR-3", "E-VAL-1"])
        #expect(receipt.passedIDs == [])
        #expect(receipt.failedIDs == [])
        #expect(receipt.gpu == nil)
        #expect(!receipt.isComplete)

        // One skip among passes on a real GPU is still incomplete, and the skip is named.
        var mixed = Receipt(gpu: "Apple M1 Pro")
        mixed.record("E-HAR-2", .passed)
        mixed.record("E-HAR-1", .skipped)
        #expect(mixed.skippedIDs == ["E-HAR-1"])
        #expect(mixed.passedIDs == ["E-HAR-2"])
        #expect(!mixed.isComplete)
    }

    @Test func `E-HAR-5 a receipt is complete only with ids a GPU and no skip or failure`() {
        var complete = Receipt(gpu: "Apple M1 Pro")
        #expect(!complete.isComplete)  // nothing recorded proves nothing
        complete.record("E-HAR-1", .passed)
        complete.record("E-HAR-2", .passed)
        #expect(complete.isComplete)
        #expect(complete.passedIDs == ["E-HAR-1", "E-HAR-2"])

        var noGPU = Receipt(gpu: nil)
        noGPU.record("E-HAR-2", .passed)
        #expect(!noGPU.isComplete)

        var failed = complete
        failed.record("E-HAR-3", .failed)
        #expect(!failed.isComplete)
        #expect(failed.failedIDs == ["E-HAR-3"])

        // An id with several tests keeps its worst outcome, in either order.
        var worst = Receipt(gpu: "Apple M1 Pro")
        worst.record("E-HAR-1", .passed)
        worst.record("E-HAR-1", .skipped)
        worst.record("E-HAR-1", .passed)
        #expect(worst.skippedIDs == ["E-HAR-1"] && worst.passedIDs == [])
        worst.record("E-HAR-1", .failed)
        worst.record("E-HAR-1", .skipped)
        #expect(worst.failedIDs == ["E-HAR-1"] && worst.skippedIDs == [])
        #expect(Receipt.Outcome.passed < .skipped && Receipt.Outcome.skipped < .failed)
        #expect(Receipt.skippingGPUSuite(ids: []) == Receipt(gpu: nil))
    }
}
