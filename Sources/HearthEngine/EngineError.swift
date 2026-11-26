/// Every way the engine refuses a request. The engine throws one of these and never crashes (E-HAR-4).
public enum EngineError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No Metal device: a hosted runner, or a caller that passed `nil`.
    case noDevice
    /// A frame names a texture the renderer does not hold and the caller did not ask for a fallback.
    case missingTexture(TextureID)
    /// An asset's header contradicts itself or its payload.
    case malformedAssetHeader(width: Int, height: Int, byteCount: Int)
    /// A pixel format this path cannot produce or read back.
    case unsupportedFormat(PixelFormat)
    /// A render target smaller than 1 or larger than the device's texture limit on a side.
    case invalidTargetSize(width: Int, height: Int)
    /// The quad at this index of the frame has a rectangle that is not finite.
    case invalidQuad(index: Int)
    /// An opaque quad follows a blended one: the ground is drawn first, blended content after (E-PASS-3).
    case opaqueAfterBlended(index: Int)
    /// A texture larger on a side than this device's probed limit (E-API-3).
    case textureTooLarge(width: Int, height: Int, limit: Int)
    /// Metal refused an allocation or a command buffer. The text names what was asked for.
    case gpuFailure(String)

    public var description: String {
        switch self {
        case .noDevice:
            "no Metal device"
        case .missingTexture(let id):
            "missing texture '\(id.name)'"
        case .malformedAssetHeader(let width, let height, let byteCount):
            "malformed asset header: \(width)x\(height) with \(byteCount) bytes"
        case .unsupportedFormat(let format):
            "unsupported format \(format)"
        case .invalidTargetSize(let width, let height):
            "invalid target size \(width)x\(height)"
        case .invalidQuad(let index):
            "quad \(index) has a rectangle that is not finite"
        case .opaqueAfterBlended(let index):
            "quad \(index) is opaque but follows a blended quad"
        case .textureTooLarge(let width, let height, let limit):
            "texture \(width)x\(height) exceeds this device's limit of \(limit)"
        case .gpuFailure(let what):
            "GPU failure: \(what)"
        }
    }
}
