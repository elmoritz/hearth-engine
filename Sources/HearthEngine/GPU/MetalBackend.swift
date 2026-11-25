import Foundation
import Metal

/// The Metal 3-era back end: a private render target, one draw per quad, a blit to a shared buffer.
final class MetalBackend: GPUBackend {
    private struct Pipelines {
        let solid: MTLRenderPipelineState
        let textured: MTLRenderPipelineState
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private let sampler: MTLSamplerState
    private var pipelines: [PixelFormat: Pipelines] = [:]
    private var textures: [TextureID: MTLTexture] = [:]

    var deviceName: String { device.name }

    init(device: MTLDevice) throws(EngineError) {
        self.device = device
        queue = try requireGPU("command queue") { device.makeCommandQueue() }
        library = try requireGPU("shader library") { try device.makeDefaultLibrary(bundle: Bundle.module) }
        let nearest = MTLSamplerDescriptor()
        nearest.minFilter = .nearest
        nearest.magFilter = .nearest
        nearest.sAddressMode = .clampToEdge
        nearest.tAddressMode = .clampToEdge
        sampler = try requireGPU("sampler") { device.makeSamplerState(descriptor: nearest) }
    }

    func hasTexture(_ id: TextureID) -> Bool {
        textures[id] != nil
    }

    func setTexture(_ id: TextureID, image: PixelImage) throws(EngineError) {
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

    func render(_ plan: FramePlan, target: RenderTarget) throws(EngineError) -> PixelImage {
        let device = self.device
        let queue = self.queue
        let pipelines = try pipelines(for: target.format)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: target.format.metal, width: target.width, height: target.height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let texture = try requireGPU("render target") { device.makeTexture(descriptor: descriptor) }
        let commands = try requireGPU("command buffer") { queue.makeCommandBuffer() }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let clear = plan.clearColor
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clear.r) / 255, green: Double(clear.g) / 255, blue: Double(clear.b) / 255,
            alpha: Double(clear.a) / 255)
        let encoder = try requireGPU("render encoder") { commands.makeRenderCommandEncoder(descriptor: pass) }
        if !plan.draws.isEmpty {
            let vertices = try requireGPU("vertex buffer") {
                plan.vertices.withUnsafeBytes { raw in
                    raw.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
                }
            }
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            var targetSize = SIMD2<Float>(Float(target.width), Float(target.height))
            encoder.setVertexBytes(&targetSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
            for draw in plan.draws {
                switch draw.source {
                case .color(let color):
                    var value = SIMD4<Float>(Float(color.r), Float(color.g), Float(color.b), Float(color.a)) / 255
                    encoder.setRenderPipelineState(pipelines.solid)
                    encoder.setFragmentBytes(&value, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                case .texture(let id):
                    encoder.setRenderPipelineState(pipelines.textured)
                    encoder.setFragmentTexture(textures[id], index: 0)
                }
                encoder.drawPrimitives(
                    type: .triangle, vertexStart: draw.firstVertex, vertexCount: FramePlan.verticesPerQuad)
            }
        }
        encoder.endEncoding()

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

    private func pipelines(for format: PixelFormat) throws(EngineError) -> Pipelines {
        if let made = pipelines[format] {
            return made
        }
        let device = self.device
        let library = self.library
        let layout = MTLVertexDescriptor()
        layout.attributes[0].format = .float2
        layout.attributes[0].offset = 0
        layout.attributes[0].bufferIndex = 0
        layout.attributes[1].format = .float2
        layout.attributes[1].offset = MemoryLayout<Float>.stride * 2
        layout.attributes[1].bufferIndex = 0
        layout.layouts[0].stride = MemoryLayout<Float>.stride * FramePlan.floatsPerVertex

        func pipeline(_ fragment: String) throws(EngineError) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = try requireGPU("quad_vertex") { library.makeFunction(name: "quad_vertex") }
            descriptor.fragmentFunction = try requireGPU(fragment) { library.makeFunction(name: fragment) }
            descriptor.vertexDescriptor = layout
            descriptor.colorAttachments[0].pixelFormat = format.metal
            return try requireGPU("pipeline \(fragment)") { try device.makeRenderPipelineState(descriptor: descriptor) }
        }
        let made = Pipelines(
            solid: try pipeline("quad_solid_fragment"), textured: try pipeline("quad_textured_fragment"))
        pipelines[format] = made
        return made
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
