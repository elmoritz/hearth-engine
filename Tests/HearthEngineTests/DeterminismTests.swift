import HearthEngine
import HearthHarness
import Testing

/// E-HAR-2 and E-HAR-3: a frame is a function of its description and an injected time, and of nothing else.
@Suite struct DeterminismTests {
    static let times: [Double] = [0, 1.25, -3, 30 * 86_400]

    // MARK: E-HAR-2

    @Test(.requiresGPU) func `E-HAR-2 two renders at one time are byte-identical`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        for scene in try HarnessScene.catalogue() {
            try scene.load(into: renderer)
            for seconds in Self.times {
                let time = EngineTime(seconds: seconds)
                let first = try scene.render(at: time, with: renderer)
                let second = try scene.render(at: time, with: renderer)
                #expect(first.bytes == second.bytes)
                #expect(try matchesExactly(first, second))
            }
        }
    }

    @Test(.requiresGPU) func `E-HAR-2 negative control renders at two times differ`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        for scene in try HarnessScene.catalogue() {
            try scene.load(into: renderer)
            for seconds in Self.times {
                let now = try scene.render(at: EngineTime(seconds: seconds), with: renderer)
                let later = try scene.render(at: EngineTime(seconds: seconds + 0.5), with: renderer)
                #expect(now.bytes != later.bytes)
                #expect(try !matchesExactly(now, later))
            }
        }
    }

    @Test func `E-HAR-2 a scene is a pure function of its time over 1000 seeded times`() throws {
        var random = SplitMix64(seed: 0x4845_0006)
        for scene in try HarnessScene.catalogue() {
            var distinct = Set<FrameDescription>()
            for _ in 0..<1000 {
                let time = EngineTime(seconds: Double.random(in: -86_400...2_592_000, using: &random))
                let frame = scene.frame(time)
                #expect(frame == scene.frame(time))
                #expect(frame.quads.allSatisfy { $0.rect.x.isFinite && $0.rect.y.isFinite && $0.rect.width > 0 && $0.rect.height > 0 })
                distinct.insert(frame)
            }
            // Time is really an input: a thousand times give (nearly) a thousand frames.
            #expect(distinct.count > 990)
            // Times without a phase still give a frame the renderer accepts: the one at phase 0.
            for seconds in [Double.nan, .infinity, -.infinity] {
                #expect(scene.frame(EngineTime(seconds: seconds)) == scene.frame(.zero))
            }
        }
    }

    @Test func `E-HAR-2 the postcard moves its three animated quads with the injected time`() throws {
        let scene = try HarnessScene.postcard()
        #expect(scene.name == "postcard" && scene.target == RenderTarget(width: 256, height: 160))
        #expect(scene.textures == (try SyntheticCorpus.generate()))
        let start = scene.frame(.zero), quarter = scene.frame(EngineTime(seconds: 1))
        #expect(start.clearColor == RGBA8(24, 32, 56) && start.quads.count == quarter.quads.count)
        // Every texture the scene names is one it brings, and every part of the corpus is on screen.
        let named = Set(start.quads.compactMap { quad -> TextureID? in
            if case .texture(let id) = quad.fill { return id }
            return nil
        })
        #expect(named.isSubset(of: Set(scene.textures.map(\.textureID))))
        #expect(named.count == 7 + 9 + 3 + 2)
        #expect(start.quads.allSatisfy { $0.rect.x + $0.rect.width <= 256 + 8 && $0.rect.y + $0.rect.height <= 160 })
        // Only the last three quads depend on time.
        let animated = start.quads.count - 3
        #expect(Array(start.quads[..<animated]) == Array(quarter.quads[..<animated]))
        #expect(start.quads[animated] == Quad(x: -8, y: 72, width: 16, height: 4, color: RGBA8(255, 220, 60)))
        #expect(quarter.quads[animated] == Quad(x: 24, y: 72, width: 16, height: 4, color: RGBA8(255, 220, 60)))
        #expect(start.quads[animated + 1] == Quad(x: 174, y: 100, width: 6, height: 6, color: .white))
        #expect(abs(quarter.quads[animated + 1].rect.x - 160) < 1e-4 && abs(quarter.quads[animated + 1].rect.y - 114) < 1e-4)
        #expect(start.quads[animated + 2] == Quad(x: 244, y: 148, width: 8, height: 8, color: .red))
        #expect(quarter.quads[animated + 2] == Quad(x: 244, y: 148, width: 8, height: 8, color: .green))
        #expect(scene.frame(EngineTime(seconds: 0.999)).quads[animated + 2].fill == .color(.red))
        #expect(scene.frame(EngineTime(seconds: 8)) == start)

        let bars = HarnessScene.bars
        #expect(bars.name == "bars" && bars.target == RenderTarget(width: 64, height: 32) && bars.textures.isEmpty)
        #expect(bars.frame(.zero) == FrameDescription(clearColor: .black, quads: [
            Quad(x: 0, y: 0, width: 16, height: 32, color: .red), Quad(x: 16, y: 0, width: 16, height: 32, color: .green),
            Quad(x: 32, y: 0, width: 16, height: 32, color: .blue), Quad(x: 48, y: 0, width: 16, height: 32, color: .white),
            Quad(x: 0, y: 12, width: 4, height: 8, color: .black),
        ]))
        #expect(bars.frame(EngineTime(seconds: 0.5)).quads[4] == Quad(x: 16, y: 12, width: 4, height: 8, color: .black))
    }

    // MARK: E-HAR-3

    @Test(.requiresGPU) func `E-HAR-3 100 renders of the postcard scene hash identically`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        let scene = try HarnessScene.postcard()
        try scene.load(into: renderer)
        let time = EngineTime(seconds: 2.75)
        var hashes = Set<String>()
        for _ in 0..<100 {
            hashes.insert(try scene.render(at: time, with: renderer).sha256)
        }
        #expect(hashes.count == 1)
        // And the image is the postcard, not a blank: the clear colour, the ramp's corners and a tile are where the scene puts them.
        let image = try scene.render(at: time, with: renderer)
        #expect(image[250, 80] == RGBA8(24, 32, 56))
        #expect(image[0, 0] == RGBA8(0, 0, 255) && image[63, 63] == RGBA8(255, 255, 0))
        #expect(image[0, 159] == SyntheticCorpus.muted[0] && image[64, 0] == RGBA8(255, 0, 0))
        #expect(image[255, 64] == RGBA8(255, 255, 255, 255) && image[0, 64] == RGBA8(255, 255, 255, 0))
    }

    @Test(.requiresGPU) func `E-HAR-3 negative control a one-pixel change changes the hash`() throws {
        let renderer = try HarnessGPU.makeRenderer()
        let scene = try HarnessScene.postcard()
        try scene.load(into: renderer)
        let time = EngineTime(seconds: 2.75)
        let reference = try scene.render(at: time, with: renderer)

        var frame = scene.frame(time)
        frame.quads.append(Quad(x: 250, y: 80, width: 1, height: 1, color: RGBA8(24, 32, 57)))
        let changed = try renderer.render(frame, target: scene.target)
        #expect(changed.sha256 != reference.sha256)
        #expect(try NearExact.compare(changed, reference, tolerance: .exact).pixelsOverTypical == 1)
        // Another time is another image: one second on, the blinking quad has changed colour.
        #expect(try scene.render(at: EngineTime(seconds: 3.75), with: renderer).sha256 != reference.sha256)
    }

    @Test(.requiresGPU) func `E-HAR-3 a fresh renderer and a reused one hash the same`() throws {
        let scene = try HarnessScene.postcard()
        let time = EngineTime(seconds: 2.75)
        let reused = try HarnessGPU.makeRenderer()
        try scene.load(into: reused)
        let reference = try scene.render(at: time, with: reused).sha256
        // Other frames, sizes and formats in between leave nothing behind.
        _ = try scene.render(at: EngineTime(seconds: 99), with: reused)
        _ = try reused.render(HarnessScene.bars.frame(.zero), target: RenderTarget(width: 7, height: 3, format: .bgra8Unorm))
        try scene.load(into: reused)
        #expect(try scene.render(at: time, with: reused).sha256 == reference)

        let fresh = try HarnessGPU.makeRenderer()
        try scene.load(into: fresh)
        #expect(try scene.render(at: time, with: fresh).sha256 == reference)
    }

    @Test func `E-HAR-3 the hash covers the size as well as the bytes`() throws {
        let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let wide = try PixelImage(width: 2, height: 1, bytes: bytes)
        let tall = try PixelImage(width: 1, height: 2, bytes: bytes)
        #expect(wide.sha256 != tall.sha256)
        #expect(wide.sha256 == (try PixelImage(width: 2, height: 1, bytes: bytes)).sha256)
        var changed = wide
        changed.set(x: 1, y: 0, to: RGBA8(5, 6, 7, 9))
        #expect(changed.sha256 != wide.sha256)
        // SHA-256 of the bytes 02 00 00 00 01 00 00 00 01 02 03 04 05 06 07 08, as lowercase hex.
        #expect(wide.sha256.count == 64 && wide.sha256.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(wide.sha256 == "5edafcdc512a3bd9296c32e7db7bcbfbc5f83c87a1909702fa0f20a67f27341f")
    }

    @Test func `E-HAR-3 the seeded generator repeats`() {
        var a = SplitMix64(seed: 1234567), b = SplitMix64(seed: 1234567), c = SplitMix64(seed: 1234568)
        // The reference outputs of SplitMix64 for this seed.
        #expect([a.next(), a.next(), a.next()] == [6_457_827_717_110_365_317, 3_203_168_211_198_807_973, 9_817_491_932_198_370_423])
        _ = (b.next(), b.next(), b.next())
        #expect(a.next() == b.next())
        #expect(a.next() != c.next())
    }
}
