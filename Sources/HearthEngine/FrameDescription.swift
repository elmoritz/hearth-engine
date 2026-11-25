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

/// The one drawable of HE-1: an axis-aligned rectangle filled with a colour or with a whole texture.
///
/// Values are written verbatim and unblended (no colour space, no premultiplication: Decisions D1 is open and
/// the colour pipeline owns both). A pixel is covered when its centre lies inside the rectangle. A quad whose
/// width or height is not positive covers nothing.
public struct Quad: Sendable, Hashable {
    public enum Fill: Sendable, Hashable {
        case color(RGBA8)
        /// The whole texture, stretched over the rectangle with nearest sampling.
        case texture(TextureID)
    }

    public var rect: PixelRect
    public var fill: Fill

    public init(rect: PixelRect, fill: Fill) {
        self.rect = rect
        self.fill = fill
    }

    public init(x: Float, y: Float, width: Float, height: Float, color: RGBA8) {
        self.init(rect: PixelRect(x: x, y: y, width: width, height: height), fill: .color(color))
    }

    public init(x: Float, y: Float, width: Float, height: Float, texture: TextureID) {
        self.init(rect: PixelRect(x: x, y: y, width: width, height: height), fill: .texture(texture))
    }
}

/// Everything one frame draws: an immutable value with no closures and no GPU objects (invariant 2), so it can
/// cross threads and be serialised. Quads are drawn in order; a later quad overwrites an earlier one.
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
