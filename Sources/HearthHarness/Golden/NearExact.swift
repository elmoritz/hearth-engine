import HearthEngine

/// Why a comparison could not be made or its evidence not kept.
public enum GoldenError: Error, Sendable, Equatable {
    case sizeMismatch(actualWidth: Int, actualHeight: Int, expectedWidth: Int, expectedHeight: Int)
    case artifactWriteFailed(String)
}

/// The near-exact tier of the golden-image method: analytic and same-configuration tests.
public struct NearExactTolerance: Sendable, Equatable {
    /// The per-channel difference almost every pixel must stay within.
    public var typicalDelta: Int
    /// How many pixels per thousand must stay within `typicalDelta`.
    public var typicalPerMille: Int
    /// The per-channel difference no pixel may exceed.
    public var maximumDelta: Int

    public init(typicalDelta: Int, typicalPerMille: Int, maximumDelta: Int) {
        self.typicalDelta = typicalDelta
        self.typicalPerMille = typicalPerMille
        self.maximumDelta = maximumDelta
    }

    /// The catalogue's rule: at most 2/255 on at least 99.9% of pixels and at most 8/255 on all.
    public static let catalogue = NearExactTolerance(typicalDelta: 2, typicalPerMille: 999, maximumDelta: 8)
    /// For analytic tests: no difference at all.
    public static let exact = NearExactTolerance(typicalDelta: 0, typicalPerMille: 1000, maximumDelta: 0)
}

public struct NearExactResult: Sendable, Equatable {
    public let pixelCount: Int
    /// Pixels with a channel further than `typicalDelta` from the expected one.
    public let pixelsOverTypical: Int
    /// The largest per-channel difference anywhere.
    public let maximumDelta: Int
    /// Where the largest difference is; the first such pixel in row order. `nil` when the images are equal.
    public let worstX: Int?
    public let worstY: Int?
    public let passed: Bool
}

public enum NearExact {
    public static func compare(
        _ actual: PixelImage,
        _ expected: PixelImage,
        tolerance: NearExactTolerance = .catalogue
    ) throws(GoldenError) -> NearExactResult {
        try requireSameSize(actual, expected)
        var over = 0
        var maximum = 0
        var worst: Int?
        let a = actual.bytes
        let e = expected.bytes
        for pixel in 0..<actual.pixelCount {
            var delta = 0
            for channel in 0..<4 {
                delta = max(delta, abs(Int(a[pixel * 4 + channel]) - Int(e[pixel * 4 + channel])))
            }
            if delta > tolerance.typicalDelta {
                over += 1
            }
            if delta > maximum {
                maximum = delta
                worst = pixel
            }
        }
        let within = actual.pixelCount - over
        let passed = maximum <= tolerance.maximumDelta
            && within * 1000 >= tolerance.typicalPerMille * actual.pixelCount
        return NearExactResult(
            pixelCount: actual.pixelCount, pixelsOverTypical: over, maximumDelta: maximum,
            worstX: worst.map { $0 % actual.width }, worstY: worst.map { $0 / actual.width }, passed: passed)
    }

    /// The per-pixel largest channel difference as a grey image, amplified 16 times so 2/255 is visible.
    public static func differenceMap(_ actual: PixelImage, _ expected: PixelImage) throws(GoldenError) -> PixelImage {
        try requireSameSize(actual, expected)
        var map = expected
        let a = actual.bytes
        let e = expected.bytes
        for pixel in 0..<actual.pixelCount {
            var delta = 0
            for channel in 0..<4 {
                delta = max(delta, abs(Int(a[pixel * 4 + channel]) - Int(e[pixel * 4 + channel])))
            }
            let grey = UInt8(min(255, delta * 16))
            map.set(x: pixel % actual.width, y: pixel / actual.width, to: RGBA8(grey, grey, grey))
        }
        return map
    }

    static func requireSameSize(_ actual: PixelImage, _ expected: PixelImage) throws(GoldenError) {
        guard actual.width == expected.width, actual.height == expected.height else {
            throw .sizeMismatch(
                actualWidth: actual.width, actualHeight: actual.height,
                expectedWidth: expected.width, expectedHeight: expected.height)
        }
    }
}
