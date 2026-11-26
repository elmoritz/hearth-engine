import Metal

/// Renders a frame headless into an offscreen texture of any size and returns its pixels (E-HAR-1).
///
/// No view, no display link, no clock. One renderer serves any number of frames and targets; a render carries no
/// state into the next one beyond the textures the caller registered. It encodes exactly as the on-screen
/// `FrameLoop` does, into a private target instead of a drawable.
public final class OffscreenRenderer {
    let backend: MetalBackend

    /// The device's name, for receipts.
    public var deviceName: String { backend.deviceName }

    /// What the probe found, after the restrictions this renderer was made with.
    public var capabilities: GPUCapabilities { backend.capabilities }

    /// What the last render did and how many pipelines were ever built.
    public var counters: GPUCounters { backend.counters }

    /// Probes the device and builds every pipeline, off the calling thread, before returning (E-PSO-3).
    ///
    /// Throws `noDevice` for `nil`: a machine without a Metal device is an error the caller can handle, not a
    /// crash. `restrictions` turns optional features off and lowers limits, as the Simulator has them (E-API-3).
    public init(device: MTLDevice?, restrictions: GPURestrictions = .none) async throws(EngineError) {
        guard let device else { throw .noDevice }
        let warmup = try await MetalBackend.warm(device: device, restrictions: restrictions)
        backend = try MetalBackend(device: device, warmup: warmup)
    }

    init(backend: MetalBackend) {
        self.backend = backend
    }

    /// Registers `image` under `id`, replacing what was there. Throws `textureTooLarge` past the device's limit.
    public func setTexture(_ id: TextureID, image: PixelImage) throws(EngineError) {
        try backend.setTexture(id, image: image)
    }

    /// Renders `frame` into a fresh target and reads it back, top row first.
    public func render(
        _ frame: FrameDescription,
        target: RenderTarget,
        options: RenderOptions = RenderOptions()
    ) throws(EngineError) -> PixelImage {
        let backend = self.backend
        let plan = try FramePlan(
            frame: frame, target: target, options: options, maxTextureSide: backend.capabilities.maxTextureSide
        ) { backend.hasTexture($0) }
        return try backend.render(plan, target: target)
    }
}
