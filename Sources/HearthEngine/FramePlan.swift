/// A validated frame, ready for any GPU back end: what to clear with, the vertices and one draw per visible quad,
/// opaque draws first.
///
/// Building a plan is pure, so every refusal (target size, format, a quad that is not finite, a missing texture)
/// is decided on the CPU, before a Metal call exists that validation could object to.
struct FramePlan: Equatable {
    enum Source: Equatable {
        case color(RGBA8)
        case texture(TextureID)
    }

    struct Draw: Equatable {
        /// Index of the first of this quad's six vertices.
        var firstVertex: Int
        var source: Source
        var blend: Quad.Blend
    }

    /// Floats per vertex: position x, y in target pixels, then texture u, v.
    static let floatsPerVertex = 4
    static let verticesPerQuad = 6

    var clearColor: RGBA8
    var vertices: [Float] = []
    var draws: [Draw] = []

    init(
        frame: FrameDescription,
        target: RenderTarget,
        options: RenderOptions,
        maxTextureSide: Int = PixelImage.maximumDimension,
        hasTexture: (TextureID) -> Bool
    ) throws(EngineError) {
        let sides = 1...Swift.min(maxTextureSide, PixelImage.maximumDimension)
        guard sides.contains(target.width), sides.contains(target.height) else {
            throw .invalidTargetSize(width: target.width, height: target.height)
        }
        guard target.format.isEightBit else {
            throw .unsupportedFormat(target.format)
        }
        clearColor = frame.clearColor
        var blended = false
        for (index, quad) in frame.quads.enumerated() {
            let left = quad.rect.x
            let top = quad.rect.y
            let right = left + quad.rect.width
            let bottom = top + quad.rect.height
            guard left.isFinite, top.isFinite, right.isFinite, bottom.isFinite else {
                throw .invalidQuad(index: index)
            }
            // The order rule is on the description, not on what is visible: a culled quad breaks it too.
            if quad.blend == .opaque && blended {
                throw .opaqueAfterBlended(index: index)
            }
            blended = blended || quad.blend != .opaque
            guard quad.rect.width > 0, quad.rect.height > 0 else { continue }
            let source: Source
            switch quad.fill {
            case .color(let color):
                source = .color(color)
            case .texture(let id):
                if hasTexture(id) {
                    source = .texture(id)
                } else if options.missingTexture == .fallback {
                    source = .color(RenderOptions.fallbackColor)
                } else {
                    throw .missingTexture(id)
                }
            }
            draws.append(Draw(firstVertex: vertices.count / FramePlan.floatsPerVertex, source: source, blend: quad.blend))
            vertices += [
                left, top, 0, 0,
                right, top, 1, 0,
                left, bottom, 0, 1,
                right, top, 1, 0,
                right, bottom, 1, 1,
                left, bottom, 0, 1,
            ]
        }
    }
}
