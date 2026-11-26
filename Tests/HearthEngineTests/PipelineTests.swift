import HearthHarness
import Metal
import Testing

@testable import HearthEngine

/// Pipelines, render passes and the feature floor: what the warm-up builds, what a frame encodes, and that both
/// pass layouts give the analytic pixels.
@Suite struct PipelineTests {
    static let clear = RGBA8(17, 34, 51)
    static let layouts: [(GPURestrictions, PassLayout)] = [(.none, .singlePass), (.floor, .twoPass)]

    static func device() throws -> MTLDevice {
        try #require(HarnessGPU.current.device)
    }

    static func backend(
        restrictions: GPURestrictions = .none, functions: @escaping FunctionTable = { $0.functions }
    ) async throws -> MetalBackend {
        let device = try device()
        let warmup = try await MetalBackend.warm(device: device, restrictions: restrictions, functions: functions)
        return try MetalBackend(device: device, warmup: warmup)
    }

    static func render(_ backend: MetalBackend, _ frame: FrameDescription, width: Int, height: Int) throws -> PixelImage {
        let target = RenderTarget(width: width, height: height)
        let plan = try FramePlan(frame: frame, target: target, options: RenderOptions(), maxTextureSide: backend.capabilities.maxTextureSide) {
            backend.hasTexture($0)
        }
        return try backend.render(plan, target: target)
    }

    static func gpuFailureText(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch let error as EngineError {
            if case .gpuFailure(let text) = error { return text }
            return "\(error)"
        } catch {
            return "\(error)"
        }
    }

    // MARK: E-PSO-1

    @Test(.requiresGPU) func `E-PSO-1 no pipeline is created after warm-up across a feature tour`() async throws {
        for (restrictions, layout) in Self.layouts {
            let renderer = try await HarnessGPU.makeRenderer(restrictions: restrictions)
            #expect(renderer.capabilities.passLayout == layout)
            let warmed = renderer.counters.pipelinesCreated
            #expect(warmed == PipelineKey.precompiled(layout: layout).count)
            for scene in try HarnessScene.catalogue() {
                try scene.load(into: renderer)
                for time in [0, 1.3, 2_592_000] {
                    _ = try scene.render(at: EngineTime(seconds: time), with: renderer)
                }
            }
            for format in PixelFormat.allCases where format.isEightBit {
                for blend in Quad.Blend.allCases {
                    let frame = FrameDescription(clearColor: Self.clear, quads: [
                        Quad(x: 0, y: 0, width: 4, height: 4, color: .red, blend: blend),
                        Quad(x: 1, y: 1, width: 2, height: 2, texture: "flat/white", blend: .premultipliedOver),
                    ])
                    _ = try renderer.render(frame, target: RenderTarget(width: 4, height: 4, format: format))
                }
            }
            #expect(renderer.counters.pipelinesCreated == warmed)
        }
    }

    @Test(.requiresGPU) func `E-PSO-1 a key outside the warmed set throws instead of building`() async throws {
        let backend = try await Self.backend()
        let before = backend.counters
        let foreign = PipelineKey.scene(.color(.red), blend: .opaque, layout: .twoPass, targetFormat: .rgba8Unorm)
        #expect(!backend.pipelineKeys.contains(foreign))
        let text = await Self.gpuFailureText { _ = try backend.pipeline(foreign) }
        #expect(text == "pipeline solid/opaque/twoPass/scene was not built at warm-up")
        #expect(backend.counters == before)
    }

    @Test(.requiresGPU) func `E-PSO-1 an empty frame and a single quad create nothing`() async throws {
        let renderer = try await HarnessGPU.makeRenderer()
        let warmed = renderer.counters.pipelinesCreated
        _ = try renderer.render(FrameDescription(), target: RenderTarget(width: 1, height: 1))
        _ = try renderer.render(FrameDescription(quads: [Quad(x: 0, y: 0, width: 1, height: 1, color: .red)]),
                                target: RenderTarget(width: 1, height: 1))
        #expect(renderer.counters.pipelinesCreated == warmed)
    }

    @Test(.requiresGPU) func `Perf E-PSO-1 pipelines after warm-up`() async throws {
        let renderer = try await HarnessGPU.makeRenderer()
        let warmed = renderer.counters.pipelinesCreated
        let postcard = try HarnessScene.postcard()
        try postcard.load(into: renderer)
        _ = try postcard.render(at: .zero, with: renderer)
        print("PERF pso.after-warmup \(renderer.counters.pipelinesCreated - warmed) pipelines count")
        #expect(renderer.counters.pipelinesCreated == warmed)
    }

    // MARK: E-PSO-2

    @Test func `E-PSO-2 the precompiled key set is listed`() {
        let keys = PipelineKey.precompiled(layout: .singlePass, targetFormats: [.bgra8Unorm])
        #expect(keys.map(\.description) == [
            "solid/opaque/singlePass/bgra8Unorm", "solid/premultipliedOver/singlePass/bgra8Unorm",
            "textured/opaque/singlePass/bgra8Unorm", "textured/premultipliedOver/singlePass/bgra8Unorm",
            "final/opaque/singlePass/bgra8Unorm",
        ])
        #expect(PipelineKey.precompiled(layout: .twoPass).map(\.description) == [
            "solid/opaque/twoPass/scene", "solid/premultipliedOver/twoPass/scene",
            "textured/opaque/twoPass/scene", "textured/premultipliedOver/twoPass/scene",
            "final/opaque/twoPass/rgba8Unorm", "final/opaque/twoPass/bgra8Unorm",
        ])
        #expect(PipelineKey.precompiled(layout: .singlePass).count == 10)
    }

    @Test(.requiresGPU) func `E-PSO-2 the warmed set equals the precompiled set`() async throws {
        for (restrictions, layout) in Self.layouts {
            let backend = try await Self.backend(restrictions: restrictions)
            #expect(backend.pipelineKeys == Set(PipelineKey.precompiled(layout: layout)))
        }
    }

    @Test func `E-PSO-2 negative control a missing key is reported`() {
        let keys = PipelineKey.precompiled(layout: .singlePass)
        for dropped in keys.indices {
            var fewer = keys
            fewer.remove(at: dropped)
            #expect(Set(fewer) != Set(keys))
        }
    }

    @Test func `E-PSO-2 every key the encoder can ask for is precompiled`() {
        for layout in PassLayout.allCases {
            let set = Set(PipelineKey.precompiled(layout: layout))
            for format in PipelineKey.targetFormats {
                for source in [FramePlan.Source.color(.red), .texture("any")] {
                    for blend in Quad.Blend.allCases {
                        #expect(set.contains(.scene(source, blend: blend, layout: layout, targetFormat: format)))
                    }
                }
                #expect(set.contains(.final(layout: layout, targetFormat: format)))
            }
        }
    }

    @Test func `E-PSO-2 keys are unique`() {
        for layout in PassLayout.allCases {
            let keys = PipelineKey.precompiled(layout: layout)
            #expect(Set(keys).count == keys.count)
        }
        let single = Set(PipelineKey.precompiled(layout: .singlePass).filter { $0.stage == .final })
        let two = Set(PipelineKey.precompiled(layout: .twoPass).filter { $0.stage == .final })
        #expect(single.count == 2 && two.count == 2 && single.isDisjoint(with: two))
    }

    @Test(.requiresGPU) func `Perf E-PSO-2 pipelines warmed`() async throws {
        for (restrictions, layout) in Self.layouts {
            let renderer = try await HarnessGPU.makeRenderer(restrictions: restrictions)
            print("PERF pso.warm.\(layout) \(renderer.counters.pipelinesCreated) pipelines count")
            #expect(renderer.counters.pipelinesCreated == PipelineKey.precompiled(layout: layout).count)
        }
    }

    // MARK: E-PSO-3

    @MainActor
    @Test(.requiresGPU) func `E-PSO-3 every pipeline is built off the main thread`() async throws {
        for (restrictions, _) in Self.layouts {
            let renderer = try await HarnessGPU.makeRenderer(restrictions: restrictions)
            #expect(renderer.counters.pipelinesCreatedOnMainThread == 0)
            #expect(renderer.counters.pipelinesCreated == renderer.backend.builds.count)
            #expect(renderer.backend.builds.allSatisfy { !$0.onMainThread })
            // Everything is built by the time init returns: before any frame.
            #expect(renderer.counters.renderPasses == 0 && renderer.counters.draws == 0)
        }
    }

    @Test(.requiresGPU) func `E-PSO-3 a pipeline that fails to build fails init with gpuFailure`() async throws {
        let broken: FunctionTable = { key in
            key.stage == .textured && key.blend == .opaque ? (key.functions.vertex, "no_such_fragment") : key.functions
        }
        for (restrictions, _) in Self.layouts {
            let text = await Self.gpuFailureText { _ = try await Self.backend(restrictions: restrictions, functions: broken) }
            #expect(text == "no_such_fragment: the device returned nothing")
        }
        let vertexless: FunctionTable = { key in ("no_such_vertex", key.functions.fragment) }
        let text = await Self.gpuFailureText { _ = try await Self.backend(restrictions: .floor, functions: vertexless) }
        #expect(text == "no_such_vertex: the device returned nothing")
    }

    @Test(.requiresGPU) func `E-PSO-3 warm-up builds each key exactly once`() async throws {
        for (restrictions, layout) in Self.layouts {
            let backend = try await Self.backend(restrictions: restrictions)
            let built = backend.builds.map(\.key)
            #expect(built.count == Set(built).count)
            #expect(Set(built) == Set(PipelineKey.precompiled(layout: layout)))
        }
    }

    // MARK: E-PASS-1

    @Test func `E-PASS-1 the single-pass descriptor audit`() {
        let passes = PassLayout.singlePass.passes
        #expect(passes == [PassDescription(attachments: [
            PassAttachment(role: .target, load: .dontCare, store: .store, storage: .target),
            PassAttachment(role: .scene, load: .clear, store: .dontCare, storage: .memoryless),
        ])])
        let descriptor = MetalBackend.renderPass(passes[0], target: nil, scene: nil, clear: Self.clear)
        #expect(descriptor.colorAttachments[0].loadAction == .dontCare)
        #expect(descriptor.colorAttachments[0].storeAction == .store)
        #expect(descriptor.colorAttachments[1].loadAction == .clear)
        #expect(descriptor.colorAttachments[1].storeAction == .dontCare)
        #expect(descriptor.colorAttachments[1].clearColor.green == 34.0 / 255)
        #expect(Self.audit(passes))
    }

    @Test func `E-PASS-1 the two-pass descriptor audit`() {
        let passes = PassLayout.twoPass.passes
        #expect(passes == [
            PassDescription(attachments: [PassAttachment(role: .scene, load: .clear, store: .store, storage: .private)]),
            PassDescription(attachments: [PassAttachment(role: .target, load: .dontCare, store: .store, storage: .target)]),
        ])
        let first = MetalBackend.renderPass(passes[0], target: nil, scene: nil, clear: Self.clear)
        let second = MetalBackend.renderPass(passes[1], target: nil, scene: nil, clear: Self.clear)
        #expect(first.colorAttachments[0].loadAction == .clear && first.colorAttachments[0].storeAction == .store)
        #expect(second.colorAttachments[0].loadAction == .dontCare && second.colorAttachments[0].storeAction == .store)
        #expect(second.colorAttachments[1].texture == nil)
        #expect(Self.audit([passes[1]]))
    }

    /// The catalogue's rule: the target is cleared or don't-care and stored; every other attachment of a pass that
    /// writes the target is memoryless and don't-care.
    static func audit(_ passes: [PassDescription]) -> Bool {
        passes.allSatisfy { pass in
            pass.attachments.allSatisfy { attachment in
                switch attachment.role {
                case .target: attachment.store == .store
                case .scene: attachment.storage == .memoryless && attachment.store == .dontCare
                }
            }
        }
    }

    @Test func `E-PASS-1 negative control a stored scene attachment fails the audit`() {
        var passes = PassLayout.singlePass.passes
        passes[0].attachments[1].store = .store
        #expect(!Self.audit(passes))
        var unstored = PassLayout.singlePass.passes
        unstored[0].attachments[0].store = .dontCare
        #expect(!Self.audit(unstored))
    }

    @Test func `E-PASS-1 the offscreen target is the only stored non-drawable`() {
        for layout in PassLayout.allCases {
            let targets = layout.passes.flatMap(\.attachments).filter { $0.role == .target }
            #expect(targets.count == 1 && targets[0].store == .store && targets[0].storage == .target)
        }
        let scenes = PassLayout.singlePass.passes.flatMap(\.attachments).filter { $0.role == .scene }
        #expect(scenes.map(\.storage) == [.memoryless])
    }

    @Test(.requiresGPU) func `E-PASS-1 single-pass scene pipelines never write the drawable attachment`() async throws {
        let library = try await MetalBackend.warm(device: Self.device(), restrictions: .floor).library
        for key in PipelineKey.precompiled(layout: .singlePass) {
            let descriptor = try MetalBackend.describe(key, library: library)
            if key.stage == .final {
                #expect(descriptor.colorAttachments[0].writeMask == .all)
                #expect(descriptor.colorAttachments[1].writeMask == [])
            } else {
                #expect(descriptor.colorAttachments[0].writeMask == [])
                #expect(descriptor.colorAttachments[1].writeMask == .all)
                #expect(descriptor.colorAttachments[1].pixelFormat == .rgba16Float)
                #expect(descriptor.colorAttachments[1].isBlendingEnabled == (key.blend == .premultipliedOver))
            }
            #expect(!descriptor.colorAttachments[0].isBlendingEnabled)
        }
        for key in PipelineKey.precompiled(layout: .twoPass) {
            let descriptor = try MetalBackend.describe(key, library: library)
            #expect(descriptor.colorAttachments[0].writeMask == .all)
            #expect(descriptor.colorAttachments[0].pixelFormat == (key.stage == .final ? key.targetFormat?.metal : .rgba16Float))
            #expect(descriptor.colorAttachments[1].pixelFormat == .invalid)
        }
    }

    // MARK: E-PASS-2

    @Test(.requiresGPU) func `E-PASS-2 one render pass per frame on the Mac`() async throws {
        let renderer = try await HarnessGPU.makeRenderer()
        #expect(renderer.capabilities.passLayout == .singlePass)
        let postcard = try HarnessScene.postcard()
        try postcard.load(into: renderer)
        for time in [0, 0.5, 7.25] {
            _ = try postcard.render(at: EngineTime(seconds: time), with: renderer)
            #expect(renderer.counters.renderPasses == 1)
        }
    }

    @Test(.requiresGPU) func `E-PASS-2 two passes per frame on the fallback`() async throws {
        let renderer = try await HarnessGPU.makeRenderer(restrictions: GPURestrictions(disabled: .readsRenderTargetInPass))
        #expect(renderer.capabilities.passLayout == .twoPass)
        #expect(renderer.capabilities.maxTextureSide == 16384)
        let postcard = try HarnessScene.postcard()
        try postcard.load(into: renderer)
        _ = try postcard.render(at: .zero, with: renderer)
        #expect(renderer.counters.renderPasses == 2)
    }

    @Test(.requiresGPU) func `E-PASS-2 a refused framebuffer-fetch pipeline selects the fallback`() async throws {
        let refusing: FunctionTable = { key in
            key.layout == .singlePass && key.stage == .final ? (key.functions.vertex, "no_such_fetch") : key.functions
        }
        let fallback = try await Self.backend(functions: refusing)
        #expect(fallback.passLayout == .twoPass)
        #expect(!fallback.capabilities.features.contains(.readsRenderTargetInPass))
        let reference = try await Self.backend()
        #expect(reference.passLayout == .singlePass)
        #expect(GPUCapabilities(features: .all, maxTextureSide: 8192).passLayout == .singlePass)
        #expect(GPUCapabilities(features: [], maxTextureSide: 8192).passLayout == .twoPass)
    }

    @Test(.requiresGPU) func `E-PASS-2 an empty frame is still one pass`() async throws {
        for (restrictions, layout) in Self.layouts {
            let renderer = try await HarnessGPU.makeRenderer(restrictions: restrictions)
            _ = try renderer.render(FrameDescription(clearColor: Self.clear), target: RenderTarget(width: 3, height: 3))
            #expect(renderer.counters.renderPasses == (layout == .singlePass ? 1 : 2))
            #expect(renderer.counters.draws == 1)
            #expect(renderer.counters.pipelineBinds == 1)
        }
    }

    @Test(.requiresGPU) func `E-PASS-2 empty and partly covered frames are defined on both layouts`() async throws {
        for (restrictions, _) in Self.layouts {
            let renderer = try await HarnessGPU.makeRenderer(restrictions: restrictions)
            for format in [PixelFormat.rgba8Unorm, .bgra8Unorm] {
                let target = RenderTarget(width: 33, height: 7, format: format)
                let empty = try renderer.render(FrameDescription(clearColor: Self.clear), target: target)
                #expect(try matchesExactly(empty, expectedImage(width: 33, height: 7, clear: Self.clear) { _, _ in nil }))
                let third = FrameDescription(clearColor: Self.clear, quads: [Quad(x: 0, y: 0, width: 11, height: 7, color: .green)])
                let covered = try renderer.render(third, target: target)
                #expect(try matchesExactly(covered, expectedImage(width: 33, height: 7, clear: Self.clear) { x, _ in
                    x < 11 ? .green : nil
                }))
            }
        }
    }

    @Test(.requiresGPU) func `E-PASS-2 negative control a missing final stage fails the coverage check`() async throws {
        for (restrictions, _) in Self.layouts {
            let backend = try await Self.backend(restrictions: restrictions)
            backend.skipsFinalStage = true
            let frame = FrameDescription(clearColor: Self.clear, quads: [Quad(x: 0, y: 0, width: 11, height: 7, color: .green)])
            let image = try Self.render(backend, frame, width: 33, height: 7)
            #expect(try !matchesExactly(image, expectedImage(width: 33, height: 7, clear: Self.clear) { x, _ in
                x < 11 ? .green : nil
            }))
            #expect(backend.counters.draws == 1)
        }
    }

    @Test(.requiresGPU) func `Perf E-PASS-2 passes per frame`() async throws {
        let renderer = try await HarnessGPU.makeRenderer()
        let postcard = try HarnessScene.postcard()
        try postcard.load(into: renderer)
        _ = try postcard.render(at: .zero, with: renderer)
        print("PERF frame.passes \(renderer.counters.renderPasses) passes count")
        print("PERF frame.draws.postcard \(renderer.counters.draws) draws count")
        print("PERF frame.binds.postcard \(renderer.counters.pipelineBinds) binds count")
        #expect(renderer.counters.renderPasses == 1)
    }

    // MARK: E-PASS-3

    @Test func `E-PASS-3 opaque draws come first with blending off`() throws {
        let frame = FrameDescription(quads: [
            Quad(x: 0, y: 0, width: 2, height: 2, color: .red),
            Quad(x: 0, y: 0, width: 2, height: 2, texture: "t"),
            Quad(x: 0, y: 0, width: 2, height: 2, color: .blue, blend: .premultipliedOver),
            Quad(x: 0, y: 0, width: 2, height: 2, texture: "t", blend: .premultipliedOver),
        ])
        let plan = try FramePlan(frame: frame, target: RenderTarget(width: 2, height: 2), options: RenderOptions()) { _ in true }
        #expect(plan.draws.map(\.blend) == [.opaque, .opaque, .premultipliedOver, .premultipliedOver])
        for layout in PassLayout.allCases {
            for draw in plan.draws {
                let key = PipelineKey.scene(draw.source, blend: draw.blend, layout: layout, targetFormat: .bgra8Unorm)
                #expect(key.attachments.allSatisfy { $0.blend == (($0.writes && draw.blend == .premultipliedOver) ? .premultipliedOver : .opaque) })
            }
        }
    }

    static let halfRed = RGBA8(128, 0, 0, 128)

    static func blendFrame(_ blend: Quad.Blend) -> FrameDescription {
        FrameDescription(clearColor: .black, quads: [
            Quad(x: 0, y: 0, width: 4, height: 4, color: .blue),
            Quad(x: 1, y: 1, width: 2, height: 2, color: halfRed, blend: blend),
        ])
    }

    @Test(.requiresGPU) func `E-PASS-3 premultiplied over blends on the GPU`() async throws {
        for (restrictions, _) in Self.layouts {
            let renderer = try await HarnessGPU.makeRenderer(restrictions: restrictions)
            let image = try renderer.render(Self.blendFrame(.premultipliedOver), target: RenderTarget(width: 4, height: 4))
            let mixed = try #require(image[1, 2])
            #expect(abs(Int(mixed.r) - 128) <= 1 && mixed.g == 0 && abs(Int(mixed.b) - 127) <= 1 && mixed.a == 255)
            #expect(image[0, 0] == .blue && image[3, 3] == .blue)
        }
    }

    @Test func `E-PASS-3 an opaque quad after a blended one throws opaqueAfterBlended`() {
        let frame = FrameDescription(quads: [
            Quad(x: 0, y: 0, width: 2, height: 2, color: .red),
            Quad(x: 0, y: 0, width: 2, height: 2, color: .red, blend: .premultipliedOver),
            Quad(x: 0, y: 0, width: 2, height: 2, color: .red),
            Quad(x: 0, y: 0, width: 2, height: 2, color: .red),
        ])
        #expect(throws: EngineError.opaqueAfterBlended(index: 2)) {
            try FramePlan(frame: frame, target: RenderTarget(width: 2, height: 2), options: RenderOptions()) { _ in true }
        }
    }

    @Test(.requiresGPU) func `E-PASS-3 negative control an opaque quad does not blend`() async throws {
        let renderer = try await HarnessGPU.makeRenderer()
        let image = try renderer.render(Self.blendFrame(.opaque), target: RenderTarget(width: 4, height: 4))
        #expect(image[1, 2] == Self.halfRed)
        let mixed = try #require(image[1, 2])
        #expect(!(abs(Int(mixed.b) - 127) <= 1 && mixed.a == 255))
    }

    @Test func `E-PASS-3 all opaque all blended and empty frames are valid`() throws {
        let target = RenderTarget(width: 2, height: 2)
        for blend in Quad.Blend.allCases {
            let frame = FrameDescription(quads: (0..<3).map { _ in Quad(x: 0, y: 0, width: 1, height: 1, color: .red, blend: blend) })
            let plan = try FramePlan(frame: frame, target: target, options: RenderOptions()) { _ in true }
            #expect(plan.draws.count == 3 && plan.draws.allSatisfy { $0.blend == blend })
        }
        #expect(try FramePlan(frame: FrameDescription(), target: target, options: RenderOptions()) { _ in true }.draws.isEmpty)
    }

    @Test func `E-PASS-3 a culled opaque quad after a blended one still throws`() {
        let frame = FrameDescription(quads: [
            Quad(x: 0, y: 0, width: 2, height: 2, color: .red, blend: .premultipliedOver),
            Quad(x: 0, y: 0, width: 0, height: 2, color: .red),
        ])
        #expect(throws: EngineError.opaqueAfterBlended(index: 1)) {
            try FramePlan(frame: frame, target: RenderTarget(width: 2, height: 2), options: RenderOptions()) { _ in true }
        }
        let nonFinite = FrameDescription(quads: [
            Quad(x: 0, y: 0, width: 2, height: 2, color: .red, blend: .premultipliedOver),
            Quad(x: .nan, y: 0, width: 1, height: 1, color: .red),
        ])
        #expect(throws: EngineError.invalidQuad(index: 1)) {
            try FramePlan(frame: nonFinite, target: RenderTarget(width: 2, height: 2), options: RenderOptions()) { _ in true }
        }
    }

    // MARK: E-API-3

    @Test(.requiresGPU) func `E-API-3 the corpus renders with every optional feature forced off`() async throws {
        for (restrictions, _) in Self.layouts {
            let renderer = try await HarnessGPU.makeRenderer(restrictions: restrictions)
            for entry in try SyntheticCorpus.generate() {
                try renderer.setTexture(entry.textureID, image: entry.image)
                let frame = FrameDescription(clearColor: Self.clear, quads: [
                    Quad(x: 0, y: 0, width: Float(entry.image.width), height: Float(entry.image.height), texture: entry.textureID),
                ])
                let image = try renderer.render(frame, target: RenderTarget(width: entry.image.width, height: entry.image.height))
                #expect(try matchesExactly(image, entry.image), "\(entry.name) on \(renderer.capabilities.passLayout)")
            }
        }
    }

    @Test(.requiresGPU) func `E-API-3 the capability probe reports features not families`() async throws {
        let renderer = try await HarnessGPU.makeRenderer()
        #expect(renderer.capabilities == GPUCapabilities(features: .all, maxTextureSide: 16384))
        let floor = try await HarnessGPU.makeRenderer(restrictions: .floor)
        #expect(floor.capabilities == GPUCapabilities(features: [], maxTextureSide: 8192))
        #expect(MetalBackend.maxTextureSide { _ in true } == 16384)
        #expect(MetalBackend.maxTextureSide { _ in false } == 8192)
        #expect(MetalBackend.maxTextureSide { $0 <= 8192 } == 8192)
    }

    @Test func `E-API-3 forcing a feature off that the device lacks changes nothing`() {
        let lacking = GPUCapabilities(features: [], maxTextureSide: 8192)
        #expect(lacking.restricted(by: .floor) == lacking)
        #expect(lacking.restricted(by: .none) == lacking)
        #expect(lacking.restricted(by: .floor).passLayout == .twoPass)
    }

    @Test(.requiresGPU) func `E-API-3 a texture past the probed limit is refused`() async throws {
        let floor = try await HarnessGPU.makeRenderer(restrictions: .floor)
        #expect(throws: EngineError.invalidTargetSize(width: 8193, height: 1)) {
            try floor.render(FrameDescription(), target: RenderTarget(width: 8193, height: 1))
        }
        #expect(throws: EngineError.invalidTargetSize(width: 1, height: 8193)) {
            try floor.render(FrameDescription(), target: RenderTarget(width: 1, height: 8193))
        }
        _ = try floor.render(FrameDescription(), target: RenderTarget(width: 8192, height: 1))
        let wide = try PixelImage(width: 8193, height: 1, filledWith: .red)
        #expect(throws: EngineError.textureTooLarge(width: 8193, height: 1, limit: 8192)) {
            try floor.setTexture("wide", image: wide)
        }
        let tall = try PixelImage(width: 1, height: 8193, filledWith: .red)
        #expect(throws: EngineError.textureTooLarge(width: 1, height: 8193, limit: 8192)) {
            try floor.setTexture("tall", image: tall)
        }
        try floor.setTexture("edge", image: PixelImage(width: 8192, height: 1, filledWith: .red))
        let full = try await HarnessGPU.makeRenderer()
        try full.setTexture("wide", image: wide)
        #expect(throws: EngineError.invalidTargetSize(width: 16385, height: 1)) {
            try full.render(FrameDescription(), target: RenderTarget(width: 16385, height: 1))
        }
    }

    @Test(.requiresGPU) func `E-API-3 the probed limit is 16384 on the Mac`() async throws {
        let renderer = try await HarnessGPU.makeRenderer(restrictions: GPURestrictions(maxTextureSide: 20000))
        #expect(renderer.capabilities.maxTextureSide == 16384)
        let lowered = try await HarnessGPU.makeRenderer(restrictions: GPURestrictions(maxTextureSide: 4096))
        #expect(lowered.capabilities.maxTextureSide == 4096)
        #expect(lowered.capabilities.passLayout == .singlePass)
    }
}
