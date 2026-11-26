/// Everything that distinguishes one render pipeline from another (E-PSO-2).
///
/// The set a renderer can ever ask for is `precompiled(layout:targetFormats:)`, a pure function: the warm-up builds
/// exactly that set at init and the encoder only looks keys up, so no pipeline is built after warm-up (E-PSO-1).
struct PipelineKey: Sendable, Hashable, CustomStringConvertible {
    enum Stage: Sendable, Hashable, CaseIterable {
        case solid
        case textured
        /// The full-screen stage that turns the scene into the target's pixels.
        case final
    }

    /// One colour attachment of the pipeline: its format, whether the pipeline writes it, and how.
    struct Attachment: Sendable, Hashable {
        var format: PixelFormat
        var writes: Bool
        var blend: Quad.Blend
    }

    var stage: Stage
    var blend: Quad.Blend
    var layout: PassLayout
    /// The target's format. Two-pass scene stages draw into the scene texture and do not depend on it (nil).
    var targetFormat: PixelFormat?

    /// The formats a target can have: the drawable's `bgra8Unorm` and the harness's `rgba8Unorm`.
    static let targetFormats: [PixelFormat] = [.rgba8Unorm, .bgra8Unorm]

    static func scene(_ source: FramePlan.Source, blend: Quad.Blend, layout: PassLayout, targetFormat: PixelFormat) -> PipelineKey {
        let stage: Stage
        switch source {
        case .color: stage = .solid
        case .texture: stage = .textured
        }
        return PipelineKey(stage: stage, blend: blend, layout: layout, targetFormat: layout == .singlePass ? targetFormat : nil)
    }

    static func final(layout: PassLayout, targetFormat: PixelFormat) -> PipelineKey {
        PipelineKey(stage: .final, blend: .opaque, layout: layout, targetFormat: targetFormat)
    }

    /// Every pipeline a renderer with this layout and these target formats can use, each once.
    static func precompiled(layout: PassLayout, targetFormats: [PixelFormat] = targetFormats) -> [PipelineKey] {
        var keys = [PipelineKey]()
        func add(_ key: PipelineKey) {
            if !keys.contains(key) { keys.append(key) }
        }
        for format in targetFormats {
            for source in [FramePlan.Source.color(.clear), .texture("")] {
                for blend in Quad.Blend.allCases {
                    add(scene(source, blend: blend, layout: layout, targetFormat: format))
                }
            }
            add(final(layout: layout, targetFormat: format))
        }
        return keys
    }

    /// The colour attachments by index. In the single pass, scene stages never write the target (attachment 0) and
    /// the final stage never writes the scene (attachment 1): the target's load action is don't-care, so only the
    /// final stage, covering every pixel, may define it.
    var attachments: [Attachment] {
        let scene = PassLayout.sceneFormat
        switch (layout, stage) {
        case (.singlePass, .final):
            return [Attachment(format: targetFormat ?? .bgra8Unorm, writes: true, blend: .opaque),
                    Attachment(format: scene, writes: false, blend: .opaque)]
        case (.singlePass, _):
            return [Attachment(format: targetFormat ?? .bgra8Unorm, writes: false, blend: .opaque),
                    Attachment(format: scene, writes: true, blend: blend)]
        case (.twoPass, .final):
            return [Attachment(format: targetFormat ?? .bgra8Unorm, writes: true, blend: .opaque)]
        case (.twoPass, _):
            return [Attachment(format: scene, writes: true, blend: blend)]
        }
    }

    /// The shader functions, by name in the target's metallib.
    var functions: (vertex: String, fragment: String) {
        switch (layout, stage) {
        case (.singlePass, .solid): ("quad_vertex", "quad_solid_scene_fragment")
        case (.singlePass, .textured): ("quad_vertex", "quad_textured_scene_fragment")
        case (.singlePass, .final): ("final_vertex", "final_fetch_fragment")
        case (.twoPass, .solid): ("quad_vertex", "quad_solid_fragment")
        case (.twoPass, .textured): ("quad_vertex", "quad_textured_fragment")
        case (.twoPass, .final): ("final_vertex", "final_sample_fragment")
        }
    }

    var description: String {
        "\(stage)/\(blend)/\(layout)/\(targetFormat.map { "\($0)" } ?? "scene")"
    }
}
