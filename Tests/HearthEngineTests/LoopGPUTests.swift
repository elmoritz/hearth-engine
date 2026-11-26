import Foundation
import HearthHarness
import Metal
import QuartzCore
import Testing

@testable import HearthEngine

/// The on-screen pieces against a real `CAMetalLayer` and GPU: layer configuration, drawable sizes, the real
/// submitter and the public loop.
@MainActor
@Suite struct LoopGPUTests {
    static func device() throws -> MTLDevice {
        try #require(HarnessGPU.current.device)
    }

    static func surface() throws -> (CAMetalLayer, MetalLayerSurface) {
        let layer = CAMetalLayer()
        return (layer, MetalLayerSurface(layer: layer, device: try device()))
    }

    static let layouts: [(CGSize, CGFloat)] = [
        (CGSize(width: 320, height: 480), 2), (CGSize(width: 1024, height: 768), 1), (CGSize(width: 375, height: 812), 3),
    ]

    // MARK: E-LIFE-4

    @Test(.requiresGPU) func `E-LIFE-4 drawable size follows layout on a real layer`() throws {
        let (layer, surface) = try Self.surface()
        let rig = LoopRig(layout: false)
        let loop = FrameLoop(
            link: rig.link, layer: surface, submitter: rig.submitter, source: rig.source,
            configuration: FrameLoopConfiguration(idiom: .mac), info: nil, events: { _ in })
        for (points, scale) in Self.layouts {
            loop.layoutChanged(size: points, scale: scale)
            let expected = CGSize(width: points.width * scale, height: points.height * scale)
            #expect(abs(layer.drawableSize.width - expected.width) <= 1 && abs(layer.drawableSize.height - expected.height) <= 1)
            let drawable = try #require(surface.nextDrawable())
            #expect(abs(CGFloat(drawable.pixelWidth) - expected.width) <= 1)
            #expect(abs(CGFloat(drawable.pixelHeight) - expected.height) <= 1)
        }
    }

    static func marker(width: Int, height: Int) -> FrameDescription {
        FrameDescription(clearColor: .black, quads: [Quad(x: Float(width - 3), y: Float(height - 5), width: 1, height: 1, color: .green)])
    }

    @Test(.requiresGPU) func `E-LIFE-4 a marker sprite lands at its pixel after each resize`() async throws {
        let renderer = try await HarnessGPU.makeRenderer()
        for (points, scale) in Self.layouts {
            let size = try #require(PixelSize(points: points, scale: scale, maxSide: renderer.capabilities.maxTextureSide))
            let image = try renderer.render(Self.marker(width: size.width, height: size.height),
                                            target: RenderTarget(width: size.width, height: size.height, format: .bgra8Unorm))
            #expect(image[size.width - 3, size.height - 5] == .green)
            #expect(image[size.width - 4, size.height - 5] == .black)
            #expect(image[size.width - 3, size.height - 4] == .black)
        }
    }

    @Test(.requiresGPU) func `E-LIFE-4 negative control a stale size misplaces the marker`() async throws {
        let renderer = try await HarnessGPU.makeRenderer()
        let old = try #require(PixelSize(points: Self.layouts[0].0, scale: Self.layouts[0].1, maxSide: 16384))
        let new = try #require(PixelSize(points: Self.layouts[1].0, scale: Self.layouts[1].1, maxSide: 16384))
        // The frame laid out for the new size, drawn into a drawable of the old size.
        let image = try renderer.render(Self.marker(width: new.width, height: new.height),
                                        target: RenderTarget(width: old.width, height: old.height))
        #expect(image[old.width - 3, old.height - 5] != .green)
        #expect(image[new.width - 3, new.height - 5] == nil)
    }

    @Test(.requiresGPU) func `E-LIFE-4 the configured layer never scales old pixels`() throws {
        let (layer, _) = try Self.surface()
        #expect(layer.contentsGravity == .topLeft)
        #expect(!layer.presentsWithTransaction)
        #expect(layer.pixelFormat == .bgra8Unorm)
        #expect(layer.device === (try Self.device()))
    }

    // MARK: E-PASS-1, the layer half

    @Test(.requiresGPU) func `E-PASS-1 the layer is framebuffer-only with three drawables`() throws {
        let (layer, _) = try Self.surface()
        #expect(layer.framebufferOnly)
        #expect(layer.maximumDrawableCount == 3)
    }

    // MARK: E-PASS-2 and E-LIFE-2 on a real drawable

    @Test(.requiresGPU) func `E-PASS-2 a frame on a real drawable is one pass and completes`() async throws {
        let device = try Self.device()
        let (layer, surface) = try Self.surface()
        layer.drawableSize = CGSize(width: 64, height: 32)
        let warmup = try await MetalBackend.warm(device: device, restrictions: .none)
        let submitter = try MetalFrameSubmitter(backend: MetalBackend(device: device, warmup: warmup), options: RenderOptions())
        #expect(submitter.maxTextureSide == 16384)
        let frame = HarnessScene.bars.frame(.zero)
        for presentAfter in [nil, 1.0 / 30] as [Double?] {
            let drawable = try #require(surface.nextDrawable())
            let outcome = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandBufferOutcome, any Error>) in
                submitter.onCompletion = { _, outcome in continuation.resume(returning: outcome) }
                do {
                    let id = try submitter.submit(frame, to: drawable, presentAfter: presentAfter)
                    submitter.waitUntilScheduled(id)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            #expect(outcome == .completed)
            #expect(submitter.backend.counters.renderPasses == 1)
            #expect(submitter.backend.counters.draws == frame.quads.count + 1)
        }
        // A bigger frame grows the ring slot; an empty one needs no vertices.
        for quads in [Array(repeating: Quad(x: 0, y: 0, width: 2, height: 2, color: .red), count: 200), []] {
            let drawable = try #require(surface.nextDrawable())
            _ = try submitter.submit(FrameDescription(quads: quads), to: drawable, presentAfter: nil)
            #expect(submitter.backend.counters.draws == quads.count + 1)
        }
    }

    @Test(.requiresGPU) func `E-LIFE-2 the real submitter refuses a foreign drawable and a missing texture before any GPU work`() async throws {
        let device = try Self.device()
        let (layer, surface) = try Self.surface()
        layer.drawableSize = CGSize(width: 8, height: 8)
        let warmup = try await MetalBackend.warm(device: device, restrictions: .none)
        let submitter = try MetalFrameSubmitter(backend: MetalBackend(device: device, warmup: warmup), options: RenderOptions())
        #expect(throws: EngineError.gpuFailure("drawable: not a CAMetalDrawable")) {
            try submitter.submit(FrameDescription(), to: FakeDrawable(CGSize(width: 8, height: 8)), presentAfter: nil)
        }
        let drawable = try #require(surface.nextDrawable())
        #expect(throws: EngineError.missingTexture("absent")) {
            try submitter.submit(FrameDescription(quads: [Quad(x: 0, y: 0, width: 1, height: 1, texture: "absent")]),
                                 to: drawable, presentAfter: nil)
        }
        submitter.waitUntilScheduled(SubmissionID(value: 99))
    }

    // MARK: E-PSO-3, the public loop

    @Test(.requiresGPU) func `E-PSO-3 the on-screen loop is built with every pipeline warmed off the main thread`() async throws {
        let layer = CAMetalLayer()
        let source = FakeSource()
        let loop = try await FrameLoop(layer: layer, device: Self.device(), source: source)
        let submitter = try #require(loop.submitter as? MetalFrameSubmitter)
        #expect(submitter.backend.counters.pipelinesCreated == PipelineKey.precompiled(layout: .singlePass).count)
        #expect(submitter.backend.counters.pipelinesCreatedOnMainThread == 0)
        #expect(loop.contentRate == .paused)
        #expect(layer.framebufferOnly && layer.contentsGravity == .topLeft)
        loop.invalidate()
    }

    @Test func `E-HAR-4 a loop without a device throws noDevice`() async {
        await #expect(throws: EngineError.noDevice) {
            _ = try await FrameLoop(layer: CAMetalLayer(), device: nil, source: FakeSource())
        }
    }

    // MARK: E-RATE-4, the Metal link adapter

    @Test func `E-RATE-4 the Metal link reports target-to-target intervals`() {
        let layer = CAMetalLayer()
        let driver = MetalDisplayLinkDriver(layer: layer)
        var ticks: [LinkTick] = []
        driver.onTick = { ticks.append($0) }
        driver.deliver(target: 10, drawable: nil)
        driver.deliver(target: 10 + 1.0 / 60, drawable: nil)
        #expect(ticks.map(\.timestamp) == [10, 10])
        #expect(ticks.map(\.targetTimestamp) == [10, 10 + 1.0 / 60])
        driver.isPaused = false
        #expect(!driver.isPaused)
        driver.preferredRange = FramePolicy.ambience
        #expect(driver.preferredRange == FramePolicy.ambience)
        driver.invalidate()
        #expect(makeDisplayLink(.displayLink, layer: layer) is MetalDisplayLinkDriver)
    }
}
