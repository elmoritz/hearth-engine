import Foundation

/// One rendering of a scene: a frame description and the target it is drawn into. The target travels with the
/// frame because a replay needs its size and format to give the same pixels (D18).
public struct SceneView: Sendable, Hashable {
    /// Unique among a scene's views and not empty: the harness and the viewer pick a view by it.
    public var name: String
    public var target: RenderTarget
    public var frame: FrameDescription

    public init(name: String, target: RenderTarget, frame: FrameDescription) {
        self.name = name
        self.target = target
        self.frame = frame
    }
}

/// A tile layer of a scene. Version 1 of the format names its layers and holds nothing else: the list is there so
/// that more than one layer is not a format break (D24); the layer's contents (D16) arrive as a later version.
public struct SceneTileLayer: Sendable, Hashable {
    /// Unique among a scene's layers and not empty.
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// A scene file: the serialised frame description of D18, in a stable, versioned and deterministic format, so a
/// frame built anywhere (a Simulator test, a device, a bug report) replays on the Mac reference path.
///
/// The bytes are UTF-8 JSON with one fixed spelling (E-SER-3): keys sorted at every level, two-space indent, a
/// container that is empty or holds only scalars on one line, `Float` values as their shortest round-trip decimal
/// (`64`, `0.5`). Encode, decode, encode is byte-identical (E-SER-1). Reading accepts any layout and key order but
/// nothing the format does not define. Textures are named, never embedded.
///
/// Encoding and decoding check the same rules, so whatever encodes decodes: names not empty and unique among the
/// views and among the layers, target sides in `1...PixelImage.maximumDimension`, every quad's rectangle finite
/// (JSON has no NaN or infinity). Anything else a frame holds is written as it is, so a replay meets the renderer's
/// own refusal.
///
/// Names and texture names are `String`s, so equality, and the uniqueness of names, is Unicode canonical
/// equivalence: `"\u{E9}"` and `"e\u{301}"` are one name. The bytes follow the scalars, so two scenes that are `==`
/// can still encode differently; one value always encodes to the same bytes (E-SER-3).
public struct SceneFile: Sendable, Hashable {
    /// The `format` member of every scene file.
    public static let format = "hearth-scene"
    /// The version this build writes.
    public static let version = 1
    /// The versions this build reads (E-SER-2). Each has a fixture in the tests that must keep decoding.
    public static let supportedVersions: ClosedRange<Int> = 1...version

    public var layers: [SceneTileLayer]
    public var views: [SceneView]

    public init(layers: [SceneTileLayer] = [], views: [SceneView] = []) {
        self.layers = layers
        self.views = views
    }

    /// A scene of one view and no layers.
    public init(view: SceneView) {
        self.init(views: [view])
    }

    /// Decodes a scene file. Throws `unsupportedSceneVersion` for a version outside `supportedVersions`, and
    /// `invalidSceneFile` for anything else that is not a scene file of its version.
    public init(data: Data) throws(EngineError) {
        self = try SceneFileCodec.decode([UInt8](data))
    }

    /// The canonical bytes of this scene. Throws `invalidSceneFile` for a scene the format cannot hold.
    public func encoded() throws(EngineError) -> Data {
        try validate()
        return Data(SceneFileCodec.encode(self).written())
    }

    /// The view called `name`, if there is one.
    public func view(named name: String) -> SceneView? {
        views.first { $0.name == name }
    }

    /// The rules both directions check.
    func validate() throws(EngineError) {
        try Self.checkNames(layers.map(\.name), list: "layers")
        try Self.checkNames(views.map(\.name), list: "views")
        let sides = 1...PixelImage.maximumDimension
        for (viewIndex, view) in views.enumerated() {
            let path = "views[\(viewIndex)]"
            guard sides.contains(view.target.width) else {
                throw .invalidSceneFile(path: "\(path).target.width", reason: "\(view.target.width) is outside \(sides)")
            }
            guard sides.contains(view.target.height) else {
                throw .invalidSceneFile(path: "\(path).target.height", reason: "\(view.target.height) is outside \(sides)")
            }
            for (quadIndex, quad) in view.frame.quads.enumerated() {
                let rect = quad.rect
                for (field, value) in [("x", rect.x), ("y", rect.y), ("width", rect.width), ("height", rect.height)]
                where !value.isFinite {
                    throw .invalidSceneFile(path: "\(path).frame.quads[\(quadIndex)].rect.\(field)", reason: "not a finite number")
                }
            }
        }
    }

    private static func checkNames(_ names: [String], list: String) throws(EngineError) {
        var seen = Set<String>()
        for (index, name) in names.enumerated() {
            guard !name.isEmpty else { throw .invalidSceneFile(path: "\(list)[\(index)].name", reason: "empty") }
            guard seen.insert(name).inserted else {
                throw .invalidSceneFile(path: "\(list)[\(index)].name", reason: "duplicate name \"\(name)\"")
            }
        }
    }
}

extension PixelFormat {
    /// The spelling in a scene file.
    var sceneName: String {
        switch self {
        case .rgba8Unorm: "rgba8Unorm"
        case .bgra8Unorm: "bgra8Unorm"
        case .rgba16Float: "rgba16Float"
        }
    }
}

extension Quad.Blend {
    /// The spelling in a scene file.
    var sceneName: String {
        switch self {
        case .opaque: "opaque"
        case .premultipliedOver: "premultipliedOver"
        }
    }
}

/// The mapping between `SceneFile` and its JSON, by version.
enum SceneFileCodec {
    static func encode(_ scene: SceneFile) -> SceneJSON {
        .object([
            "format": .string(SceneFile.format),
            "version": .int(SceneFile.version),
            "layers": .array(scene.layers.map { .object(["name": .string($0.name)]) }),
            "views": .array(scene.views.map(encode)),
        ])
    }

    private static func encode(_ view: SceneView) -> SceneJSON {
        .object([
            "name": .string(view.name),
            "target": .object([
                "format": .string(view.target.format.sceneName),
                "width": .int(view.target.width),
                "height": .int(view.target.height),
            ]),
            "frame": .object([
                "clearColor": encode(view.frame.clearColor),
                "quads": .array(view.frame.quads.map(encode)),
            ]),
        ])
    }

    private static func encode(_ color: RGBA8) -> SceneJSON {
        .array([color.r, color.g, color.b, color.a].map { .int(Int($0)) })
    }

    private static func encode(_ quad: Quad) -> SceneJSON {
        let fill: SceneJSON =
            switch quad.fill {
            case .color(let color): .object(["color": encode(color)])
            case .texture(let id): .object(["texture": .string(id.name)])
            }
        return .object([
            "blend": .string(quad.blend.sceneName),
            "fill": fill,
            "rect": .object([
                "x": .float(quad.rect.x), "y": .float(quad.rect.y),
                "width": .float(quad.rect.width), "height": .float(quad.rect.height),
            ]),
        ])
    }

    static func decode(_ bytes: [UInt8]) throws(EngineError) -> SceneFile {
        let root = SceneValue(json: try SceneJSON.parse(bytes), path: "")
        let members = try root.members()
        // The format, then the version, then the body: a newer file is refused by its version whatever its body.
        guard let format = members["format"] else { throw root.child("format").failure("missing") }
        guard try format.string() == SceneFile.format else {
            throw format.failure("expected \"\(SceneFile.format)\"")
        }
        guard let version = members["version"] else { throw root.child("version").failure("missing") }
        let number = try version.int()
        guard SceneFile.supportedVersions.contains(number) else { throw .unsupportedSceneVersion(number) }
        let scene = try decodeVersion1(root)
        try scene.validate()
        return scene
    }

    private static func decodeVersion1(_ root: SceneValue) throws(EngineError) -> SceneFile {
        let members = try root.members(exactly: ["format", "version", "layers", "views"])
        var layers = [SceneTileLayer]()
        for layer in try members.value("layers").elements() {
            layers.append(SceneTileLayer(name: try layer.members(exactly: ["name"]).value("name").string()))
        }
        var views = [SceneView]()
        for view in try members.value("views").elements() {
            views.append(try decodeView(view))
        }
        return SceneFile(layers: layers, views: views)
    }

    private static func decodeView(_ value: SceneValue) throws(EngineError) -> SceneView {
        let members = try value.members(exactly: ["name", "target", "frame"])
        let target = try members.value("target").members(exactly: ["format", "width", "height"])
        let formatValue = try target.value("format")
        let formatName = try formatValue.string()
        guard let format = PixelFormat.allCases.first(where: { $0.sceneName == formatName }) else {
            throw formatValue.failure("unknown pixel format \"\(formatName)\"")
        }
        let frame = try members.value("frame").members(exactly: ["clearColor", "quads"])
        var quads = [Quad]()
        for quad in try frame.value("quads").elements() {
            quads.append(try decodeQuad(quad))
        }
        return SceneView(
            name: try members.value("name").string(),
            target: RenderTarget(width: try target.value("width").int(), height: try target.value("height").int(), format: format),
            frame: FrameDescription(clearColor: try decodeColor(try frame.value("clearColor")), quads: quads))
    }

    private static func decodeQuad(_ value: SceneValue) throws(EngineError) -> Quad {
        let members = try value.members(exactly: ["blend", "fill", "rect"])
        let blendValue = try members.value("blend")
        let blendName = try blendValue.string()
        guard let blend = Quad.Blend.allCases.first(where: { $0.sceneName == blendName }) else {
            throw blendValue.failure("unknown blend \"\(blendName)\"")
        }
        let fillValue = try members.value("fill")
        let fillMembers = try fillValue.members()
        let fill: Quad.Fill
        switch (fillMembers.members["color"], fillMembers.members["texture"], fillMembers.members.count) {
        case (let color?, nil, 1): fill = .color(try decodeColor(color))
        case (nil, let texture?, 1): fill = .texture(TextureID(try texture.string()))
        default: throw fillValue.failure("expected exactly one of \"color\" and \"texture\"")
        }
        let rect = try members.value("rect").members(exactly: ["x", "y", "width", "height"])
        return Quad(
            rect: PixelRect(
                x: try rect.value("x").float(), y: try rect.value("y").float(),
                width: try rect.value("width").float(), height: try rect.value("height").float()),
            fill: fill, blend: blend)
    }

    private static func decodeColor(_ value: SceneValue) throws(EngineError) -> RGBA8 {
        let elements = try value.elements()
        guard elements.count == 4 else { throw value.failure("expected 4 components, found \(elements.count)") }
        var components = [UInt8]()
        for element in elements {
            let component = try element.int()
            guard let byte = UInt8(exactly: component) else { throw element.failure("\(component) is outside 0...255") }
            components.append(byte)
        }
        return RGBA8(components[0], components[1], components[2], components[3])
    }
}

/// A JSON value and where it sits in the file, so every refusal names its path.
struct SceneValue {
    let json: SceneJSON
    let path: String

    func failure(_ reason: String) -> EngineError {
        .invalidSceneFile(path: path.isEmpty ? "file" : path, reason: reason)
    }

    func child(_ key: String) -> SceneValue {
        SceneValue(json: .null, path: path.isEmpty ? key : "\(path).\(key)")
    }

    /// An object's members, keyed and each with its own path.
    func members() throws(EngineError) -> SceneMembers {
        guard case .object(let members) = json else { throw failure("expected an object") }
        var out = [String: SceneValue]()
        for (key, value) in members {
            out[key] = SceneValue(json: value, path: child(key).path)
        }
        return SceneMembers(owner: self, members: out)
    }

    /// An object's members, which must be exactly `keys`: an unknown key is refused rather than dropped, so a
    /// re-encode never loses what the file said.
    func members(exactly keys: Set<String>) throws(EngineError) -> SceneMembers {
        let found = try members()
        if let unknown = found.members.keys.filter({ !keys.contains($0) }).min(by: SceneJSON.keyPrecedes) {
            throw child(unknown).failure("unknown key")
        }
        return found
    }

    func elements() throws(EngineError) -> [SceneValue] {
        guard case .array(let elements) = json else { throw failure("expected an array") }
        return elements.enumerated().map { SceneValue(json: $1, path: "\(path)[\($0)]") }
    }

    func string() throws(EngineError) -> String {
        guard case .string(let text) = json else { throw failure("expected a string") }
        return text
    }

    /// A number written without a fraction or an exponent, in `Int`'s range.
    func int() throws(EngineError) -> Int {
        guard case .number(let text) = json else { throw failure("expected an integer") }
        guard !text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) else {
            throw failure("expected an integer, found \(text)")
        }
        guard let value = Int(text) else { throw failure("\(text) is outside the integer range") }
        return value
    }

    /// A number that reads as a finite `Float`, converted once from its text (correctly rounded).
    func float() throws(EngineError) -> Float {
        guard case .number(let text) = json else { throw failure("expected a number") }
        guard let value = Float(text), value.isFinite else { throw failure("\(text) is not a finite Float") }
        return value
    }
}

/// An object's members with their paths.
struct SceneMembers {
    let owner: SceneValue
    let members: [String: SceneValue]

    /// The member called `key`; a missing one is refused with its path.
    func value(_ key: String) throws(EngineError) -> SceneValue {
        guard let value = members[key] else { throw owner.child(key).failure("missing") }
        return value
    }

    subscript(key: String) -> SceneValue? {
        members[key]
    }
}
