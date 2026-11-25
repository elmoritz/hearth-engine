import HearthEngine
import HearthHarness
import Testing

extension Trait where Self == ConditionTrait {
    /// A GPU test: without a Metal device it reports skipped, never passed and never failed (E-HAR-5).
    static var requiresGPU: Self { requiresGPU(HarnessGPU.current) }

    /// The trait for a given answer of the device probe, so the skip itself can be tested.
    static func requiresGPU(_ availability: HarnessGPU.Availability) -> Self {
        .enabled(if: availability.isAvailable, "no Metal device: skipped, which is not passed (E-PROOF-2)")
    }
}

/// The exact comparison every analytic readback test uses, so its negative control exercises the same code.
func matchesExactly(_ actual: PixelImage, _ expected: PixelImage) throws -> Bool {
    try NearExact.compare(actual, expected, tolerance: .exact).passed
}

/// An image built pixel by pixel in the test: the analytic expectation.
func expectedImage(width: Int, height: Int, clear: RGBA8 = .clear, _ pixel: (Int, Int) -> RGBA8?) throws -> PixelImage {
    var image = try PixelImage(width: width, height: height, filledWith: clear)
    for y in 0..<height {
        for x in 0..<width {
            if let color = pixel(x, y) {
                image.set(x: x, y: y, to: color)
            }
        }
    }
    return image
}
