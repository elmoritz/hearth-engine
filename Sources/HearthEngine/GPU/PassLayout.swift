/// Optional GPU features the engine uses when the device has them (E-API-3). Each is probed, never inferred from
/// a family name.
public struct GPUFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A fragment function reads the render target it writes, in the same pass (programmable blending). Without it
    /// the frame runs the two-pass fallback (D18).
    public static let readsRenderTargetInPass = GPUFeatures(rawValue: 1 << 0)

    public static let all: GPUFeatures = [.readsRenderTargetInPass]
}

/// What a renderer may use of the device: everything it has (`none`), or less, so a test can run the corpus with
/// optional features off and the Simulator's limits on a Mac (E-API-3).
public struct GPURestrictions: Sendable, Hashable {
    /// Features treated as absent even when the device has them.
    public var disabled: GPUFeatures
    /// A lower texture side limit than the device's, or nil for the device's own.
    public var maxTextureSide: Int?

    public init(disabled: GPUFeatures = [], maxTextureSide: Int? = nil) {
        self.disabled = disabled
        self.maxTextureSide = maxTextureSide
    }

    public static let none = GPURestrictions()
    /// Every optional feature off and the Simulator's 8192 texture limit (`research/isometric-landscape.md` 6).
    public static let floor = GPURestrictions(disabled: .all, maxTextureSide: 8192)
}

/// What the probe found on a device, after restrictions.
public struct GPUCapabilities: Sendable, Hashable {
    public var features: GPUFeatures
    /// The largest texture or render-target side, probed by allocation (Metal has no query).
    public var maxTextureSide: Int

    public init(features: GPUFeatures, maxTextureSide: Int) {
        self.features = features
        self.maxTextureSide = maxTextureSide
    }

    /// The probe's answer with `restrictions` applied: features only removed, the limit only lowered.
    func restricted(by restrictions: GPURestrictions) -> GPUCapabilities {
        GPUCapabilities(
            features: features.subtracting(restrictions.disabled),
            maxTextureSide: Swift.min(maxTextureSide, restrictions.maxTextureSide ?? maxTextureSide))
    }

    /// Single pass when the device reads a render target in the same pass; the two-pass fallback otherwise (E-PASS-2).
    var passLayout: PassLayout {
        features.contains(.readsRenderTargetInPass) ? .singlePass : .twoPass
    }
}

/// How a frame's render passes are laid out (D1, D18, E-PASS-1, E-PASS-2).
///
/// Single pass: the scene is drawn into a memoryless `rgba16Float` attachment (attachment 1) and a final stage reads
/// it in the same pass through `[[color(1)]]` and writes the target (attachment 0). Two passes: the scene goes into a
/// stored private texture and a second pass samples it into the target. The final stage is a copy today; grade,
/// encode and dither join it (#3, #11), and #29 proves the two layouts equivalent (E-PASS-4).
public enum PassLayout: Sendable, Hashable, CaseIterable {
    case singlePass
    case twoPass

    /// The format the scene is composited in.
    static let sceneFormat = PixelFormat.rgba16Float

    /// The passes of one frame, in order.
    var passes: [PassDescription] {
        switch self {
        case .singlePass:
            [PassDescription(attachments: [
                PassAttachment(role: .target, load: .dontCare, store: .store, storage: .target),
                PassAttachment(role: .scene, load: .clear, store: .dontCare, storage: .memoryless),
            ])]
        case .twoPass:
            [
                PassDescription(attachments: [
                    PassAttachment(role: .scene, load: .clear, store: .store, storage: .private),
                ]),
                PassDescription(attachments: [
                    PassAttachment(role: .target, load: .dontCare, store: .store, storage: .target),
                ]),
            ]
        }
    }
}

/// One colour attachment of a render pass, as the descriptor audit reads it (E-PASS-1).
struct PassAttachment: Sendable, Hashable {
    enum Role: Sendable, Hashable {
        /// The drawable on screen, or the offscreen target the harness reads back.
        case target
        /// The scene composite.
        case scene
    }

    enum Load: Sendable, Hashable {
        case clear
        case dontCare
    }

    enum Store: Sendable, Hashable {
        case store
        case dontCare
    }

    enum Storage: Sendable, Hashable {
        /// The drawable's texture, or the offscreen target's private texture.
        case target
        case memoryless
        case `private`
    }

    var role: Role
    var load: Load
    var store: Store
    var storage: Storage
}

struct PassDescription: Sendable, Hashable {
    /// Colour attachments by index.
    var attachments: [PassAttachment]
}
