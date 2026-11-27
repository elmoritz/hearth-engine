import Foundation
import HearthHarness
import Testing

@testable import HearthEngine

/// E-SER: the scene file, the serialised frame description of D18.
@Suite struct SceneFileTests {
    static let times: [Double] = [0, 1.25, -3, 30 * 86_400]

    /// A small valid version-1 file, written compactly so the shape tests can edit it by text.
    static let base = #"{"format": "hearth-scene", "layers": [{"name": "a"}], "version": 1, "views": [{"frame": {"clearColor": [1, 2, 3, 4], "quads": [{"blend": "opaque", "fill": {"color": [5, 6, 7, 8]}, "rect": {"height": 4, "width": 3, "x": 1, "y": 2}}]}, "name": "v", "target": {"format": "rgba8Unorm", "height": 2, "width": 2}}]}"#

    static let baseScene = SceneFile(
        layers: [SceneTileLayer(name: "a")],
        views: [
            SceneView(
                name: "v", target: RenderTarget(width: 2, height: 2),
                frame: FrameDescription(
                    clearColor: RGBA8(1, 2, 3, 4), quads: [Quad(x: 1, y: 2, width: 3, height: 4, color: RGBA8(5, 6, 7, 8))]))
        ])

    // MARK: Helpers

    static func encode(_ scene: SceneFile) throws -> [UInt8] {
        [UInt8](try scene.encoded())
    }

    static func decode(_ bytes: [UInt8]) throws(EngineError) -> SceneFile {
        try SceneFile(data: Data(bytes))
    }

    static func decode(_ text: String) throws(EngineError) -> SceneFile {
        try decode(Array(text.utf8))
    }

    /// The error decoding `bytes` throws, or nil when it decodes.
    static func failure(_ bytes: [UInt8]) -> EngineError? {
        do throws(EngineError) {
            _ = try decode(bytes)
            return nil
        } catch {
            return error
        }
    }

    static func failure(_ text: String) -> EngineError? {
        failure(Array(text.utf8))
    }

    static func encodeFailure(_ scene: SceneFile) -> EngineError? {
        do throws(EngineError) {
            _ = try scene.encoded()
            return nil
        } catch {
            return error
        }
    }

    static func path(of error: EngineError?) -> String? {
        if case .invalidSceneFile(let path, _)? = error { return path }
        return nil
    }

    /// Every `Float` of a scene as its bit pattern: `==` cannot see -0 against 0.
    static func floatBits(_ scene: SceneFile) -> [UInt32] {
        scene.views.flatMap { view in
            view.frame.quads.flatMap { [$0.rect.x, $0.rect.y, $0.rect.width, $0.rect.height].map(\.bitPattern) }
        }
    }

    static func randomFloat(_ random: inout SplitMix64) -> Float {
        switch random.next() % 4 {
        case 0: return Float(Int.random(in: -600...600, using: &random)) / 2
        case 1:
            let specials: [Float] = [0, -0.0, .leastNonzeroMagnitude, -.leastNormalMagnitude, .greatestFiniteMagnitude, 0.1, 16_777_216]
            return specials[Int(random.next() % UInt64(specials.count))]
        default:
            while true {
                let value = Float(bitPattern: UInt32(truncatingIfNeeded: random.next()))
                if value.isFinite { return value }
            }
        }
    }

    static let nameScalars: [Unicode.Scalar] = [
        "a", "Z", "0", "/", "-", " ", "\"", "\\", "\n", "\r", "\t", "\u{08}", "\u{0C}", "\u{01}", "\u{1F}", "\u{7F}",
        "\u{E9}", "\u{65}", "\u{301}", "\u{FFFF}", "\u{1F600}",
    ]

    static func randomName(_ random: inout SplitMix64, unique index: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for _ in 0..<Int(random.next() % 6) {
            scalars.append(nameScalars[Int(random.next() % UInt64(nameScalars.count))])
        }
        return String(scalars) + "#\(index)"
    }

    static func randomColor(_ random: inout SplitMix64) -> RGBA8 {
        RGBA8(UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random),
              UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random))
    }

    static func randomScene(_ random: inout SplitMix64) -> SceneFile {
        let layers = (0..<Int(random.next() % 4)).map { SceneTileLayer(name: randomName(&random, unique: $0)) }
        let views = (0..<Int(random.next() % 4)).map { index in
            let quads = (0..<Int(random.next() % 7)).map { _ in
                Quad(
                    rect: PixelRect(
                        x: randomFloat(&random), y: randomFloat(&random), width: randomFloat(&random),
                        height: randomFloat(&random)),
                    fill: random.next() % 2 == 0
                        ? .color(randomColor(&random)) : .texture(TextureID(randomName(&random, unique: 0))),
                    blend: random.next() % 2 == 0 ? .opaque : .premultipliedOver)
            }
            return SceneView(
                name: randomName(&random, unique: index),
                target: RenderTarget(
                    width: Int.random(in: 1...16384, using: &random), height: Int.random(in: 1...16384, using: &random),
                    format: PixelFormat.allCases[Int(random.next() % 3)]),
                frame: FrameDescription(clearColor: randomColor(&random), quads: quads))
        }
        return SceneFile(layers: layers, views: views)
    }

    static func fixture(version: Int) throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: "scene-v\(version)", withExtension: "json", subdirectory: "Fixtures"))
        return [UInt8](try Data(contentsOf: url))
    }

    // MARK: E-SER-1, round trip

    @Test func `E-SER-1 catalogue scenes round-trip byte-identically`() throws {
        for scene in try HarnessScene.catalogue() {
            for seconds in Self.times {
                let file = SceneFile(view: SceneView(name: scene.name, target: scene.target, frame: scene.frame(EngineTime(seconds: seconds))))
                let bytes = try Self.encode(file)
                let decoded = try Self.decode(bytes)
                #expect(decoded == file)
                #expect(Self.floatBits(decoded) == Self.floatBits(file))
                #expect(try Self.encode(decoded) == bytes)
                #expect(decoded.view(named: scene.name)?.frame == scene.frame(EngineTime(seconds: seconds)))
                #expect(decoded.view(named: "no such view") == nil)
            }
        }
    }

    @Test func `E-SER-1 1000 seeded scene files round-trip`() throws {
        var random = SplitMix64(seed: 0x4845_0021)
        var quads = 0
        for _ in 0..<1000 {
            let scene = Self.randomScene(&random)
            quads += scene.views.reduce(0) { $0 + $1.frame.quads.count }
            let bytes = try Self.encode(scene)
            let decoded = try Self.decode(bytes)
            #expect(decoded == scene)
            #expect(Self.floatBits(decoded) == Self.floatBits(scene))
            #expect(decoded.layers.map { Array($0.name.unicodeScalars) } == scene.layers.map { Array($0.name.unicodeScalars) })
            #expect(decoded.views.map { Array($0.name.unicodeScalars) } == scene.views.map { Array($0.name.unicodeScalars) })
            #expect(try Self.encode(decoded) == bytes)
        }
        #expect(quads > 2000)
    }

    @Test(.requiresGPU) func `E-SER-1 the decoded postcard renders the same pixels as the original`() async throws {
        let renderer = try await HarnessGPU.makeRenderer()
        let scene = try HarnessScene.postcard()
        try scene.load(into: renderer)
        for seconds in Self.times {
            let frame = scene.frame(EngineTime(seconds: seconds))
            let bytes = try Self.encode(SceneFile(view: SceneView(name: "postcard", target: scene.target, frame: frame)))
            let view = try #require(try Self.decode(bytes).view(named: "postcard"))
            let original = try renderer.render(frame, target: scene.target)
            let replayed = try renderer.render(view.frame, target: view.target)
            #expect(try matchesExactly(replayed, original))
        }
    }

    @Test(.requiresGPU) func `E-SER-1 negative control a scene file with one changed colour renders different pixels`() async throws {
        let renderer = try await HarnessGPU.makeRenderer()
        let scene = try HarnessScene.postcard()
        try scene.load(into: renderer)
        for seconds in Self.times {
            let frame = scene.frame(EngineTime(seconds: seconds))
            let text = String(decoding: try Self.encode(SceneFile(view: SceneView(name: "postcard", target: scene.target, frame: frame))), as: UTF8.self)
            #expect(text.contains("[255, 220, 60, 255]"))
            let edited = text.replacingOccurrences(of: "[255, 220, 60, 255]", with: "[255, 220, 0, 255]")
            let view = try #require(try Self.decode(edited).view(named: "postcard"))
            #expect(view.frame != frame)
            let original = try renderer.render(frame, target: scene.target)
            let replayed = try renderer.render(view.frame, target: view.target)
            #expect(try !matchesExactly(replayed, original))
        }
    }

    @Test func `E-SER-1 malformed syntax throws invalidSceneFile at its byte`() {
        let cases: [([UInt8], String)] = [
            ([], "byte 0"),
            ([0xEF, 0xBB, 0xBF, 0x7B, 0x7D], "byte 0"),
            ([0xFF], "file"),
            ([0x7B, 0xC3], "file"),
            (Array("{} x".utf8), "byte 3"),
            (Array(#"{"a"#.utf8), "byte 3"),
            (Array("[\"a\u{01}\"]".utf8), "byte 3"),
            (Array("[\"a\u{1F}\"]".utf8), "byte 3"),
            (Array(#"["\x"]"#.utf8), "byte 3"),
            (Array(#"["\"#.utf8), "byte 3"),
            (Array(#"["\ud800"]"#.utf8), "byte 8"),
            (Array(#"["\ud800"#.utf8), "byte 8"),
            (Array(#"["\ud800\u0041"]"#.utf8), "byte 14"),
            (Array(#"["\ud800\n"]"#.utf8), "byte 8"),
            // The boundary of the low-surrogate look-ahead: a backslash as the file's last byte.
            (Array(#"["\ud800\"#.utf8), "byte 8"),
            (Array(#"["\udc00"]"#.utf8), "byte 8"),
            (Array(#"["\udfff"]"#.utf8), "byte 8"),
            (Array(#"["\u12"]"#.utf8), "byte 6"),
            (Array(#"["\u1"#.utf8), "byte 4"),
            (Array(#"["\uZZZZ"]"#.utf8), "byte 4"),
            (Array(#"["\u00G0"]"#.utf8), "byte 6"),
            (Array(#"["\u00g0"]"#.utf8), "byte 6"),
            (Array(#"["\u00/0"]"#.utf8), "byte 6"),
            (Array(#"["\u00:0"]"#.utf8), "byte 6"),
            (Array(#"["\u00@0"]"#.utf8), "byte 6"),
            (Array(#"["\u00`0"]"#.utf8), "byte 6"),
            (Array("[01]".utf8), "byte 2"),
            (Array("[-]".utf8), "byte 2"),
            (Array("[1.]".utf8), "byte 3"),
            (Array("[.5]".utf8), "byte 1"),
            (Array("[1e]".utf8), "byte 3"),
            (Array("[1e+]".utf8), "byte 4"),
            (Array("[1E-]".utf8), "byte 4"),
            (Array("[+1]".utf8), "byte 1"),
            (Array("[NaN]".utf8), "byte 1"),
            (Array("[Infinity]".utf8), "byte 1"),
            (Array("[tru]".utf8), "byte 1"),
            (Array("[nul]".utf8), "byte 1"),
            (Array("[falsy]".utf8), "byte 1"),
            (Array("[t".utf8), "byte 1"),
            (Array(#"{"a" 1}"#.utf8), "byte 5"),
            (Array(#"{"a": 1 "b": 2}"#.utf8), "byte 8"),
            (Array("{1: 2}".utf8), "byte 1"),
            (Array("[1 2]".utf8), "byte 3"),
            (Array(#"{"a": 1,}"#.utf8), "byte 8"),
            (Array("[1,]".utf8), "byte 3"),
            (Array(#"{"a": 1, "a": 2}"#.utf8), "byte 9"),
            (Array("[".utf8), "byte 1"),
            (Array("{".utf8), "byte 1"),
            (Array(#"{"a": "#.utf8), "byte 6"),
            (Array(String(repeating: "[", count: 33).utf8) + Array(String(repeating: "]", count: 33).utf8), "byte 32"),
            (Array(String(repeating: "{\"k\": ", count: 33).utf8) + [0x31] + Array(String(repeating: "}", count: 33).utf8), "byte 192"),
        ]
        for (bytes, path) in cases {
            let error = Self.failure(bytes)
            #expect(Self.path(of: error) == path, "\(String(decoding: bytes, as: UTF8.self)): \(String(describing: error))")
        }
    }

    @Test func `E-SER-1 the parser reads every JSON spelling the format may meet`() throws {
        let text = "\t\r\n [\"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0041\\u00e9\\u00E9\\uD83D\\uDE00\\u0000\", -0, 1E5, 1e-5, 1.5e+3, 0.25, true, false, null, {}, []] \n"
        let parsed = try SceneJSON.parse(Array(text.utf8))
        #expect(parsed == .array([
            .string("\"\\/\u{08}\u{0C}\n\r\t" + "A\u{E9}\u{E9}\u{1F600}\u{0}"), .number("-0"), .number("1E5"), .number("1e-5"),
            .number("1.5e+3"), .number("0.25"), .bool(true), .bool(false), .null, .object([:]), .array([]),
        ]))
        // A literal that ends exactly at the end of the file.
        #expect(try SceneJSON.parse(Array("true".utf8)) == .bool(true))
        #expect(try SceneJSON.parse(Array("false".utf8)) == .bool(false))
        #expect(try SceneJSON.parse(Array("null".utf8)) == .null)
        #expect(try SceneJSON.parse(Array(#"{"b": 1, "a": {"c": [2]}}"#.utf8)) == .object(["a": .object(["c": .array([.number("2")])]), "b": .number("1")]))
    }

    @Test func `E-SER-1 malformed shape throws invalidSceneFile with its path`() {
        #expect(Self.failure(Self.base) == nil)
        let secondView = #""width": 2}}, {"frame": {"clearColor": [0, 0, 0, 0], "quads": []}, "name": "v", "target": {"format": "rgba8Unorm", "height": 1, "width": 1}}]}"#
        let cases: [(String, String, String)] = [
            ("\"hearth-scene\"", "\"other\"", "format"),
            ("\"format\": \"hearth-scene\", ", "", "format"),
            ("\"format\": \"hearth-scene\"", "\"format\": 1", "format"),
            ("\"version\": 1, ", "", "version"),
            ("\"layers\": [{\"name\": \"a\"}], ", "", "layers"),
            ("\"version\": 1,", "\"version\": 1, \"extra\": 0,", "extra"),
            ("\"version\": 1,", "\"version\": 1, \"b\": 0, \"B\": 0,", "B"),
            ("\"layers\": [{\"name\": \"a\"}]", "\"layers\": {}", "layers"),
            ("{\"name\": \"a\"}", "{\"name\": \"a\", \"z\": 1}", "layers[0].z"),
            ("{\"name\": \"a\"}", "{\"name\": 3}", "layers[0].name"),
            ("{\"name\": \"a\"}", "{\"name\": \"\"}", "layers[0].name"),
            ("{\"name\": \"a\"}", "{}", "layers[0].name"),
            ("[{\"name\": \"a\"}]", "[{\"name\": \"a\"}, {\"name\": \"a\"}]", "layers[1].name"),
            ("[{\"name\": \"a\"}]", "[1]", "layers[0]"),
            ("\"name\": \"v\"", "\"name\": \"\"", "views[0].name"),
            ("\"name\": \"v\"", "\"name\": [\"v\"]", "views[0].name"),
            ("\"width\": 2}}]}", secondView, "views[1].name"),
            ("\"views\": [{", "\"views\": [7, {", "views[0]"),
            ("\"rgba8Unorm\"", "\"rgb\"", "views[0].target.format"),
            ("\"height\": 2, \"width\": 2", "\"height\": 2, \"width\": 0", "views[0].target.width"),
            ("\"height\": 2, \"width\": 2", "\"height\": 2, \"width\": 16385", "views[0].target.width"),
            ("\"height\": 2, \"width\": 2", "\"height\": 0, \"width\": 2", "views[0].target.height"),
            ("\"height\": 2, \"width\": 2", "\"height\": -1, \"width\": 2", "views[0].target.height"),
            ("\"height\": 2, \"width\": 2", "\"height\": 16385, \"width\": 2", "views[0].target.height"),
            ("\"height\": 2, \"width\": 2", "\"height\": 2, \"width\": 2.0", "views[0].target.width"),
            ("\"height\": 2, \"width\": 2", "\"height\": 2, \"width\": 2e0", "views[0].target.width"),
            ("\"height\": 2, \"width\": 2", "\"height\": 2, \"width\": 2E0", "views[0].target.width"),
            ("\"height\": 2, \"width\": 2", "\"height\": 2", "views[0].target.width"),
            ("\"target\": {", "\"target\": {\"depth\": 1, ", "views[0].target.depth"),
            ("[1, 2, 3, 4]", "[1, 2, 3]", "views[0].frame.clearColor"),
            ("[1, 2, 3, 4]", "[1, 2, 3, 4, 5]", "views[0].frame.clearColor"),
            ("[1, 2, 3, 4]", "[1, 2, 3, 256]", "views[0].frame.clearColor[3]"),
            ("[1, 2, 3, 4]", "[-1, 2, 3, 4]", "views[0].frame.clearColor[0]"),
            ("[1, 2, 3, 4]", "[1, 2, 3, 4.0]", "views[0].frame.clearColor[3]"),
            ("[1, 2, 3, 4]", "[1, 2, 3, \"4\"]", "views[0].frame.clearColor[3]"),
            ("[1, 2, 3, 4]", "5", "views[0].frame.clearColor"),
            ("\"frame\": {", "\"frame\": {\"extra\": 1, ", "views[0].frame.extra"),
            ("\"quads\": [{\"blend\"", "\"quads\": [1, {\"blend\"", "views[0].frame.quads[0]"),
            ("\"opaque\"", "\"add\"", "views[0].frame.quads[0].blend"),
            ("{\"color\": [5, 6, 7, 8]}", "{}", "views[0].frame.quads[0].fill"),
            ("{\"color\": [5, 6, 7, 8]}", "{\"color\": [5, 6, 7, 8], \"texture\": \"t\"}", "views[0].frame.quads[0].fill"),
            ("{\"color\": [5, 6, 7, 8]}", "{\"texture\": \"t\", \"x\": 1}", "views[0].frame.quads[0].fill"),
            ("{\"color\": [5, 6, 7, 8]}", "{\"color\": [5, 6, 7, 8], \"x\": 1}", "views[0].frame.quads[0].fill"),
            ("{\"color\": [5, 6, 7, 8]}", "{\"x\": 1}", "views[0].frame.quads[0].fill"),
            ("{\"color\": [5, 6, 7, 8]}", "{\"texture\": 4}", "views[0].frame.quads[0].fill.texture"),
            ("{\"color\": [5, 6, 7, 8]}", "[5, 6, 7, 8]", "views[0].frame.quads[0].fill"),
            ("[5, 6, 7, 8]", "[5, 6, 7, 300]", "views[0].frame.quads[0].fill.color[3]"),
            ("\"x\": 1", "\"x\": 1e39", "views[0].frame.quads[0].rect.x"),
            ("\"x\": 1", "\"x\": -1e39", "views[0].frame.quads[0].rect.x"),
            ("\"x\": 1", "\"x\": \"1\"", "views[0].frame.quads[0].rect.x"),
            ("\"x\": 1", "\"x\": null", "views[0].frame.quads[0].rect.x"),
            ("\"height\": 4, ", "", "views[0].frame.quads[0].rect.height"),
            ("\"y\": 2}", "\"y\": 2, \"z\": 0}", "views[0].frame.quads[0].rect.z"),
        ]
        for (from, to, path) in cases {
            #expect(Self.base.contains(from), "\(from)")
            let text = Self.base.replacingOccurrences(of: from, with: to)
            let error = Self.failure(text)
            #expect(Self.path(of: error) == path, "\(text): \(String(describing: error))")
        }
        #expect(Self.path(of: Self.failure("[]")) == "file")
        #expect(Self.path(of: Self.failure("\"scene\"")) == "file")
    }

    @Test func `E-SER-1 encoding a non-finite rectangle or an invalid name throws`() {
        for field in 0..<4 {
            for bad in [Float.nan, .infinity, -.infinity] {
                var scene = Self.baseScene
                var values: [Float] = [1, 2, 3, 4]
                values[field] = bad
                scene.views[0].frame.quads = [
                    Quad(x: 0, y: 0, width: 1, height: 1, color: .red),
                    Quad(x: values[0], y: values[1], width: values[2], height: values[3], color: .red),
                ]
                let name = ["x", "y", "width", "height"][field]
                #expect(Self.path(of: Self.encodeFailure(scene)) == "views[0].frame.quads[1].rect.\(name)")
            }
        }
        var scene = Self.baseScene
        scene.layers = [SceneTileLayer(name: "a"), SceneTileLayer(name: "")]
        #expect(Self.path(of: Self.encodeFailure(scene)) == "layers[1].name")
        scene.layers = [SceneTileLayer(name: "a"), SceneTileLayer(name: "b"), SceneTileLayer(name: "a")]
        #expect(Self.encodeFailure(scene) == .invalidSceneFile(path: "layers[2].name", reason: "duplicate name \"a\""))
        // Names compare as Strings: canonically equivalent spellings are one name, though their bytes differ.
        scene.layers = [SceneTileLayer(name: "\u{E9}"), SceneTileLayer(name: "e\u{301}")]
        #expect(Self.path(of: Self.encodeFailure(scene)) == "layers[1].name")
        let composed = SceneFile(layers: [SceneTileLayer(name: "\u{E9}")])
        let decomposed = SceneFile(layers: [SceneTileLayer(name: "e\u{301}")])
        #expect(composed == decomposed)
        #expect((try? Self.encode(composed)) != (try? Self.encode(decomposed)))
        scene = Self.baseScene
        scene.views.append(SceneView(name: "", target: RenderTarget(width: 1, height: 1), frame: FrameDescription()))
        #expect(Self.encodeFailure(scene) == .invalidSceneFile(path: "views[1].name", reason: "empty"))
        scene.views[1].name = "v"
        #expect(Self.path(of: Self.encodeFailure(scene)) == "views[1].name")
        scene.views[1].name = "w"
        #expect(Self.encodeFailure(scene) == nil)
        for (width, height, path) in [(0, 1, "width"), (16385, 1, "width"), (1, 0, "height"), (1, 16385, "height"), (-4, -4, "width")] {
            scene.views[1].target = RenderTarget(width: width, height: height)
            #expect(Self.path(of: Self.encodeFailure(scene)) == "views[1].target.\(path)")
        }
        scene.views[1].target = RenderTarget(width: 1, height: 1)
        scene.views[1].frame.quads = [Quad(x: .nan, y: 0, width: 1, height: 1, color: .red)]
        #expect(Self.encodeFailure(scene) == .invalidSceneFile(path: "views[1].frame.quads[0].rect.x", reason: "not a finite number"))
    }

    @Test func `E-SER-1 edge scenes round-trip`() throws {
        var scenes = [SceneFile(), SceneFile(layers: [SceneTileLayer(name: "only")])]
        scenes.append(SceneFile(view: SceneView(name: "empty", target: RenderTarget(width: 1, height: 1), frame: FrameDescription())))
        for format in PixelFormat.allCases {
            scenes.append(SceneFile(view: SceneView(
                name: "\(format)", target: RenderTarget(width: 16384, height: 16384, format: format),
                frame: FrameDescription(clearColor: .white, quads: [Quad(x: 0, y: 0, width: 1, height: 1, color: .clear)]))))
        }
        let specials: [Float] = [-0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude, .greatestFiniteMagnitude,
                                 -.greatestFiniteMagnitude, .leastNormalMagnitude, -5, 0]
        scenes.append(SceneFile(view: SceneView(
            name: "verbatim", target: RenderTarget(width: 3, height: 5),
            frame: FrameDescription(quads: [
                Quad(x: specials[0], y: specials[1], width: specials[2], height: specials[3], texture: "unknown", blend: .premultipliedOver),
                Quad(x: specials[4], y: specials[5], width: specials[6], height: specials[7], color: .blue),
            ]))))
        for scene in scenes {
            let bytes = try Self.encode(scene)
            let decoded = try Self.decode(bytes)
            #expect(decoded == scene)
            #expect(Self.floatBits(decoded) == Self.floatBits(scene))
            #expect(try Self.encode(decoded) == bytes)
        }
        #expect(String(decoding: try Self.encode(SceneFile()), as: UTF8.self)
            == "{\n  \"format\": \"hearth-scene\",\n  \"layers\": [],\n  \"version\": 1,\n  \"views\": []\n}\n")
    }

    @Test func `E-SER-1 1000 seeded corruptions throw a typed error or decode`() throws {
        var random = SplitMix64(seed: 0x4845_0121)
        let bytes = try Self.fixture(version: 1)
        var refused = 0
        for _ in 0..<1000 {
            var corrupt = bytes
            let at = Int(random.next() % UInt64(corrupt.count))
            switch random.next() % 4 {
            case 0: corrupt.removeSubrange(at...)
            case 1: corrupt[at] = UInt8(truncatingIfNeeded: random.next())
            case 2: corrupt.insert(UInt8(truncatingIfNeeded: random.next()), at: at)
            default: corrupt.remove(at: at)
            }
            switch Self.failure(corrupt) {
            case nil:
                // A corruption that still reads (a changed digit, say) is a scene, and round-trips like one.
                let scene = try Self.decode(corrupt)
                #expect(try Self.decode(try Self.encode(scene)) == scene)
            case .invalidSceneFile?, .unsupportedSceneVersion?:
                refused += 1
            case let other?:
                Issue.record("unexpected error \(other)")
            }
        }
        #expect(refused > 500)
    }

    @Test func `E-SER-1 a scene with exactly 32 levels of nesting is accepted by the parser`() throws {
        let deepest = String(repeating: "[", count: 32) + String(repeating: "]", count: 32)
        var expected = SceneJSON.array([])
        for _ in 1..<32 { expected = .array([expected]) }
        #expect(try SceneJSON.parse(Array(deepest.utf8)) == expected)
        #expect(SceneJSON.maximumDepth == 32)
        // A scene file nests six deep; the limit leaves the format room to grow.
        #expect(Self.failure(Self.base) == nil)
    }

    // MARK: E-SER-2, versions

    static let fixtureScene = SceneFile(
        layers: [SceneTileLayer(name: "ground"), SceneTileLayer(name: "overlay")],
        views: [
            SceneView(
                name: "main", target: RenderTarget(width: 8, height: 4),
                frame: FrameDescription(clearColor: RGBA8(24, 32, 56), quads: [
                    Quad(x: 0, y: 0, width: 4, height: 4, color: .red),
                    Quad(x: 2.5, y: 0.25, width: 4, height: 2, texture: "flat/red-half", blend: .premultipliedOver),
                ])),
            SceneView(
                name: "minimap", target: RenderTarget(width: 2, height: 2, format: .bgra8Unorm),
                frame: FrameDescription(clearColor: .clear)),
        ])

    @Test func `E-SER-2 the version 1 fixture decodes to its known scene`() throws {
        let bytes = try Self.fixture(version: 1)
        let scene = try Self.decode(bytes)
        #expect(scene == Self.fixtureScene)
        #expect(scene.layers.count == 2 && scene.views.count == 2)
        #expect(try Self.encode(scene) == bytes)
        #expect(scene.view(named: "minimap")?.target.format == .bgra8Unorm)
    }

    @Test func `E-SER-2 a fixture exists for every supported version`() throws {
        #expect(SceneFile.version == 1 && SceneFile.supportedVersions == 1...1)
        #expect(SceneFile.supportedVersions.upperBound == SceneFile.version)
        for version in SceneFile.supportedVersions {
            let bytes = try Self.fixture(version: version)
            _ = try Self.decode(bytes)
            #expect(String(decoding: bytes, as: UTF8.self).contains("\"version\": \(version),"))
        }
        let written = String(decoding: try Self.encode(Self.fixtureScene), as: UTF8.self)
        #expect(written.contains("\"version\": \(SceneFile.version),"))
        #expect(written.contains("\"format\": \"\(SceneFile.format)\","))
    }

    @Test func `E-SER-2 an unknown version throws unsupportedSceneVersion`() {
        for version in [0, -1, 2, 999, Int.max, Int.min] {
            let text = Self.base.replacingOccurrences(of: "\"version\": 1", with: "\"version\": \(version)")
            #expect(Self.failure(text) == .unsupportedSceneVersion(version))
        }
    }

    @Test func `E-SER-2 a version that is not an integer throws invalidSceneFile`() {
        for spelled in ["\"1\"", "1.0", "1e0", "true", "null", "[1]", "9223372036854775808", "-9223372036854775809"] {
            let text = Self.base.replacingOccurrences(of: "\"version\": 1", with: "\"version\": \(spelled)")
            #expect(Self.path(of: Self.failure(text)) == "version", "\(spelled)")
        }
        #expect(Self.failure(Self.base.replacingOccurrences(of: "\"version\": 1, ", with: ""))
            == .invalidSceneFile(path: "version", reason: "missing"))
    }

    @Test func `E-SER-2 the version is read before the body`() {
        let newer = Self.base.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2")
            .replacingOccurrences(of: "\"layers\": [{\"name\": \"a\"}]", with: "\"layers\": 7, \"tiles\": {}")
        #expect(Self.failure(newer) == .unsupportedSceneVersion(2))
        #expect(Self.path(of: Self.failure(newer.replacingOccurrences(of: "\"hearth-scene\"", with: "\"other\""))) == "format")
        #expect(Self.failure(newer.replacingOccurrences(of: "\"format\": \"hearth-scene\", ", with: ""))
            == .invalidSceneFile(path: "format", reason: "missing"))
        #expect(Self.failure("{\"version\": 2, \"format\": \"hearth-scene\"}") == .unsupportedSceneVersion(2))
    }

    @Test func `E-SER-2 error descriptions name the version and the path`() {
        #expect(EngineError.invalidSceneFile(path: "views[0].name", reason: "empty").description == "invalid scene file at views[0].name: empty")
        #expect(EngineError.unsupportedSceneVersion(7).description == "unsupported scene file version 7")
    }

    // MARK: E-SER-3, determinism

    @Test func `E-SER-3 two encodes of one scene are byte-identical`() throws {
        var random = SplitMix64(seed: 0x4845_0221)
        for _ in 0..<1000 {
            let scene = Self.randomScene(&random)
            let rebuilt = SceneFile(
                layers: scene.layers.map { SceneTileLayer(name: String(String.UnicodeScalarView($0.name.unicodeScalars))) },
                views: scene.views.map { SceneView(name: $0.name, target: $0.target, frame: FrameDescription(clearColor: $0.frame.clearColor, quads: Array($0.frame.quads))) })
            let first = try Self.encode(scene)
            #expect(try Self.encode(scene) == first)
            #expect(try Self.encode(rebuilt) == first)
        }
    }

    @Test func `E-SER-3 keys are sorted at every level`() {
        var forward = [String: SceneJSON](), backward = [String: SceneJSON](minimumCapacity: 64)
        let keys = ["b", "a", "B", "\u{E9}", "aa", "A", "_", "1"]
        for key in keys { forward[key] = .int(0) }
        for key in keys.reversed() { backward[key] = .int(0) }
        let expected = "{\"1\": 0, \"A\": 0, \"B\": 0, \"_\": 0, \"a\": 0, \"aa\": 0, \"b\": 0, \"\u{E9}\": 0}\n"
        #expect(String(decoding: SceneJSON.object(forward).written(), as: UTF8.self) == expected)
        #expect(SceneJSON.object(backward).written() == SceneJSON.object(forward).written())
        let nested = SceneJSON.object(["z": .object(["y": .int(1), "x": .array([.object(["q": .null, "p": .null])])])])
        #expect(String(decoding: nested.written(), as: UTF8.self)
            == "{\n  \"z\": {\n    \"x\": [\n      {\"p\": null, \"q\": null}\n    ],\n    \"y\": 1\n  }\n}\n")
        #expect(SceneJSON.keyPrecedes("B", "a") && !SceneJSON.keyPrecedes("a", "B") && !SceneJSON.keyPrecedes("a", "a"))
    }

    @Test func `E-SER-3 numbers have one fixed spelling`() {
        let examples: [(Float, String)] = [
            (64, "64"), (0, "0"), (-0.0, "-0"), (0.5, "0.5"), (0.1, "0.1"), (-2.25, "-2.25"), (1_000_000, "1000000"),
            (.leastNonzeroMagnitude, "1e-45"), (.greatestFiniteMagnitude, "3.4028235e+38"), (16_777_216, "16777216"), (1e20, "1e+20"),
            (0.0001, "0.0001"), (0.00001, "1e-05"),
        ]
        for (value, spelled) in examples {
            #expect(SceneJSON.spelling(of: value) == spelled, "\(value)")
        }
        #expect(SceneJSON.int(-7) == .number("-7") && SceneJSON.int(255) == .number("255"))
        #expect(SceneJSON.float(64) == .number("64"))
    }

    @Test func `E-SER-3 float formatting is shortest round-trip over 1000 seeded floats`() throws {
        var random = SplitMix64(seed: 0x4845_0321)
        let grammar = /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/
        for _ in 0..<1000 {
            let value = Self.randomFloat(&random)
            let spelled = SceneJSON.spelling(of: value)
            #expect(spelled.wholeMatch(of: grammar) != nil, "\(spelled)")
            #expect(Float(spelled)?.bitPattern == value.bitPattern, "\(spelled)")
            #expect(!spelled.hasSuffix(".0"))
            #expect(spelled.count <= value.description.count)
            #expect(try SceneJSON.parse(Array("[\(spelled)]".utf8)) == .array([.number(spelled)]))
        }
    }

    @Test func `E-SER-3 non-canonical input re-encodes canonically`() throws {
        let messy = """
            {"views":[{"target":{"width":2,"height":2.0e0,"format":"rgba8Unorm"},"name":"\\u0076",
              "frame":{"quads":[{"rect":{"y":2.00,"x":0.10e1,"width":3,"height":4.0},
            "fill":{"color":[5,6,7,8]},"blend":"opaque"}],"clearColor":[1,2,3,4]}}],
            \t"version":1,"layers":[{"name":"a"}],"format":"hearth-scene"}
            """
        // height 2.0e0 is not an integer: the target is strict, the rectangle is not.
        #expect(Self.path(of: Self.failure(messy)) == "views[0].target.height")
        let fixed = messy.replacingOccurrences(of: "2.0e0", with: "2")
        let scene = try Self.decode(fixed)
        #expect(scene == Self.baseScene)
        #expect(try Self.encode(scene) == (try Self.encode(Self.baseScene)))
        #expect(try Self.encode(scene) == (try Self.encode(try Self.decode(Self.base))))
        for spelled in ["64.0", "6.4e1", "6.4E+1", "640e-1", "64.000"] {
            let text = Self.base.replacingOccurrences(of: "\"x\": 1", with: "\"x\": \(spelled)")
            let bytes = try Self.encode(try Self.decode(text))
            #expect(String(decoding: bytes, as: UTF8.self).contains("\"x\": 64,"))
        }
    }

    @Test func `E-SER-3 layout rules for empty and scalar containers`() {
        #expect(String(decoding: SceneJSON.array([]).written(), as: UTF8.self) == "[]\n")
        #expect(String(decoding: SceneJSON.object([:]).written(), as: UTF8.self) == "{}\n")
        #expect(String(decoding: SceneJSON.array([.int(1)]).written(), as: UTF8.self) == "[1]\n")
        #expect(String(decoding: SceneJSON.object(["k": .bool(false)]).written(), as: UTF8.self) == "{\"k\": false}\n")
        let mixed = SceneJSON.object(["a": .object([:]), "b": .array([]), "c": .array([.int(1), .bool(true), .null, .string("x")])])
        #expect(String(decoding: mixed.written(), as: UTF8.self) == "{\n  \"a\": {},\n  \"b\": [],\n  \"c\": [1, true, null, \"x\"]\n}\n")
        let nested = SceneJSON.array([.array([.array([])]), .int(2)])
        #expect(String(decoding: nested.written(), as: UTF8.self) == "[\n  [\n    []\n  ],\n  2\n]\n")
        let escapes = SceneJSON.string("\"\\\n\r\t\u{08}\u{0C}\u{01}\u{1F}\u{7F}\u{E9}/\u{1F600}")
        #expect(String(decoding: escapes.written(), as: UTF8.self) == "\"\\\"\\\\\\n\\r\\t\\b\\f\\u0001\\u001f\u{7F}\u{E9}/\u{1F600}\"\n")
        #expect(Array(SceneJSON.string("\u{0}").written()) == Array("\"\\u0000\"\n".utf8))
        // The space is the first character written raw; everything below it is escaped.
        #expect(String(decoding: SceneJSON.string(" a b ").written(), as: UTF8.self) == "\" a b \"\n")
    }
}
