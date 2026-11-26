import Foundation
import Metal

/// Which shader functions a pipeline key uses. Injectable so a test can make one build fail (E-PSO-3) or the probe
/// refuse (E-PASS-2); the engine always uses `PipelineKey.functions`.
typealias FunctionTable = @Sendable (PipelineKey) -> (vertex: String, fragment: String)

/// One pipeline built by the warm-up, and whether it was built on the main thread (E-PSO-3: never).
struct PipelineBuild: Sendable, Hashable {
    var key: PipelineKey
    var onMainThread: Bool
}

/// What the warm-up produced: the probe's answer and every pipeline the renderer will ever use.
struct PipelineWarmup: Sendable {
    let library: MTLLibrary
    let capabilities: GPUCapabilities
    let pipelines: [PipelineKey: MTLRenderPipelineState]
    let builds: [PipelineBuild]
}

/// The Metal 3-era back end. Pipelines are built once, asynchronously and off the main thread, before the first
/// frame (E-PSO-3); after that the set is frozen and a key outside it is an error, never a build (E-PSO-1). One
/// encoder serves the offscreen target the harness reads back and the drawable on screen, so the golden tests
/// prove the encode the screen gets.
final class MetalBackend: GPUBackend {
    let device: MTLDevice
    let capabilities: GPUCapabilities
    let builds: [PipelineBuild]
    private(set) var counters = GPUCounters()
    /// Test hook for the coverage negative control (E-PASS-2): leave the final stage out, so the target keeps
    /// whatever its don't-care load gave it.
    var skipsFinalStage = false

    private let queue: MTLCommandQueue
    private let sampler: MTLSamplerState
    private let pipelines: [PipelineKey: MTLRenderPipelineState]
    private var textures: [TextureID: MTLTexture] = [:]
    private var sceneTexture: MTLTexture?

    var deviceName: String { device.name }
    var passLayout: PassLayout { capabilities.passLayout }
    var pipelineKeys: Set<PipelineKey> { Set(pipelines.keys) }

    init(device: MTLDevice, warmup: PipelineWarmup) throws(EngineError) {
        self.device = device
        capabilities = warmup.capabilities
        pipelines = warmup.pipelines
        builds = warmup.builds
        counters.pipelinesCreated = warmup.builds.count
        counters.pipelinesCreatedOnMainThread = warmup.builds.filter(\.onMainThread).count
        queue = try requireGPU("command queue") { device.makeCommandQueue() }
        let nearest = MTLSamplerDescriptor()
        nearest.minFilter = .nearest
        nearest.magFilter = .nearest
        nearest.sAddressMode = .clampToEdge
        nearest.tAddressMode = .clampToEdge
        sampler = try requireGPU("sampler") { device.makeSamplerState(descriptor: nearest) }
    }

    /// Probes the device and builds every pipeline of its pass layout, concurrently, off the caller's thread.
    @concurrent
    static func warm(
        device: MTLDevice,
        restrictions: GPURestrictions,
        functions: @escaping FunctionTable = { $0.functions }
    ) async throws(EngineError) -> PipelineWarmup {
        let library = try requireGPU("shader library") { try device.makeDefaultLibrary(bundle: Bundle.module) }
        let side = maxTextureSide { side in
            let probe = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: 1, mipmapped: false)
            probe.storageMode = .private
            return device.makeTexture(descriptor: probe) != nil
        }
        var pipelines = [PipelineKey: MTLRenderPipelineState]()
        var builds = [PipelineBuild]()
        var features: GPUFeatures = []
        if !restrictions.disabled.contains(.readsRenderTargetInPass) {
            // The probe is the single pass's own final stage: it builds exactly where reading the target works.
            let probe = PipelineKey.final(layout: .singlePass, targetFormat: .bgra8Unorm)
            if let (state, onMain) = try? await build(probe, device: device, library: library, functions: functions) {
                features.insert(.readsRenderTargetInPass)
                pipelines[probe] = state
                builds.append(PipelineBuild(key: probe, onMainThread: onMain))
            }
        }
        let capabilities = GPUCapabilities(features: features, maxTextureSide: side).restricted(by: restrictions)
        let keys = PipelineKey.precompiled(layout: capabilities.passLayout).filter { pipelines[$0] == nil }
        do {
            try await withThrowingTaskGroup(of: (PipelineKey, MTLRenderPipelineState, Bool).self) { group in
                for key in keys {
                    group.addTask {
                        let (state, onMain) = try await build(key, device: device, library: library, functions: functions)
                        return (key, state, onMain)
                    }
                }
                for try await (key, state, onMain) in group {
                    pipelines[key] = state
                    builds.append(PipelineBuild(key: key, onMainThread: onMain))
                }
            }
        } catch let error as EngineError {
            throw error
        } catch {
            // cov:allow - build throws only EngineError; the group adds no error of its own
            throw .gpuFailure("pipeline warm-up: \(error)")
        }
        return PipelineWarmup(library: library, capabilities: capabilities, pipelines: pipelines, builds: builds)
    }

    /// The largest texture side: 16384 where a 16384-wide texture can be made, the Simulator's 8192 otherwise.
    static func maxTextureSide(allocates: (Int) -> Bool) -> Int {
        allocates(PixelImage.maximumDimension) ? PixelImage.maximumDimension : 8192
    }

    @concurrent
    private static func build(
        _ key: PipelineKey, device: MTLDevice, library: MTLLibrary, functions: FunctionTable
    ) async throws(EngineError) -> (MTLRenderPipelineState, Bool) {
        let onMainThread = pthread_main_np() != 0
        let descriptor = try describe(key, library: library, functions: functions)
        do {
            return (try await device.makeRenderPipelineState(descriptor: descriptor), onMainThread)
        } catch {
            throw .gpuFailure("pipeline \(key): \(error)")
        }
    }

    /// The pipeline descriptor of a key: functions, vertex layout, and each attachment's format, write mask and blend.
    static func describe(
        _ key: PipelineKey, library: MTLLibrary, functions: FunctionTable = { $0.functions }
    ) throws(EngineError) -> MTLRenderPipelineDescriptor {
        let names = functions(key)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = key.description
        descriptor.vertexFunction = try requireGPU(names.vertex) { library.makeFunction(name: names.vertex) }
        descriptor.fragmentFunction = try requireGPU(names.fragment) { library.makeFunction(name: names.fragment) }
        if key.stage != .final {
            let layout = MTLVertexDescriptor()
            layout.attributes[0].format = .float2
            layout.attributes[0].offset = 0
            layout.attributes[0].bufferIndex = 0
            layout.attributes[1].format = .float2
            layout.attributes[1].offset = MemoryLayout<Float>.stride * 2
            layout.attributes[1].bufferIndex = 0
            layout.layouts[0].stride = MemoryLayout<Float>.stride * FramePlan.floatsPerVertex
            descriptor.vertexDescriptor = layout
        }
        for (index, attachment) in key.attachments.enumerated() {
            let color = descriptor.colorAttachments[index]
            color?.pixelFormat = attachment.format.metal
            color?.writeMask = attachment.writes ? .all : []
            if attachment.blend == .premultipliedOver {
                color?.isBlendingEnabled = true
                color?.rgbBlendOperation = .add
                color?.alphaBlendOperation = .add
                color?.sourceRGBBlendFactor = .one
                color?.sourceAlphaBlendFactor = .one
                color?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        }
        return descriptor
    }

    func hasTexture(_ id: TextureID) -> Bool {
        textures[id] != nil
    }

    func setTexture(_ id: TextureID, image: PixelImage) throws(EngineError) {
        let limit = capabilities.maxTextureSide
        guard image.width <= limit, image.height <= limit else {
            throw .textureTooLarge(width: image.width, height: image.height, limit: limit)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: image.width, height: image.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let device = self.device
        let texture = try requireGPU("texture '\(id.name)'") { device.makeTexture(descriptor: descriptor) }
        image.bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: image.width * 4)
            }
        }
        textures[id] = texture
    }

    /// A shared buffer holding the plan's vertices, or nil for a plan with none.
    func vertexBuffer(for plan: FramePlan) throws(EngineError) -> MTLBuffer? {
        guard !plan.vertices.isEmpty else { return nil }
        let device = self.device
        return try requireGPU("vertex buffer") {
            plan.vertices.withUnsafeBytes { raw in
                raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
            }
        }
    }

    func render(_ plan: FramePlan, target: RenderTarget) throws(EngineError) -> PixelImage {
        let device = self.device
        let queue = self.queue
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: target.format.metal, width: target.width, height: target.height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let texture = try requireGPU("render target") { device.makeTexture(descriptor: descriptor) }
        let commands = try requireGPU("command buffer") { queue.makeCommandBuffer() }
        try encode(plan, into: texture, format: target.format, commands: commands, vertices: vertexBuffer(for: plan))

        let rowBytes = target.width * 4
        let byteCount = rowBytes * target.height
        let readback = try requireGPU("readback buffer") {
            device.makeBuffer(length: byteCount, options: .storageModeShared)
        }
        let blit = try requireGPU("blit encoder") { commands.makeBlitCommandEncoder() }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: target.width, height: target.height, depth: 1),
            to: readback, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: byteCount)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else {
            // cov:allow - a committed command buffer cannot be made to fail from a test
            throw .gpuFailure("command buffer: \(commands.error.map { "\($0)" } ?? "not completed")")
        }

        var bytes = [UInt8](UnsafeRawBufferPointer(start: readback.contents(), count: byteCount))
        if target.format == .bgra8Unorm {
            for offset in stride(from: 0, to: byteCount, by: 4) {
                bytes.swapAt(offset, offset + 2)
            }
        }
        return try PixelImage(width: target.width, height: target.height, bytes: bytes)
    }

    /// Encodes one frame into `target` (an offscreen texture or a drawable's), in this device's pass layout.
    func encode(
        _ plan: FramePlan, into target: MTLTexture, format: PixelFormat, commands: MTLCommandBuffer,
        vertices: MTLBuffer?, vertexOffset: Int = 0
    ) throws(EngineError) {
        var frame = counters
        frame.renderPasses = 0
        frame.draws = 0
        frame.pipelineBinds = 0
        let layout = passLayout
        let scene = try sceneTexture(width: target.width, height: target.height, layout: layout)
        let passes = layout.passes
        let size = SIMD2<Float>(Float(target.width), Float(target.height))

        let first = MetalBackend.renderPass(passes[0], target: target, scene: scene, clear: plan.clearColor)
        let encoder = try requireGPU("render encoder") { commands.makeRenderCommandEncoder(descriptor: first) }
        frame.renderPasses += 1
        var bound: MTLRenderPipelineState?
        func bind(_ key: PipelineKey, on encoder: MTLRenderCommandEncoder) throws(EngineError) {
            let state = try pipeline(key)
            if state !== bound {
                encoder.setRenderPipelineState(state)
                bound = state
                frame.pipelineBinds += 1
            }
        }
        if let vertices, !plan.draws.isEmpty {
            encoder.setVertexBuffer(vertices, offset: vertexOffset, index: 0)
            var targetSize = size
            encoder.setVertexBytes(&targetSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
            for draw in plan.draws {
                try bind(.scene(draw.source, blend: draw.blend, layout: layout, targetFormat: format), on: encoder)
                switch draw.source {
                case .color(let color):
                    var value = SIMD4<Float>(Float(color.r), Float(color.g), Float(color.b), Float(color.a)) / 255
                    encoder.setFragmentBytes(&value, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                case .texture(let id):
                    encoder.setFragmentTexture(textures[id], index: 0)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: draw.firstVertex, vertexCount: FramePlan.verticesPerQuad)
                frame.draws += 1
            }
        }
        var finalEncoder = encoder
        if layout == .twoPass {
            encoder.endEncoding()
            let second = MetalBackend.renderPass(passes[1], target: target, scene: scene, clear: plan.clearColor)
            finalEncoder = try requireGPU("render encoder") { commands.makeRenderCommandEncoder(descriptor: second) }
            frame.renderPasses += 1
            bound = nil
            finalEncoder.setFragmentTexture(scene, index: 0)
        }
        if !skipsFinalStage {
            try bind(.final(layout: layout, targetFormat: format), on: finalEncoder)
            finalEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            frame.draws += 1
        }
        finalEncoder.endEncoding()
        counters = frame
    }

    /// The pipeline the warm-up built for `key`. The set is frozen: anything else is an error, never a build.
    func pipeline(_ key: PipelineKey) throws(EngineError) -> MTLRenderPipelineState {
        guard let state = pipelines[key] else {
            throw .gpuFailure("pipeline \(key) was not built at warm-up")
        }
        return state
    }

    /// The scene attachment for a target of this size: memoryless in the single pass, a stored private texture the
    /// final stage samples in the two-pass fallback. Kept while the size holds.
    private func sceneTexture(width: Int, height: Int, layout: PassLayout) throws(EngineError) -> MTLTexture {
        if let sceneTexture, sceneTexture.width == width, sceneTexture.height == height {
            return sceneTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: PassLayout.sceneFormat.metal, width: width, height: height, mipmapped: false)
        switch layout {
        case .singlePass:
            descriptor.usage = .renderTarget
            descriptor.storageMode = .memoryless
        case .twoPass:
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
        }
        let device = self.device
        let made = try requireGPU("scene attachment") { device.makeTexture(descriptor: descriptor) }
        sceneTexture = made
        return made
    }

    /// A render pass descriptor from its description: the target or scene texture at each index, and the
    /// description's load and store actions (E-PASS-1).
    static func renderPass(_ pass: PassDescription, target: MTLTexture?, scene: MTLTexture?, clear: RGBA8) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        for (index, attachment) in pass.attachments.enumerated() {
            let color = descriptor.colorAttachments[index]
            color?.texture = attachment.role == .target ? target : scene
            color?.loadAction = attachment.load == .clear ? .clear : .dontCare
            color?.storeAction = attachment.store == .store ? .store : .dontCare
            color?.clearColor = MTLClearColor(
                red: Double(clear.r) / 255, green: Double(clear.g) / 255, blue: Double(clear.b) / 255,
                alpha: Double(clear.a) / 255)
        }
        return descriptor
    }
}

extension PixelFormat {
    var metal: MTLPixelFormat {
        switch self {
        case .rgba8Unorm: .rgba8Unorm
        case .bgra8Unorm: .bgra8Unorm
        case .rgba16Float: .rgba16Float
        }
    }
}
