import Foundation
import Metal
import QuartzCore
import os

/// What the host draws. The loop asks for one frame per encoded frame, never in between (E-API-2).
@MainActor
public protocol FrameSource: AnyObject {
    /// Whether anything moves without the host saying so. Read on every tick and on every input change; a change
    /// from `.still` to `.ambient` needs a `setNeedsFrame` to wake a paused loop.
    var motion: ContentMotion { get }
    /// The frame for this moment, as an immutable value: the encode reads only it.
    func frame(for context: FrameContext) -> FrameDescription
}

/// The moment a frame is for: engine time from the link's target timestamp, and whether ambience runs.
public struct FrameContext: Sendable, Hashable {
    /// Time, step and discontinuity of this frame (E-TIME-2..4).
    public var clock: FrameClock
    /// Ambient effects run (false under thermal `.critical`, E-RATE-1, and while the host is paused).
    public var ambience: Bool

    public var time: EngineTime { clock.time }

    public init(clock: FrameClock, ambience: Bool) {
        self.clock = clock
        self.ambience = ambience
    }
}

/// Why a command buffer failed. `notPermitted` and `accessRevoked` mean the app lost the GPU (backgrounded).
public enum CommandBufferFailure: Sendable, Hashable {
    case notPermitted
    case accessRevoked
    case other(code: Int)
}

/// Something the loop reports instead of trapping (invariant 5).
public enum EngineEvent: Sendable, Equatable {
    case warning(EngineWarning)
    /// A command buffer completed with an error (E-LIFE-2). Logged; the loop pauses for GPU loss.
    case commandBufferFailed(CommandBufferFailure)
    /// The host's frame was refused before any GPU work (a missing texture, a malformed quad).
    case frameRefused(EngineError)
}

/// Which display link drives the loop (D9).
public enum DisplayLinkKind: Sendable, Hashable {
    /// `CAMetalDisplayLink`, Apple's recommended path. The default.
    case metalDisplayLink
    /// `CADisplayLink` with `present(afterMinimumDuration:)` at the measured rate (iOS only): the switch for the
    /// `CAMetalDisplayLink` hangs other engines saw on older iOS (`research/engine-pitfalls.md` 1.1).
    case displayLink
}

public struct FrameLoopConfiguration: Sendable, Hashable {
    public var link: DisplayLinkKind
    /// Above 60 Hz while interacting, on displays that can (E-RATE-1, E-PLIST-1).
    public var highRateAllowed: Bool
    /// Engine time at the first frame: the host's absolute time, so animation phases continue across launches.
    public var start: EngineTime
    /// The display's maximum rate. 120 covers 60 Hz displays too: their rates are also 120 / n.
    public var maximumFramesPerSecond: Int
    public var restrictions: GPURestrictions
    public var options: RenderOptions
    public var idiom: DeviceIdiom

    public init(
        link: DisplayLinkKind = .metalDisplayLink, highRateAllowed: Bool = false, start: EngineTime = .zero,
        maximumFramesPerSecond: Int = 120, restrictions: GPURestrictions = .none, options: RenderOptions = RenderOptions(),
        idiom: DeviceIdiom = .current
    ) {
        self.link = link
        self.highRateAllowed = highRateAllowed
        self.start = start
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.restrictions = restrictions
        self.options = options
        self.idiom = idiom
    }
}

/// Counts for audits: what the loop did since it was made.
public struct FrameLoopStats: Sendable, Hashable {
    public var ticks = 0
    public var framesEncoded = 0
    public var sourceCalls = 0
    /// Drawables of a stale size released unpresented (E-LIFE-4).
    public var staleDrawablesSkipped = 0
    /// Writes of the layer's `drawableSize`: one per layout change, never per frame (E-LIFE-4).
    public var drawableSizeWrites = 0
    public var waitsUntilScheduled = 0

    public init() {}
}

/// One display-link callback: when it fired, the time the frame is for, and the drawable when the link vends one.
struct LinkTick {
    var timestamp: Double
    var targetTimestamp: Double
    var drawable: (any FrameDrawable)?
}

/// A drawable the loop can size-check and hand to a submitter.
@MainActor
protocol FrameDrawable: AnyObject {
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
}

/// The layer the loop draws into.
@MainActor
protocol DrawableLayer: AnyObject {
    var drawableSize: CGSize { get set }
    func nextDrawable() -> (any FrameDrawable)?
}

/// A display link, from the loop's side.
@MainActor
protocol DisplayLinkDriver: AnyObject {
    var onTick: ((LinkTick) -> Void)? { get set }
    var isPaused: Bool { get set }
    var preferredRange: FrameRateRange { get set }
    func invalidate()
}

struct SubmissionID: Sendable, Hashable {
    var value: Int
}

/// How a command buffer ended.
enum CommandBufferOutcome: Sendable, Hashable {
    case completed
    case failed(CommandBufferFailure)
}

/// The loop's seam to the GPU.
@MainActor
protocol FrameSubmitter: AnyObject {
    /// Called on the main actor when a submitted frame's command buffer completes.
    var onCompletion: ((SubmissionID, CommandBufferOutcome) -> Void)? { get set }
    var maxTextureSide: Int { get }
    /// Plans, encodes, presents and commits one frame. Throws before any GPU work for a frame it refuses.
    func submit(_ frame: FrameDescription, to drawable: any FrameDrawable, presentAfter: Double?) throws(EngineError) -> SubmissionID
    func waitUntilScheduled(_ id: SubmissionID)
}

/// The on-screen engine: a display link, the frame-rate policy, the lifecycle gate and the GPU, around a
/// `CAMetalLayer` the host owns (D3, D9).
///
/// The host forwards layout, lifecycle and interaction; the loop renders on demand at the policy's rate, samples
/// time at the link's target timestamp, and never writes the host's state (invariant 8, E-LIFE-3).
@MainActor
public final class FrameLoop {
    /// Frames in flight at most: the layer's drawable count.
    static let maximumInFlight = 3

    /// The host's lifecycle. Leaving `.active` stops encoding at once; entering `.background` waits until the last
    /// buffer is scheduled.
    public var lifecycle: Lifecycle = .active {
        didSet { lifecycleChanged() }
    }

    /// The user is touching the content (pan, zoom, tap feedback): the interaction rate.
    public var interacting = false {
        didSet { applyRate() }
    }

    /// The host's own pause. The engine reads it (a paused host gets no ambience frames; interaction and
    /// `setNeedsFrame` still draw) and never writes it.
    public var isPaused = false {
        didSet { applyRate() }
    }

    /// What the content needs from the display, for the host to match its overlays to (E-RATE-3).
    public private(set) var contentRate: FrameRate = .paused

    public private(set) var stats = FrameLoopStats()

    private let link: any DisplayLinkDriver
    private let layer: any DrawableLayer
    let submitter: any FrameSubmitter
    private let source: any FrameSource
    private let configuration: FrameLoopConfiguration
    private let events: (EngineEvent) -> Void
    private let systemConditions: SystemConditions?
    private var lowPower = false
    private var thermal = ThermalLevel.nominal
    private var gate = LifecycleGate()
    private var clock: FrameClock
    private var estimator: RateEstimator
    private var needsFrame = false
    private var size: PixelSize?
    private var inFlight = 0
    private var lastSubmission: SubmissionID?

    private static let log = Logger(subsystem: "HearthEngine", category: "FrameLoop")

    /// Configures `layer` for `device`, warms every pipeline off the main thread, and starts a paused link.
    ///
    /// Throws `noDevice` for nil and `gpuFailure` when the warm-up fails. Startup warnings (E-PLIST-1) go to
    /// `events` and the log before this returns.
    public convenience init(
        layer: CAMetalLayer, device: MTLDevice?, configuration: FrameLoopConfiguration = FrameLoopConfiguration(),
        source: any FrameSource, events: @escaping @MainActor (EngineEvent) -> Void = { _ in }
    ) async throws(EngineError) {
        guard let device else { throw .noDevice }
        let warmup = try await MetalBackend.warm(device: device, restrictions: configuration.restrictions)
        let backend = try MetalBackend(device: device, warmup: warmup)
        let surface = MetalLayerSurface(layer: layer, device: device)
        let submitter = try MetalFrameSubmitter(backend: backend, options: configuration.options)
        let link = makeDisplayLink(configuration.link, layer: layer)
        self.init(
            link: link, layer: surface, submitter: submitter, source: source, configuration: configuration,
            info: Bundle.main.infoDictionary, systemConditions: SystemConditions(), events: events)
    }

    init(
        link: any DisplayLinkDriver, layer: any DrawableLayer, submitter: any FrameSubmitter, source: any FrameSource,
        configuration: FrameLoopConfiguration, info: [String: Any]?, systemConditions: SystemConditions? = nil,
        events: @escaping (EngineEvent) -> Void
    ) {
        self.link = link
        self.layer = layer
        self.submitter = submitter
        self.source = source
        self.configuration = configuration
        self.events = events
        self.systemConditions = systemConditions
        clock = FrameClock(start: configuration.start)
        estimator = RateEstimator(maximumFramesPerSecond: configuration.maximumFramesPerSecond)
        link.isPaused = true
        link.onTick = { [weak self] tick in self?.tick(tick) }
        submitter.onCompletion = { [weak self] id, outcome in self?.completed(id, outcome) }
        systemConditions?.onChange = { [weak self] lowPower, thermal in self?.setSystem(lowPower: lowPower, thermal: thermal) }
        if let systemConditions {
            lowPower = systemConditions.lowPower
            thermal = systemConditions.thermal
        }
        for warning in HostChecks.startupWarnings(
            info: info, idiom: configuration.idiom, highRateAllowed: configuration.highRateAllowed)
        {
            emit(.warning(warning))
        }
        applyRate()
    }

    /// Asks for one frame: the content changed. Several requests before the next tick draw one frame.
    public func setNeedsFrame() {
        needsFrame = true
        applyRate()
    }

    /// The host's view changed size. The only place the drawable size is written (E-LIFE-4).
    public func layoutChanged(size points: CGSize, scale: CGFloat) {
        let next = PixelSize(points: points, scale: scale, maxSide: submitter.maxTextureSide)
        guard next != size else { return }
        size = next
        if let next {
            layer.drawableSize = next.cgSize
            stats.drawableSizeWrites += 1
            needsFrame = true
        }
        applyRate()
    }

    /// Stops the link and the observers for good.
    public func invalidate() {
        link.invalidate()
        systemConditions?.invalidate()
    }

    /// Low Power Mode and thermal state, from `SystemConditions` or a test.
    func setSystem(lowPower: Bool, thermal: ThermalLevel) {
        self.lowPower = lowPower
        self.thermal = thermal
        applyRate()
    }

    var conditions: FrameConditions {
        FrameConditions(
            interacting: interacting, motion: isPaused ? .still : source.motion, lowPower: lowPower, thermal: thermal,
            highRateAllowed: configuration.highRateAllowed)
    }

    /// The rate the link runs at and whether it runs at all.
    private func applyRate() {
        contentRate = FramePolicy.rate(for: conditions)
        guard gate.canEncode, size != nil else {
            link.isPaused = true
            return
        }
        switch contentRate {
        case .paused:
            link.preferredRange = FramePolicy.interaction
            link.isPaused = !needsFrame
        case .running(let range, _):
            link.preferredRange = range
            link.isPaused = false
        }
    }

    private func lifecycleChanged() {
        if gate.enter(lifecycle), let lastSubmission {
            submitter.waitUntilScheduled(lastSubmission)
            stats.waitsUntilScheduled += 1
        }
        applyRate()
    }

    func tick(_ tick: LinkTick) {
        stats.ticks += 1
        estimator.add(timestamp: tick.timestamp, targetTimestamp: tick.targetTimestamp)
        let rate = FramePolicy.rate(for: conditions)
        let running = rate != .paused
        guard gate.canEncode, let size, needsFrame || running else {
            applyRate()
            return
        }
        guard inFlight < FrameLoop.maximumInFlight, let drawable = tick.drawable ?? layer.nextDrawable() else { return }
        guard drawable.pixelWidth == size.width, drawable.pixelHeight == size.height else {
            // A drawable from before the last layout: released unpresented, never stretched. Ask again.
            stats.staleDrawablesSkipped += 1
            needsFrame = true
            return
        }
        clock.advance(to: tick.targetTimestamp)
        var ambience = false
        if case .running(_, let on) = rate {
            ambience = on && !isPaused
        }
        let frame = source.frame(for: FrameContext(clock: clock, ambience: ambience))
        stats.sourceCalls += 1
        needsFrame = false
        let presentAfter = configuration.link == .displayLink ? estimator.presentInterval : nil
        do {
            lastSubmission = try submitter.submit(frame, to: drawable, presentAfter: presentAfter)
            inFlight += 1
            stats.framesEncoded += 1
        } catch {
            emit(.frameRefused(error))
        }
        applyRate()
    }

    private func completed(_ id: SubmissionID, _ outcome: CommandBufferOutcome) {
        inFlight = Swift.max(0, inFlight - 1)
        guard case .failed(let failure) = outcome else { return }
        emit(.commandBufferFailed(failure))
        switch failure {
        case .notPermitted, .accessRevoked:
            gate.revoke()
            applyRate()
        case .other:
            break
        }
    }

    private func emit(_ event: EngineEvent) {
        FrameLoop.log.warning("\(String(describing: event), privacy: .public)")
        events(event)
    }
}
