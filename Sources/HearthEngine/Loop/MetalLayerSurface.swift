import Metal
import QuartzCore

/// The host's `CAMetalLayer`, configured once for the engine (E-PASS-1, E-LIFE-4).
@MainActor
final class MetalLayerSurface: DrawableLayer {
    /// The drawable format: 8-bit BGRA until the colour pipeline picks the drawable of D1.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    let layer: CAMetalLayer

    init(layer: CAMetalLayer, device: MTLDevice) {
        self.layer = layer
        MetalLayerSurface.configure(layer, device: device)
    }

    /// The layer settings the engine relies on: the drawable is only rendered to (`framebufferOnly`), three drawables
    /// at most, and old contents are never scaled while a resize is pending (`.topLeft` gravity, pitfall 2.18).
    static func configure(_ layer: CAMetalLayer, device: MTLDevice) {
        layer.device = device
        layer.pixelFormat = pixelFormat
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.contentsGravity = .topLeft
        layer.presentsWithTransaction = false
    }

    var drawableSize: CGSize {
        get { layer.drawableSize }
        set { layer.drawableSize = newValue }
    }

    func nextDrawable() -> (any FrameDrawable)? {
        layer.nextDrawable().map(MetalDrawable.init)
    }
}

/// A `CAMetalDrawable` as the loop sees it.
@MainActor
final class MetalDrawable: FrameDrawable {
    let drawable: CAMetalDrawable

    init(_ drawable: CAMetalDrawable) {
        self.drawable = drawable
    }

    var pixelWidth: Int { drawable.texture.width }
    var pixelHeight: Int { drawable.texture.height }
}
