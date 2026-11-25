import Foundation
import HearthEngine
import HearthHarness
import Metal
import Testing

/// The headless path on a real device. Every expectation is computed here, pixel by pixel.
@Suite struct OffscreenRenderTests {
    let clear = RGBA8(10, 20, 30, 40)

    // MARK: E-HAR-1

    @Test(.requiresGPU) func `E-HAR-1 a 1x1 red quad reads back exactly where placed`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        let frame = FrameDescription(clearColor: clear, quads: [Quad(x: 5, y: 9, width: 1, height: 1, color: .red)])
        let image = try renderer.render(frame, target: RenderTarget(width: 16, height: 16))
        #expect(image.width == 16 && image.height == 16)
        #expect(image[5, 9] == .red)
        var others = 0
        for y in 0..<16 {
            for x in 0..<16 where image[x, y] == clear {
                others += 1
            }
        }
        #expect(others == 255)
        let expected = try expectedImage(width: 16, height: 16, clear: clear) { x, y in x == 5 && y == 9 ? .red : nil }
        #expect(try matchesExactly(image, expected))
    }

    @Test(.requiresGPU) func `E-HAR-1 negative control a quad one pixel off fails the exact comparison`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        let expected = try expectedImage(width: 16, height: 16, clear: clear) { x, y in x == 5 && y == 9 ? .red : nil }
        for (x, y) in [(6, 9), (4, 9), (5, 8), (5, 10)] {
            let frame = FrameDescription(clearColor: clear, quads: [Quad(x: Float(x), y: Float(y), width: 1, height: 1, color: .red)])
            let image = try renderer.render(frame, target: RenderTarget(width: 16, height: 16))
            #expect(try !matchesExactly(image, expected))
        }
        // The wrong colour in the right place fails as well.
        let off = FrameDescription(clearColor: clear, quads: [Quad(x: 5, y: 9, width: 1, height: 1, color: RGBA8(254, 0, 0))])
        #expect(try !matchesExactly(try renderer.render(off, target: RenderTarget(width: 16, height: 16)), expected))
    }

    @Test(.requiresGPU, arguments: [(1, 1), (3, 5), (257, 129), (16384, 1), (1, 4099)])
    func `E-HAR-1 a quad reads back where placed at every size`(width: Int, height: Int) throws {
        let renderer = try HarnessGPU.makeRenderer()
        let color = RGBA8(1, 127, 254, 255)
        let frame = FrameDescription(
            clearColor: clear, quads: [Quad(x: Float(width - 1), y: Float(height - 1), width: 1, height: 1, color: color)])
        let image = try renderer.render(frame, target: RenderTarget(width: width, height: height))
        let expected = try expectedImage(width: width, height: height, clear: clear) { x, y in
            x == width - 1 && y == height - 1 ? color : nil
        }
        #expect(image == expected)
    }

    @Test(.requiresGPU) func `E-HAR-1 quads clip at the target edge and follow the pixel-centre rule`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        let frame = FrameDescription(clearColor: clear, quads: [
            Quad(x: -2, y: -2, width: 4, height: 3, color: .red),          // partly outside: covers (0...1, 0)
            Quad(x: 6, y: 6, width: 100, height: 100, color: .green),      // runs past the far corner
            Quad(x: 20, y: 2, width: 3, height: 3, color: .white),         // fully outside
            Quad(x: -9, y: 2, width: 3, height: 3, color: .white),         // fully outside
            Quad(x: 3.4, y: 3.4, width: 1, height: 1, color: .blue),       // holds the centre of (3, 3) only
            Quad(x: 0.6, y: 4.6, width: 0.8, height: 0.8, color: .white),  // holds no pixel centre
            Quad(x: 2, y: 6, width: 1.4, height: 1.4, color: .magenta),    // the centre of (2, 6) only; the next is at 3.5
            Quad(x: 4, y: 0, width: 0, height: 5, color: .white),          // empty
            Quad(x: 4, y: 0, width: 5, height: 0, color: .white),          // empty
            Quad(x: 7, y: 3, width: -3, height: 2, color: .white),         // negative size draws nothing
            Quad(x: 4, y: 5, width: 2, height: -2, color: .white),         // negative size draws nothing
        ])
        let image = try renderer.render(frame, target: RenderTarget(width: 8, height: 8))
        let expected = try expectedImage(width: 8, height: 8, clear: clear) { x, y in
            if x <= 1 && y == 0 { return .red }
            if x >= 6 && y >= 6 { return .green }
            if x == 3 && y == 3 { return .blue }
            if x == 2 && y == 6 { return .magenta }
            return nil
        }
        #expect(image == expected)
    }

    @Test(.requiresGPU) func `E-HAR-1 an empty frame is the clear colour and later quads overwrite earlier ones`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        let target = RenderTarget(width: 5, height: 3)
        #expect(try renderer.render(FrameDescription(clearColor: clear), target: target) == PixelImage(width: 5, height: 3, filledWith: clear))
        #expect(try renderer.render(FrameDescription(), target: target) == PixelImage(width: 5, height: 3, filledWith: .clear))

        // No blending: a later translucent value replaces the earlier one verbatim.
        let over = RGBA8(0, 0, 200, 64)
        let frame = FrameDescription(clearColor: clear, quads: [
            Quad(x: 0, y: 0, width: 3, height: 3, color: .red), Quad(x: 2, y: 1, width: 3, height: 1, color: over),
        ])
        let expected = try expectedImage(width: 5, height: 3, clear: clear) { x, y in
            if y == 1 && x >= 2 { return over }
            return x < 3 ? .red : nil
        }
        #expect(try renderer.render(frame, target: target) == expected)
    }

    @Test(.requiresGPU) func `E-HAR-1 a bgra target reads back in rgba order`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        let color = RGBA8(200, 100, 50, 25)
        let frame = FrameDescription(clearColor: clear, quads: [Quad(x: 1, y: 0, width: 1, height: 2, color: color)])
        let rgba = try renderer.render(frame, target: RenderTarget(width: 3, height: 2, format: .rgba8Unorm))
        let bgra = try renderer.render(frame, target: RenderTarget(width: 3, height: 2, format: .bgra8Unorm))
        #expect(bgra[1, 1] == color)
        #expect(bgra[0, 0] == clear)
        #expect(bgra == rgba)
        // Both pipelines are cached per format: a second frame on each still matches.
        #expect(try renderer.render(frame, target: RenderTarget(width: 3, height: 2, format: .bgra8Unorm)) == rgba)
    }

    @Test(.requiresGPU) func `E-HAR-1 a textured quad reads back its texels where placed`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        var random = SplitMix64(seed: 0x4845_0002)
        var texels = try PixelImage(width: 5, height: 3, filledWith: .black)
        for y in 0..<3 {
            for x in 0..<5 {
                texels.set(x: x, y: y, to: RGBA8(.random(in: 0...255, using: &random), .random(in: 0...255, using: &random), .random(in: 0...255, using: &random), .random(in: 0...255, using: &random)))
            }
        }
        try renderer.setTexture("noise", image: texels)
        let frame = FrameDescription(clearColor: clear, quads: [
            Quad(x: 2, y: 1, width: 5, height: 3, texture: "noise"),    // one texel per pixel
            Quad(x: 8, y: 0, width: 10, height: 6, texture: "noise"),   // magnified twice: nearest, no filtering
        ])
        let image = try renderer.render(frame, target: RenderTarget(width: 20, height: 7))
        let expected = try expectedImage(width: 20, height: 7, clear: clear) { x, y in
            if (2..<7).contains(x) && (1..<4).contains(y) { return texels[x - 2, y - 1] }
            if (8..<18).contains(x) && y < 6 { return texels[(x - 8) / 2, y / 2] }
            return nil
        }
        #expect(image == expected)

        // Replacing a texture under its id changes the next frame.
        try renderer.setTexture("noise", image: PixelImage(width: 1, height: 1, filledWith: .green))
        let replaced = try renderer.render(frame, target: RenderTarget(width: 20, height: 7))
        #expect(replaced[2, 1] == .green && replaced[17, 5] == .green && replaced[0, 0] == clear)
    }

    // MARK: E-HAR-4

    @Test func `E-HAR-4 a nil device throws noDevice`() {
        #expect(throws: EngineError.noDevice) { try OffscreenRenderer(device: nil) }
        #expect(throws: EngineError.noDevice) { try HarnessGPU.makeRenderer(.unavailable(reason: "none")) }
    }

    @Test(.requiresGPU) func `E-HAR-4 a well-formed frame throws nothing`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        #expect(!renderer.deviceName.isEmpty)
        #expect(renderer.deviceName == HarnessGPU.probe().device?.name)
        try renderer.setTexture("white", image: PixelImage(width: 2, height: 2, filledWith: .white))
        let frame = FrameDescription(quads: [
            Quad(x: 0, y: 0, width: 2, height: 2, texture: "white"), Quad(x: 2, y: 0, width: 2, height: 2, color: .red),
        ])
        let image = try renderer.render(frame, target: RenderTarget(width: 4, height: 2))
        #expect(image[0, 0] == .white && image[3, 1] == .red)
    }

    @Test(.requiresGPU) func `E-HAR-4 a missing texture throws on the device path and the renderer stays usable`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        let frame = FrameDescription(clearColor: clear, quads: [Quad(x: 1, y: 1, width: 2, height: 2, texture: "absent")])
        let target = RenderTarget(width: 4, height: 4)
        #expect(throws: EngineError.missingTexture("absent")) { try renderer.render(frame, target: target) }
        #expect(throws: EngineError.unsupportedFormat(.rgba16Float)) {
            try renderer.render(frame, target: RenderTarget(width: 4, height: 4, format: .rgba16Float))
        }
        #expect(try renderer.render(FrameDescription(clearColor: clear), target: target) == PixelImage(width: 4, height: 4, filledWith: clear))
    }

    @Test(.requiresGPU) func `E-HAR-4 a fallback is drawn only when the caller asks`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        let frame = FrameDescription(clearColor: clear, quads: [Quad(x: 1, y: 1, width: 2, height: 2, texture: "sprite")])
        let target = RenderTarget(width: 4, height: 4)
        let asked = RenderOptions(missingTexture: .fallback)
        #expect(RenderOptions.fallbackColor == .magenta)

        // Not asked: an error, and no image.
        #expect(throws: EngineError.missingTexture("sprite")) { try renderer.render(frame, target: target) }
        #expect(throws: EngineError.missingTexture("sprite")) {
            try renderer.render(frame, target: target, options: RenderOptions(missingTexture: .throwError))
        }
        // Asked: the quad in the fallback colour, nothing else touched.
        let fallback = try expectedImage(width: 4, height: 4, clear: clear) { x, y in
            (1...2).contains(x) && (1...2).contains(y) ? .magenta : nil
        }
        #expect(try renderer.render(frame, target: target, options: asked) == fallback)
        // With the texture present the option changes nothing.
        try renderer.setTexture("sprite", image: PixelImage(width: 2, height: 2, filledWith: .green))
        let textured = try expectedImage(width: 4, height: 4, clear: clear) { x, y in
            (1...2).contains(x) && (1...2).contains(y) ? .green : nil
        }
        #expect(try renderer.render(frame, target: target, options: asked) == textured)
        #expect(try renderer.render(frame, target: target) == textured)
    }

    // MARK: E-VAL-1

    @Test(.requiresGPU) func `E-VAL-1 every harness scene renders through every pipeline under the validation layers`() throws {
        let device = try #require(HarnessGPU.probe().device)
        if ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"] == "1" {
            // The gate's validation step: the device must be the validating one, or the run proved nothing.
            #expect(String(describing: type(of: device)).contains("Debug"))
        }
        let renderer = try OffscreenRenderer(device: device)
        let scenes = try HarnessScene.catalogue()
        #expect(scenes.map(\.name) == ["postcard", "bars"])
        for scene in scenes {
            // Without its textures, on the fallback path; then with them, on the textured path.
            let frame = scene.frame(EngineTime(seconds: 1.5))
            let fallback = try renderer.render(frame, target: scene.target, options: RenderOptions(missingTexture: .fallback))
            try scene.load(into: renderer)
            let textured = try scene.render(at: EngineTime(seconds: 1.5), with: renderer)
            #expect(textured.width == scene.target.width && textured.height == scene.target.height)
            #expect((fallback == textured) == scene.textures.isEmpty)
            var bgra = scene.target
            bgra.format = .bgra8Unorm
            #expect(try renderer.render(frame, target: bgra) == textured)
        }
    }

    @Test(.requiresGPU) func `E-VAL-1 invalid input is rejected before it reaches Metal`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        let quad = Quad(x: 0, y: 0, width: 1, height: 1, color: .red)
        #expect(throws: EngineError.invalidTargetSize(width: 0, height: 4)) {
            try renderer.render(FrameDescription(quads: [quad]), target: RenderTarget(width: 0, height: 4))
        }
        #expect(throws: EngineError.invalidTargetSize(width: 4, height: 16385)) {
            try renderer.render(FrameDescription(quads: [quad]), target: RenderTarget(width: 4, height: 16385))
        }
        #expect(throws: EngineError.invalidQuad(index: 1)) {
            try renderer.render(FrameDescription(quads: [quad, Quad(x: .nan, y: 0, width: 1, height: 1, color: .red)]), target: RenderTarget(width: 4, height: 4))
        }
        #expect(throws: EngineError.missingTexture("absent")) {
            try renderer.render(FrameDescription(quads: [Quad(x: 0, y: 0, width: 1, height: 1, texture: "absent")]), target: RenderTarget(width: 4, height: 4))
        }
        #expect(throws: EngineError.unsupportedFormat(.rgba16Float)) {
            try renderer.render(FrameDescription(quads: [quad]), target: RenderTarget(width: 4, height: 4, format: .rgba16Float))
        }
        #expect(throws: EngineError.malformedAssetHeader(width: 0, height: 0, byteCount: 0)) {
            try renderer.setTexture("empty", image: PixelImage(width: 0, height: 0, bytes: []))
        }
    }

    @Test(.requiresGPU, arguments: [(1, 1), (3, 5), (16384, 1), (1, 16384)])
    func `E-VAL-1 the smallest the odd and the widest target render under validation`(width: Int, height: Int) throws {
        let renderer = try HarnessGPU.makeRenderer()
        try renderer.setTexture("texel", image: PixelImage(width: 1, height: 1, filledWith: .blue))
        let frame = FrameDescription(clearColor: clear, quads: [
            Quad(x: 0, y: 0, width: Float(width), height: Float(height), texture: "texel"),
            Quad(x: 0, y: 0, width: 1, height: 1, color: .red),
        ])
        let image = try renderer.render(frame, target: RenderTarget(width: width, height: height))
        #expect(image[0, 0] == .red)
        #expect(image[width - 1, height - 1] == (width * height == 1 ? .red : .blue))
        #expect(image.bytes.count == width * height * 4)
    }
}
