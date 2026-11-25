import Foundation
import HearthEngine

/// The thresholds of the art-level tier: the mean FLIP error and a cap on its 99th percentile.
public struct FLIPThreshold: Sendable, Equatable {
    public var mean: Double
    public var percentile99: Double

    public init(mean: Double, percentile99: Double) {
        self.mean = mean
        self.percentile99 = percentile99
    }
}

public struct FLIPResult: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// The error per pixel, in `[0, 1]`, row-major.
    public let map: [Double]
    public let mean: Double
    /// Nearest-rank 99th percentile of `map`.
    public let percentile99: Double
    /// `map` as a grey image: the artifact kept on failure.
    public let mapImage: PixelImage

    public func passes(_ threshold: FLIPThreshold) -> Bool {
        mean <= threshold.mean && percentile99 <= threshold.percentile99
    }
}

/// LDR-FLIP (Andersson et al., "FLIP: A Difference Evaluator for Alternating Images", 2020), implemented from the
/// paper: a contrast-sensitivity filter in an opponent space, a Hunt-adjusted HyAB colour difference, and an edge
/// and point feature difference that amplifies it.
///
/// The RGB channels are read as sRGB display values; alpha is ignored. Borders replicate the edge pixel.
public enum FLIP {
    /// The viewing condition of the paper: a 0.7 m wide, 3840 px monitor seen from 0.7 m.
    public static let referencePixelsPerDegree = pixelsPerDegree(distanceMetres: 0.7, pixelsPerMetre: 3840 / 0.7)

    public static func pixelsPerDegree(distanceMetres: Double, pixelsPerMetre: Double) -> Double {
        distanceMetres * pixelsPerMetre * Double.pi / 180
    }

    public static func compare(
        _ actual: PixelImage,
        _ expected: PixelImage,
        pixelsPerDegree: Double = referencePixelsPerDegree
    ) throws(GoldenError) -> FLIPResult {
        try NearExact.requireSameSize(actual, expected)
        let width = actual.width
        let height = actual.height
        let count = actual.pixelCount
        let reference = opponent(expected)
        let test = opponent(actual)

        // Colour pipeline.
        let filters = spatialFilters(pixelsPerDegree)
        var filteredReference = [[Double]]()
        var filteredTest = [[Double]]()
        for channel in 0..<3 {
            filteredReference.append(
                convolve(reference[channel], width, height, filters.kernels[channel], filters.radius))
            filteredTest.append(convolve(test[channel], width, height, filters.kernels[channel], filters.radius))
        }
        let maximum = pow(hyab(hunt(lab(linear: (0, 1, 0))), hunt(lab(linear: (0, 0, 1)))), colourExponent)
        var colour = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let r = hunt(lab(linear: clampedLinear(filteredReference[0][i], filteredReference[1][i], filteredReference[2][i])))
            let t = hunt(lab(linear: clampedLinear(filteredTest[0][i], filteredTest[1][i], filteredTest[2][i])))
            colour[i] = redistribute(pow(hyab(r, t), colourExponent), maximum: maximum)
        }

        // Feature pipeline, on the unfiltered achromatic channel scaled to [0, 1].
        let detectors = featureDetectors(pixelsPerDegree)
        let referenceLuma = reference[0].map { ($0 + 16) / 116 }
        let testLuma = test[0].map { ($0 + 16) / 116 }
        func magnitude(_ luma: [Double], _ kernels: (x: [Double], y: [Double])) -> [Double] {
            let dx = convolve(luma, width, height, kernels.x, detectors.radius)
            let dy = convolve(luma, width, height, kernels.y, detectors.radius)
            return (0..<count).map { (dx[$0] * dx[$0] + dy[$0] * dy[$0]).squareRoot() }
        }
        let referenceEdges = magnitude(referenceLuma, detectors.edge)
        let testEdges = magnitude(testLuma, detectors.edge)
        let referencePoints = magnitude(referenceLuma, detectors.point)
        let testPoints = magnitude(testLuma, detectors.point)

        var map = [Double](repeating: 0, count: count)
        var image = expected
        for i in 0..<count {
            let difference = max(abs(referenceEdges[i] - testEdges[i]), abs(referencePoints[i] - testPoints[i]))
            let feature = min(1, pow(difference / 2.0.squareRoot(), featureExponent))
            let error = min(1, max(0, pow(colour[i], 1 - feature)))
            map[i] = error
            let grey = UInt8((error * 255).rounded())
            image.set(x: i % width, y: i / width, to: RGBA8(grey, grey, grey))
        }
        let sorted = map.sorted()
        let rank = (count * 99 + 99) / 100  // nearest rank: the smallest value with 99% of the values at or below it
        return FLIPResult(
            width: width, height: height, map: map, mean: map.reduce(0, +) / Double(count),
            percentile99: sorted[max(0, rank - 1)], mapImage: image)
    }

    // MARK: Constants of the paper

    static let colourExponent = 0.7
    static let featureExponent = 0.5
    static let colourKnee = 0.4
    static let colourKneeTarget = 0.95
    static let featureWidthDegrees = 0.082

    // MARK: Colour spaces

    /// Linear RGB to CIE XYZ (D65), the matrix of the reference implementation.
    static let toXYZ: [[Double]] = [
        [10_135_552.0 / 24_577_794.0, 8_788_810.0 / 24_577_794.0, 4_435_075.0 / 24_577_794.0],
        [2_613_072.0 / 12_288_897.0, 8_788_810.0 / 12_288_897.0, 887_015.0 / 12_288_897.0],
        [1_425_312.0 / 73_733_382.0, 8_788_810.0 / 73_733_382.0, 70_074_185.0 / 73_733_382.0],
    ]
    static let fromXYZ: [[Double]] = inverse(toXYZ)
    /// XYZ of linear white: what every XYZ value is normalised by.
    static let white: [Double] = toXYZ.map { $0[0] + $0[1] + $0[2] }
    static let linearFromSRGB: [Double] = (0..<256).map { value in
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func inverse(_ m: [[Double]]) -> [[Double]] {
        let a = m[0][0], b = m[0][1], c = m[0][2]
        let d = m[1][0], e = m[1][1], f = m[1][2]
        let g = m[2][0], h = m[2][1], i = m[2][2]
        let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [
            [(e * i - f * h) / determinant, (c * h - b * i) / determinant, (b * f - c * e) / determinant],
            [(f * g - d * i) / determinant, (a * i - c * g) / determinant, (c * d - a * f) / determinant],
            [(d * h - e * g) / determinant, (b * g - a * h) / determinant, (a * e - b * d) / determinant],
        ]
    }

    static func multiply(_ m: [[Double]], _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (
            m[0][0] * v.0 + m[0][1] * v.1 + m[0][2] * v.2,
            m[1][0] * v.0 + m[1][1] * v.1 + m[1][2] * v.2,
            m[2][0] * v.0 + m[2][1] * v.1 + m[2][2] * v.2
        )
    }

    /// The image as three planes of the opponent space YCxCz.
    static func opponent(_ image: PixelImage) -> [[Double]] {
        var planes = [[Double]](repeating: [Double](repeating: 0, count: image.pixelCount), count: 3)
        let bytes = image.bytes
        for i in 0..<image.pixelCount {
            let xyz = multiply(
                toXYZ,
                (linearFromSRGB[Int(bytes[i * 4])], linearFromSRGB[Int(bytes[i * 4 + 1])], linearFromSRGB[Int(bytes[i * 4 + 2])]))
            let x = xyz.0 / white[0], y = xyz.1 / white[1], z = xyz.2 / white[2]
            planes[0][i] = 116 * y - 16
            planes[1][i] = 500 * (x - y)
            planes[2][i] = 200 * (y - z)
        }
        return planes
    }

    /// One YCxCz value back in linear RGB, clamped to `[0, 1]`.
    static func clampedLinear(_ luma: Double, _ cx: Double, _ cz: Double) -> (Double, Double, Double) {
        let y = (luma + 16) / 116
        let x = cx / 500 + y
        let z = y - cz / 200
        let rgb = multiply(fromXYZ, (x * white[0], y * white[1], z * white[2]))
        return (min(1, max(0, rgb.0)), min(1, max(0, rgb.1)), min(1, max(0, rgb.2)))
    }

    static func lab(linear rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let xyz = multiply(toXYZ, rgb)
        func f(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            return t > delta * delta * delta ? cbrt(t) : t / (3 * delta * delta) + 4.0 / 29.0
        }
        let x = f(xyz.0 / white[0]), y = f(xyz.1 / white[1]), z = f(xyz.2 / white[2])
        return (116 * y - 16, 500 * (x - y), 200 * (y - z))
    }

    /// The Hunt effect: chroma scales with lightness.
    static func hunt(_ lab: (Double, Double, Double)) -> (Double, Double, Double) {
        (lab.0, 0.01 * lab.0 * lab.1, 0.01 * lab.0 * lab.2)
    }

    static func hyab(_ p: (Double, Double, Double), _ q: (Double, Double, Double)) -> Double {
        let da = p.1 - q.1
        let db = p.2 - q.2
        return abs(p.0 - q.0) + (da * da + db * db).squareRoot()
    }

    /// Maps `[0, maximum]` to `[0, 1]`, giving most of the range to the errors below the knee.
    static func redistribute(_ error: Double, maximum: Double) -> Double {
        let knee = colourKnee * maximum
        if error < knee {
            return colourKneeTarget / knee * error
        }
        return colourKneeTarget + (error - knee) / (maximum - knee) * (1 - colourKneeTarget)
    }

    // MARK: Filters

    /// The contrast sensitivity functions as normalised kernels: achromatic, red-green, blue-yellow.
    static func spatialFilters(_ pixelsPerDegree: Double) -> (kernels: [[Double]], radius: Int) {
        // (a1, b1, a2, b2) per channel.
        let parameters: [(Double, Double, Double, Double)] = [
            (1, 0.0047, 0, 1e-5), (1, 0.0053, 0, 1e-5), (34.1, 0.04, 13.5, 0.025),
        ]
        let radius = Int((3 * (0.04 / (2 * Double.pi * Double.pi)).squareRoot() * pixelsPerDegree).rounded(.up))
        let side = 2 * radius + 1
        var kernels = [[Double]]()
        for (a1, b1, a2, b2) in parameters {
            var kernel = [Double](repeating: 0, count: side * side)
            var sum = 0.0
            for y in -radius...radius {
                for x in -radius...radius {
                    let d2 = Double(x * x + y * y) / (pixelsPerDegree * pixelsPerDegree)
                    let value = a1 * (Double.pi / b1).squareRoot() * exp(-Double.pi * Double.pi * d2 / b1)
                        + a2 * (Double.pi / b2).squareRoot() * exp(-Double.pi * Double.pi * d2 / b2)
                    kernel[(y + radius) * side + x + radius] = value
                    sum += value
                }
            }
            kernels.append(kernel.map { $0 / sum })
        }
        return (kernels, radius)
    }

    /// First (edge) and second (point) derivatives of a Gaussian, in x and in y. In each kernel the positive
    /// weights sum to 1 and the negative ones to -1.
    static func featureDetectors(
        _ pixelsPerDegree: Double
    ) -> (edge: (x: [Double], y: [Double]), point: (x: [Double], y: [Double]), radius: Int) {
        let deviation = 0.5 * featureWidthDegrees * pixelsPerDegree
        let radius = Int((3 * deviation).rounded(.up))
        let side = 2 * radius + 1
        func kernel(_ weight: (Double, Double) -> Double) -> [Double] {
            var values = [Double](repeating: 0, count: side * side)
            var positive = 0.0
            var negative = 0.0
            for y in -radius...radius {
                for x in -radius...radius {
                    let gauss = exp(-Double(x * x + y * y) / (2 * deviation * deviation))
                    let value = weight(Double(x), Double(y)) * gauss
                    values[(y + radius) * side + x + radius] = value
                    if value > 0 {
                        positive += value
                    } else {
                        negative -= value
                    }
                }
            }
            return values.map { $0 > 0 ? $0 / positive : ($0 < 0 ? $0 / negative : 0) }
        }
        let variance = deviation * deviation
        return (
            edge: (kernel { x, _ in -x }, kernel { _, y in -y }),
            point: (kernel { x, _ in x * x / variance - 1 }, kernel { _, y in y * y / variance - 1 }),
            radius: radius
        )
    }

    static func convolve(_ plane: [Double], _ width: Int, _ height: Int, _ kernel: [Double], _ radius: Int) -> [Double] {
        let side = 2 * radius + 1
        var out = [Double](repeating: 0, count: plane.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                for ky in -radius...radius {
                    let row = min(height - 1, max(0, y + ky)) * width
                    let kernelRow = (ky + radius) * side + radius
                    for kx in -radius...radius {
                        sum += plane[row + min(width - 1, max(0, x + kx))] * kernel[kernelRow + kx]
                    }
                }
                out[y * width + x] = sum
            }
        }
        return out
    }
}
