import Foundation
import HearthEngine

/// Which tier of the golden-image method judges a comparison.
public enum GoldenTier: Sendable, Equatable {
    /// Analytic and same-configuration tests.
    case nearExact(NearExactTolerance)
    /// Art-level and cross-configuration tests.
    case flip(FLIPThreshold, pixelsPerDegree: Double)
}

public struct GoldenOutcome: Sendable, Equatable {
    public let passed: Bool
    /// The measured values, for the failure message.
    public let summary: String
    /// The files written. Empty when the comparison passed.
    public let artifacts: [URL]
}

/// One golden comparison. A failure leaves the actual image, the expected one and the difference map (the FLIP
/// map on the FLIP tier) as PNG files in the directory the caller names; a pass writes nothing.
public enum GoldenCheck {
    public static func check(
        _ actual: PixelImage,
        against expected: PixelImage,
        tier: GoldenTier,
        name: String,
        artifactDirectory: URL
    ) throws(GoldenError) -> GoldenOutcome {
        let passed: Bool
        let summary: String
        let map: PixelImage
        let mapSuffix: String
        switch tier {
        case .nearExact(let tolerance):
            let result = try NearExact.compare(actual, expected, tolerance: tolerance)
            passed = result.passed
            summary = "near-exact: largest difference \(result.maximumDelta)/255, "
                + "\(result.pixelsOverTypical) of \(result.pixelCount) pixels over \(tolerance.typicalDelta)/255"
            map = try NearExact.differenceMap(actual, expected)
            mapSuffix = "diff"
        case .flip(let threshold, let pixelsPerDegree):
            let result = try FLIP.compare(actual, expected, pixelsPerDegree: pixelsPerDegree)
            passed = result.passes(threshold)
            summary = "FLIP: mean \(result.mean) (limit \(threshold.mean)), "
                + "99th percentile \(result.percentile99) (limit \(threshold.percentile99))"
            map = result.mapImage
            mapSuffix = "flip"
        }
        if passed {
            return GoldenOutcome(passed: true, summary: summary, artifacts: [])
        }
        let stem = fileStem(name)
        var written = [URL]()
        do {
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
            for (suffix, image) in [("actual", actual), ("expected", expected), (mapSuffix, map)] {
                let url = artifactDirectory.appendingPathComponent("\(stem).\(suffix).png")
                try Data(PNGEncoder.encode(image)).write(to: url)
                written.append(url)
            }
        } catch {
            throw .artifactWriteFailed("\(artifactDirectory.path): \(error.localizedDescription)")
        }
        return GoldenOutcome(passed: false, summary: summary, artifacts: written)
    }

    /// A file name made of the name's ASCII letters, digits, `-`, `_` and `.`; anything else becomes `-`.
    static func fileStem(_ name: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let kept = String(name.map { safe.contains($0) ? $0 : "-" })
        return kept.isEmpty ? "golden" : kept
    }
}
