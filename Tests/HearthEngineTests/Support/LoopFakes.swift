import Foundation
import Testing

@testable import HearthEngine

/// A display link the test fires by hand: no run loop, no clock.
@MainActor
final class FakeLink: DisplayLinkDriver {
    var onTick: ((LinkTick) -> Void)?
    var isPaused = false
    var preferredRange = FrameRateRange(minimum: 0, maximum: 0, preferred: 0)
    var invalidated = false
    /// The next callback's target, advanced by each `fire`.
    var now = 1_000.0

    func invalidate() {
        invalidated = true
    }

    /// One callback `interval` seconds after the previous one, as `CADisplayLink` reports it.
    func fire(interval: Double = 1.0 / 60, drawable: (any FrameDrawable)? = nil) {
        let timestamp = now
        now += interval
        onTick?(LinkTick(timestamp: timestamp, targetTimestamp: now, drawable: drawable))
    }

    func fire(times: Int, interval: Double = 1.0 / 60) {
        for _ in 0..<times {
            fire(interval: interval)
        }
    }
}

@MainActor
final class FakeDrawable: FrameDrawable {
    let pixelWidth: Int
    let pixelHeight: Int

    init(_ size: CGSize) {
        pixelWidth = Int(size.width)
        pixelHeight = Int(size.height)
    }
}

/// A layer that vends drawables of its current size, or of a fixed stale size.
@MainActor
final class FakeLayer: DrawableLayer {
    var drawableSize = CGSize.zero
    var stale: CGSize?
    var vends = true

    func nextDrawable() -> (any FrameDrawable)? {
        vends ? FakeDrawable(stale ?? drawableSize) : nil
    }
}

/// A GPU that records what it was asked and completes when the test says so.
@MainActor
final class FakeSubmitter: FrameSubmitter {
    var onCompletion: ((SubmissionID, CommandBufferOutcome) -> Void)?
    var maxTextureSide = 16384
    var submitted: [(frame: FrameDescription, presentAfter: Double?)] = []
    var waits: [SubmissionID] = []
    var refusal: EngineError?
    var duringSubmit: (() -> Void)?
    private(set) var pending: [SubmissionID] = []
    private var next = 0

    var lastID: SubmissionID? { next == 0 ? nil : SubmissionID(value: next - 1) }

    func submit(_ frame: FrameDescription, to drawable: any FrameDrawable, presentAfter: Double?) throws(EngineError) -> SubmissionID {
        if let refusal { throw refusal }
        duringSubmit?()
        submitted.append((frame, presentAfter))
        next += 1
        pending.append(SubmissionID(value: next - 1))
        return SubmissionID(value: next - 1)
    }

    func waitUntilScheduled(_ id: SubmissionID) {
        waits.append(id)
    }

    func complete(_ id: SubmissionID, _ outcome: CommandBufferOutcome = .completed) {
        pending.removeAll { $0 == id }
        onCompletion?(id, outcome)
    }

    func completeAll(_ outcome: CommandBufferOutcome = .completed) {
        for id in pending {
            complete(id, outcome)
        }
    }
}

/// The host: a frame built from its own state, a pause flag and a frame counter the engine must leave alone.
@MainActor
final class FakeSource: FrameSource {
    var motion = ContentMotion.still
    var quads = [Quad(x: 0, y: 0, width: 4, height: 4, color: .red)]
    var contexts: [FrameContext] = []

    func frame(for context: FrameContext) -> FrameDescription {
        contexts.append(context)
        return FrameDescription(clearColor: .black, quads: quads)
    }
}

/// A loop over fakes, laid out at 100 x 50 points at scale 2 unless `layout` is false.
@MainActor
struct LoopRig {
    let link = FakeLink()
    let layer = FakeLayer()
    let submitter = FakeSubmitter()
    let source = FakeSource()
    var events: [EngineEvent] { recorder.events }
    let recorder = EventRecorder()
    let loop: FrameLoop

    init(configuration: FrameLoopConfiguration = FrameLoopConfiguration(idiom: .mac), info: [String: Any]? = nil,
         layout: Bool = true) {
        let recorder = self.recorder
        loop = FrameLoop(
            link: link, layer: layer, submitter: submitter, source: source, configuration: configuration, info: info,
            events: { recorder.events.append($0) })
        if layout {
            loop.layoutChanged(size: CGSize(width: 100, height: 50), scale: 2)
        }
    }

    var frames: Int { submitter.submitted.count }

    /// Draws the frame the layout asked for, so a test starts from a settled loop.
    func settle() {
        link.fire()
        submitter.completeAll()
    }
}

@MainActor
final class EventRecorder {
    var events: [EngineEvent] = []
}
