import Foundation
import QuartzCore

// The display-link adapter: the one file the clock lint exempts (invariant 1). It reads no clock either: both links
// deliver their timestamps, and the loop turns them into `EngineTime`.

/// The link for `kind`. On macOS `CADisplayLink` needs a view or a screen, so the Metal link serves both kinds there.
@MainActor
func makeDisplayLink(_ kind: DisplayLinkKind, layer: CAMetalLayer) -> any DisplayLinkDriver {
    #if os(iOS)
        if kind == .displayLink {
            return ClassicDisplayLinkDriver()
        }
    #endif
    return MetalDisplayLinkDriver(layer: layer)
}

extension CAFrameRateRange {
    init(_ range: FrameRateRange) {
        self.init(minimum: range.minimum, maximum: range.maximum, preferred: range.preferred)
    }
}

/// `CAMetalDisplayLink` (iOS 17, macOS 14): Apple's recommended pacing path. It vends the drawable with each update.
@MainActor
final class MetalDisplayLinkDriver: NSObject, DisplayLinkDriver {
    private let link: CAMetalDisplayLink
    /// The previous update's target: the update carries no `timestamp`, so the interval is target to target.
    private var previousTarget: Double?

    var onTick: ((LinkTick) -> Void)?

    var isPaused: Bool {
        get { link.isPaused }
        set { link.isPaused = newValue }
    }

    var preferredRange = FramePolicy.interaction {
        didSet { link.preferredFrameRateRange = CAFrameRateRange(preferredRange) }
    }

    init(layer: CAMetalLayer) {
        link = CAMetalDisplayLink(metalLayer: layer)
        super.init()
        link.delegate = self
        link.isPaused = true
        link.preferredFrameRateRange = CAFrameRateRange(preferredRange)
        link.add(to: .main, forMode: .common)
    }

    func invalidate() {
        link.invalidate()
    }

    func deliver(target: Double, drawable: (any FrameDrawable)?) {
        let tick = LinkTick(timestamp: previousTarget ?? target, targetTimestamp: target, drawable: drawable)
        previousTarget = target
        onTick?(tick)
    }
}

extension MetalDisplayLinkDriver: @MainActor CAMetalDisplayLinkDelegate {
    // The link is added to the main run loop, so its updates arrive on the main thread.
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // The presentation timestamp is when the frame is seen: the time animation is sampled at (E-TIME-2).
        deliver(target: update.targetPresentationTimestamp, drawable: MetalDrawable(update.drawable))
    }
}

#if os(iOS)
    /// `CADisplayLink`, behind `DisplayLinkKind.displayLink` (D9). The loop takes the drawable from the layer and
    /// presents after the measured interval.
    @MainActor
    final class ClassicDisplayLinkDriver: NSObject, DisplayLinkDriver {
        private var link: CADisplayLink?

        var onTick: ((LinkTick) -> Void)?

        var isPaused: Bool {
            get { link?.isPaused ?? true }
            set { link?.isPaused = newValue }
        }

        var preferredRange = FramePolicy.interaction {
            didSet { link?.preferredFrameRateRange = CAFrameRateRange(preferredRange) }
        }

        override init() {
            super.init()
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.isPaused = true
            link.preferredFrameRateRange = CAFrameRateRange(preferredRange)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func invalidate() {
            link?.invalidate()
            link = nil
        }

        @objc private func step(_ link: CADisplayLink) {
            onTick?(LinkTick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp, drawable: nil))
        }
    }
#endif
