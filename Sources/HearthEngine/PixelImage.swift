/// One 8-bit RGBA value, exactly as stored. HE-1 attaches no colour space and no premultiplication to it.
public struct RGBA8: Sendable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let clear = RGBA8(0, 0, 0, 0)
    public static let black = RGBA8(0, 0, 0)
    public static let white = RGBA8(255, 255, 255)
    public static let red = RGBA8(255, 0, 0)
    public static let green = RGBA8(0, 255, 0)
    public static let blue = RGBA8(0, 0, 255)
    public static let magenta = RGBA8(255, 0, 255)
}

/// Pixel formats the engine names. Which of them a path supports is that path's business.
public enum PixelFormat: Sendable, Hashable, CaseIterable {
    case rgba8Unorm
    case bgra8Unorm
    /// Named for the scene attachment of D1 and D18. Not renderable through the 8-bit readback of HE-1.
    case rgba16Float

    /// Whether a target of this format reads back into a `PixelImage` without conversion loss.
    public var isEightBit: Bool {
        switch self {
        case .rgba8Unorm, .bgra8Unorm: true
        case .rgba16Float: false
        }
    }
}

/// An image in memory: RGBA8, row-major, top row first. The header is `width` and `height`; the payload must match it.
public struct PixelImage: Sendable, Hashable {
    /// The largest side of any image or render target (the Apple5 texture limit, E-API-3).
    public static let maximumDimension = 16384

    public let width: Int
    public let height: Int
    public private(set) var bytes: [UInt8]

    /// Throws `malformedAssetHeader` when a side is outside `1...maximumDimension` or the payload is not
    /// `width * height * 4` bytes.
    public init(width: Int, height: Int, bytes: [UInt8]) throws(EngineError) {
        let sides = 1...PixelImage.maximumDimension
        guard sides.contains(width), sides.contains(height), bytes.count == width * height * 4 else {
            throw .malformedAssetHeader(width: width, height: height, byteCount: bytes.count)
        }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public init(width: Int, height: Int, filledWith color: RGBA8) throws(EngineError) {
        let sides = 1...PixelImage.maximumDimension
        guard sides.contains(width), sides.contains(height) else {
            throw .malformedAssetHeader(width: width, height: height, byteCount: 0)
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes[offset] = color.r
            bytes[offset + 1] = color.g
            bytes[offset + 2] = color.b
            bytes[offset + 3] = color.a
        }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    public var pixelCount: Int { width * height }

    /// The pixel at (`x`, `y`), or `nil` outside the image.
    public subscript(x: Int, y: Int) -> RGBA8? {
        guard contains(x: x, y: y) else { return nil }
        let offset = (y * width + x) * 4
        return RGBA8(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    /// Writes one pixel. A position outside the image is ignored and reported as `false`.
    @discardableResult
    public mutating func set(x: Int, y: Int, to color: RGBA8) -> Bool {
        guard contains(x: x, y: y) else { return false }
        let offset = (y * width + x) * 4
        bytes[offset] = color.r
        bytes[offset + 1] = color.g
        bytes[offset + 2] = color.b
        bytes[offset + 3] = color.a
        return true
    }

    private func contains(x: Int, y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height
    }
}
