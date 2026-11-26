import Foundation
import Metal
import QuartzCore

/// The on-screen half of the Metal back end: plans a frame, encodes it into the drawable with the same encoder as
/// the offscreen path, presents and commits. Vertices go through a ring of three buffers, one per frame in flight;
/// nothing waits for the GPU (`research/performance-and-power.md` 2).
@MainActor
final class MetalFrameSubmitter: FrameSubmitter {
    let backend: MetalBackend
    let options: RenderOptions
    var onCompletion: ((SubmissionID, CommandBufferOutcome) -> Void)?

    private let queue: MTLCommandQueue
    private var ring: [MTLBuffer?] = Array(repeating: nil, count: FrameLoop.maximumInFlight)
    private var next = 0
    private var buffers: [SubmissionID: MTLCommandBuffer] = [:]

    var maxTextureSide: Int { backend.capabilities.maxTextureSide }

    init(backend: MetalBackend, options: RenderOptions) throws(EngineError) {
        self.backend = backend
        self.options = options
        let device = backend.device
        queue = try requireGPU("command queue") { device.makeCommandQueue() }
    }

    func submit(_ frame: FrameDescription, to drawable: any FrameDrawable, presentAfter: Double?) throws(EngineError) -> SubmissionID {
        guard let metal = drawable as? MetalDrawable else {
            throw .gpuFailure("drawable: not a CAMetalDrawable")
        }
        let texture = metal.drawable.texture
        let target = RenderTarget(width: texture.width, height: texture.height, format: .bgra8Unorm)
        let backend = self.backend
        let plan = try FramePlan(frame: frame, target: target, options: options, maxTextureSide: maxTextureSide) {
            backend.hasTexture($0)
        }
        let slot = next % ring.count
        let vertices = try vertexBuffer(for: plan, slot: slot)
        let queue = self.queue
        let commands = try requireGPU("command buffer") { queue.makeCommandBuffer() }
        try backend.encode(plan, into: texture, format: .bgra8Unorm, commands: commands, vertices: vertices)
        if let presentAfter {
            commands.present(metal.drawable, afterMinimumDuration: presentAfter)
        } else {
            commands.present(metal.drawable)
        }
        let id = SubmissionID(value: next)
        next += 1
        commands.addCompletedHandler { [weak self] buffer in
            let outcome = CommandBufferOutcome(status: buffer.status, error: buffer.error)
            Task { @MainActor in self?.finished(id, outcome) }
        }
        buffers[id] = commands
        commands.commit()
        return id
    }

    func waitUntilScheduled(_ id: SubmissionID) {
        buffers[id]?.waitUntilScheduled()
    }

    private func finished(_ id: SubmissionID, _ outcome: CommandBufferOutcome) {
        buffers[id] = nil
        onCompletion?(id, outcome)
    }

    /// The ring slot's buffer, grown when the plan needs more, filled with the plan's vertices.
    private func vertexBuffer(for plan: FramePlan, slot: Int) throws(EngineError) -> MTLBuffer? {
        guard !plan.vertices.isEmpty else { return nil }
        let length = plan.vertices.count * MemoryLayout<Float>.stride
        if (ring[slot]?.length ?? 0) < length {
            let device = backend.device
            ring[slot] = try requireGPU("vertex buffer") { device.makeBuffer(length: length, options: .storageModeShared) }
        }
        let buffer = ring[slot]
        plan.vertices.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let contents = buffer?.contents() {
                contents.copyMemory(from: base, byteCount: raw.count)
            }
        }
        return buffer
    }
}

extension CommandBufferOutcome {
    /// How a command buffer ended, from its status and error. Never traps (E-LIFE-2).
    init(status: MTLCommandBufferStatus, error: (any Error)?) {
        guard status == .error || error != nil else {
            self = .completed
            return
        }
        let code = (error as NSError?)?.code ?? -1
        switch MTLCommandBufferError.Code(rawValue: UInt(bitPattern: code)) {
        case .notPermitted: self = .failed(.notPermitted)
        case .accessRevoked: self = .failed(.accessRevoked)
        default: self = .failed(.other(code: code))
        }
    }
}
