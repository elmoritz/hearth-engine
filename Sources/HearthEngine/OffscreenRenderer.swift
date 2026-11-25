import Metal

/// Renders a frame headless into an offscreen texture of any size and returns its pixels (E-HAR-1).
///
/// No view, no display link, no clock. One renderer serves any number of frames and targets; a render carries no
/// state into the next one beyond the textures the caller registered.
public final class OffscreenRenderer {
    private let backend: any GPUBackend

    /// The device's name, for receipts.
    public var deviceName: String { backend.deviceName }

    /// Throws `noDevice` for `nil`: a machine without a Metal device is an error the caller can handle, not a crash.
    public init(device: MTLDevice?) throws(EngineError) {
        guard let device else { throw .noDevice }
        backend = try MetalBackend(device: device)
    }

    /// Registers `image` under `id`, replacing what was there. HE-2 replaces this upload with the container loader.
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
        let plan = try FramePlan(frame: frame, target: target, options: options) { backend.hasTexture($0) }
        return try backend.render(plan, target: target)
    }
}
