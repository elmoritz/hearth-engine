import Foundation
import HearthEngine

/// A named scene: the textures it needs and its frame as a function of an injected time.
///
/// One catalogue of these feeds the tests today and the viewer, the Previews and the benchmark app later (D19).
public struct HarnessScene: Sendable {
    public let name: String
    public let target: RenderTarget
    public let textures: [CorpusEntry]
    public let frame: @Sendable (EngineTime) -> FrameDescription

    public init(
        name: String, target: RenderTarget, textures: [CorpusEntry],
        frame: @escaping @Sendable (EngineTime) -> FrameDescription
    ) {
        self.name = name
        self.target = target
        self.textures = textures
        self.frame = frame
    }

    /// Registers the scene's textures with `renderer`. Once per renderer is enough.
    public func load(into renderer: OffscreenRenderer) throws(EngineError) {
        for entry in textures {
            try renderer.setTexture(entry.textureID, image: entry.image)
        }
    }

    public func render(at time: EngineTime, with renderer: OffscreenRenderer) throws(EngineError) -> PixelImage {
        try renderer.render(frame(time), target: target)
    }

    /// Every scene, registered once.
    public static func catalogue() throws(EngineError) -> [HarnessScene] {
        [try postcard(), bars]
    }

    /// The smoke-test scene: every part of the synthetic corpus plus three quads driven by time. It grows with
    /// each subsystem the engine gains.
    public static func postcard() throws(EngineError) -> HarnessScene {
        let corpus = try SyntheticCorpus.generate()
        return HarnessScene(name: "postcard", target: RenderTarget(width: 256, height: 160), textures: corpus) { time in
            var quads = [
                Quad(x: 0, y: 0, width: 64, height: 64, texture: "ramp/colour"),
                Quad(x: 64, y: 0, width: 48, height: 32, texture: "neighbours/saturated"),
                Quad(x: 112, y: 0, width: 128, height: 64, texture: "sheet/numbered"),
                Quad(x: 0, y: 64, width: 256, height: 8, texture: "ramp/alpha"),
                Quad(x: 64, y: 36, width: 8, height: 8, texture: "flat/white"),
                Quad(x: 76, y: 36, width: 8, height: 8, texture: "flat/black"),
                Quad(x: 88, y: 36, width: 8, height: 8, texture: "flat/red-half"),
            ]
            for row in 0..<3 {
                for column in 0..<3 {
                    let number = row * 3 + column
                    quads.append(
                        Quad(
                            x: Float(72 + (column - row) * 24), y: Float(76 + (column + row) * 14), width: 48,
                            height: 28, texture: TextureID(SyntheticCorpus.tileName(number, .diamond48x28))))
                }
            }
            for index in 0..<3 {
                quads.append(
                    Quad(
                        x: Float(index * 32), y: 128, width: 32, height: 32,
                        texture: TextureID(SyntheticCorpus.tileName(index, .orthogonal))))
            }
            for index in 0..<2 {
                quads.append(
                    Quad(
                        x: 184, y: Float(84 + index * 36), width: 64, height: 32,
                        texture: TextureID(SyntheticCorpus.tileName(index, .diamond2to1))))
            }
            // Three animated values, each a function of the injected time and nothing else.
            let sweep = Float(time.phase(period: 8) * 256)
            quads.append(Quad(x: sweep - 8, y: 72, width: 16, height: 4, color: RGBA8(255, 220, 60)))
            let angle = time.phase(period: 4) * 2 * Double.pi
            quads.append(
                Quad(
                    x: Float(160 + 14 * cos(angle)), y: Float(100 + 14 * sin(angle)), width: 6, height: 6,
                    color: .white))
            quads.append(
                Quad(x: 244, y: 148, width: 8, height: 8, color: time.phase(period: 2) < 0.5 ? .red : .green))
            return FrameDescription(clearColor: RGBA8(24, 32, 56), quads: quads)
        }
    }

    /// Solid colours only: four bars and one that slides across them once every two seconds.
    public static let bars = HarnessScene(name: "bars", target: RenderTarget(width: 64, height: 32), textures: []) { time in
        var quads = [Quad]()
        for (index, color) in [RGBA8.red, .green, .blue, .white].enumerated() {
            quads.append(Quad(x: Float(index * 16), y: 0, width: 16, height: 32, color: color))
        }
        quads.append(Quad(x: Float(time.phase(period: 2) * 64), y: 12, width: 4, height: 8, color: .black))
        return FrameDescription(clearColor: .black, quads: quads)
    }
}
