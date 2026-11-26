/// The name a frame uses for a texture held by the renderer.
public struct TextureID: Sendable, Hashable, ExpressibleByStringLiteral {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public init(stringLiteral value: String) {
        self.name = value
    }
}

/// A rectangle in target pixels: origin at the top-left corner of the target, y down.
public struct PixelRect: Sendable, Hashable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// An axis-aligned rectangle filled with a colour or with a whole texture.
///
/// Values are written verbatim (no colour space: Decisions D1 is open and the colour pipeline owns it). A pixel
/// is covered when its centre lies inside the rectangle. A quad whose width or height is not positive covers
/// nothing. `blend` says how it meets what is under it (E-PASS-3).
public struct Quad: Sendable, Hashable {
    public enum Fill: Sendable, Hashable {
        case color(RGBA8)
        /// The whole texture, stretched over the rectangle with nearest sampling.
        case texture(TextureID)
    }

    /// How a quad is written. Opaque quads come first in a frame (the ground), blended ones after.
    public enum Blend: Sendable, Hashable, CaseIterable {
        /// Blending off: the quad's values replace what is there. The default.
        case opaque
        /// Premultiplied source over: `source + destination * (1 - source alpha)`.
        case premultipliedOver
    }

    public var rect: PixelRect
    public var fill: Fill
    public var blend: Blend

    public init(rect: PixelRect, fill: Fill, blend: Blend = .opaque) {
        self.rect = rect
        self.fill = fill
        self.blend = blend
    }

    public init(x: Float, y: Float, width: Float, height: Float, color: RGBA8, blend: Blend = .opaque) {
        self.init(rect: PixelRect(x: x, y: y, width: width, height: height), fill: .color(color), blend: blend)
    }

    public init(x: Float, y: Float, width: Float, height: Float, texture: TextureID, blend: Blend = .opaque) {
        self.init(rect: PixelRect(x: x, y: y, width: width, height: height), fill: .texture(texture), blend: blend)
    }
}

/// Everything one frame draws: an immutable value with no closures and no GPU objects (invariant 2), so it can
/// cross threads and be serialised (E-API-2). Quads are drawn in order: every opaque quad before every blended one
/// (E-PASS-3); a later opaque quad overwrites an earlier one.
public struct FrameDescription: Sendable, Hashable {
    public var clearColor: RGBA8
    public var quads: [Quad]

    public init(clearColor: RGBA8 = .clear, quads: [Quad] = []) {
        self.clearColor = clearColor
        self.quads = quads
    }
}

/// The offscreen texture a frame is rendered into.
public struct RenderTarget: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var format: PixelFormat

    public init(width: Int, height: Int, format: PixelFormat = .rgba8Unorm) {
        self.width = width
        self.height = height
        self.format = format
    }
}

/// What the caller asks for beyond the frame itself.
public struct RenderOptions: Sendable, Hashable {
    public enum MissingTexture: Sendable, Hashable {
        /// Throw `EngineError.missingTexture`. The default: a fallback is drawn only when the caller asks (E-HAR-4).
        case throwError
        /// Draw the quad in `RenderOptions.fallbackColor` instead.
        case fallback
    }

    /// The colour of a quad whose texture is missing, when the caller asked for the fallback.
    public static let fallbackColor = RGBA8.magenta

    public var missingTexture: MissingTexture

    public init(missingTexture: MissingTexture = .throwError) {
        self.missingTexture = missingTexture
    }
}
