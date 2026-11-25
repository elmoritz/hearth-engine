import Foundation
import HearthEngine
import Testing

@testable import HearthHarness

/// The two tiers of the golden-image method and the evidence a failure leaves. No GPU.
@Suite struct GoldenTests {
    /// A seeded noise image.
    static func noise(_ width: Int, _ height: Int, seed: UInt64) throws -> PixelImage {
        var random = SplitMix64(seed: seed)
        return try PixelImage(width: width, height: height, bytes: (0..<(width * height * 4)).map { _ in UInt8.random(in: 0...255, using: &random) })
    }

    /// `image` with `delta` added to the red channel of its first `count` pixels (values start low enough not to wrap).
    static func shifted(_ image: PixelImage, by delta: UInt8, count: Int) -> PixelImage {
        var out = image
        for pixel in 0..<count {
            let x = pixel % image.width, y = pixel / image.width
            if let old = image[x, y] {
                out.set(x: x, y: y, to: RGBA8(old.r + delta, old.g, old.b, old.a))
            }
        }
        return out
    }

    // MARK: E-GOLD-1

    @Test func `E-GOLD-1 equal images pass exactly and a delta of 2 passes near-exact`() throws {
        let base = try PixelImage(width: 40, height: 25, filledWith: RGBA8(100, 100, 100, 100))
        let equal = try NearExact.compare(base, base, tolerance: .exact)
        #expect(equal == NearExactResult(pixelCount: 1000, pixelsOverTypical: 0, maximumDelta: 0, worstX: nil, worstY: nil, passed: true))

        let near = Self.shifted(base, by: 2, count: 1000)
        #expect(try NearExact.compare(near, base).passed)
        #expect(try NearExact.compare(near, base, tolerance: .catalogue).maximumDelta == 2)
        #expect(try !NearExact.compare(near, base, tolerance: .exact).passed)
        #expect(NearExactTolerance.catalogue == NearExactTolerance(typicalDelta: 2, typicalPerMille: 999, maximumDelta: 8))
        #expect(NearExactTolerance.exact == NearExactTolerance(typicalDelta: 0, typicalPerMille: 1000, maximumDelta: 0))
    }

    @Test func `E-GOLD-1 one pixel off by 9 fails and more than 0.1 percent off by 3 fails`() throws {
        let base = try PixelImage(width: 40, height: 25, filledWith: RGBA8(100, 100, 100, 100))
        var spike = base
        spike.set(x: 7, y: 3, to: RGBA8(100, 100, 109, 100))
        let spiked = try NearExact.compare(spike, base)
        #expect(!spiked.passed)
        #expect(spiked.maximumDelta == 9 && spiked.worstX == 7 && spiked.worstY == 3 && spiked.pixelsOverTypical == 1)

        let drift = try NearExact.compare(Self.shifted(base, by: 3, count: 2), base)
        #expect(!drift.passed)
        #expect(drift.pixelsOverTypical == 2 && drift.maximumDelta == 3 && drift.worstX == 0 && drift.worstY == 0)
        // Every channel counts, alpha included, in both directions.
        for channel in 0..<4 {
            var bytes = base.bytes
            bytes[channel] = 91
            #expect(try NearExact.compare(PixelImage(width: 40, height: 25, bytes: bytes), base).maximumDelta == 9)
            #expect(try NearExact.compare(base, PixelImage(width: 40, height: 25, bytes: bytes)).maximumDelta == 9)
        }
    }

    @Test func `E-GOLD-1 images of different sizes throw`() throws {
        let a = try PixelImage(width: 4, height: 2, filledWith: .red)
        let b = try PixelImage(width: 2, height: 4, filledWith: .red)
        let c = try PixelImage(width: 4, height: 3, filledWith: .red)
        #expect(throws: GoldenError.sizeMismatch(actualWidth: 4, actualHeight: 2, expectedWidth: 2, expectedHeight: 4)) {
            try NearExact.compare(a, b)
        }
        #expect(throws: GoldenError.sizeMismatch(actualWidth: 4, actualHeight: 3, expectedWidth: 4, expectedHeight: 2)) {
            try NearExact.compare(c, a)
        }
        #expect(throws: GoldenError.sizeMismatch(actualWidth: 2, actualHeight: 4, expectedWidth: 4, expectedHeight: 2)) {
            try NearExact.differenceMap(b, a)
        }
        #expect(throws: GoldenError.sizeMismatch(actualWidth: 4, actualHeight: 2, expectedWidth: 4, expectedHeight: 3)) {
            try FLIP.compare(a, c)
        }
    }

    @Test func `E-GOLD-1 the boundaries of 2 and 8 and 99.9 percent`() throws {
        let base = try PixelImage(width: 40, height: 25, filledWith: RGBA8(100, 100, 100, 100))
        // Exactly one pixel in a thousand may exceed 2/255, as long as it stays within 8/255.
        #expect(try NearExact.compare(Self.shifted(base, by: 3, count: 1), base).passed)
        #expect(try NearExact.compare(Self.shifted(base, by: 8, count: 1), base).passed)
        #expect(try !NearExact.compare(Self.shifted(base, by: 9, count: 1), base).passed)
        #expect(try !NearExact.compare(Self.shifted(base, by: 3, count: 2), base).passed)
        // 2/255 is within the typical bound for every pixel; 3/255 on every pixel is not.
        #expect(try NearExact.compare(Self.shifted(base, by: 2, count: 1000), base).pixelsOverTypical == 0)
        #expect(try NearExact.compare(Self.shifted(base, by: 3, count: 1000), base).pixelsOverTypical == 1000)
        // A single pixel is all of its image: any typical excess is 100%.
        let one = try PixelImage(width: 1, height: 1, filledWith: RGBA8(100, 100, 100, 100))
        #expect(try NearExact.compare(Self.shifted(one, by: 2, count: 1), one).passed)
        #expect(try !NearExact.compare(Self.shifted(one, by: 3, count: 1), one).passed)
        // The exact tier has no slack at all.
        #expect(try !NearExact.compare(Self.shifted(base, by: 1, count: 1), base, tolerance: .exact).passed)

        let map = try NearExact.differenceMap(Self.shifted(base, by: 3, count: 1), base)
        #expect(map[0, 0] == RGBA8(48, 48, 48) && map[1, 0] == RGBA8(0, 0, 0) && map[39, 24] == RGBA8(0, 0, 0))
        #expect(try NearExact.differenceMap(Self.shifted(base, by: 16, count: 41), base)[0, 1] == RGBA8(255, 255, 255))
        #expect(try NearExact.differenceMap(Self.shifted(base, by: 15, count: 1), base)[0, 0] == RGBA8(240, 240, 240))
    }

    @Test func `E-GOLD-1 comparison is symmetric and reflexive over 1000 seeded images`() throws {
        var random = SplitMix64(seed: 0x4845_0003)
        for index in 0..<1000 {
            let width = Int.random(in: 1...6, using: &random), height = Int.random(in: 1...6, using: &random)
            let a = try Self.noise(width, height, seed: UInt64(index) * 2 + 1)
            var b = a
            for _ in 0..<Int.random(in: 0...3, using: &random) {
                let x = Int.random(in: 0..<width, using: &random), y = Int.random(in: 0..<height, using: &random)
                b.set(x: x, y: y, to: RGBA8(.random(in: 0...255, using: &random), 0, 0, 0))
            }
            let same = try NearExact.compare(a, a, tolerance: .exact)
            #expect(same.passed && same.maximumDelta == 0)
            let forward = try NearExact.compare(a, b), backward = try NearExact.compare(b, a)
            #expect(forward == backward)
            #expect(forward.pixelsOverTypical <= forward.pixelCount && (forward.maximumDelta == 0) == (a == b))
        }
    }

    // MARK: E-GOLD-2

    @Test func `E-GOLD-2 identical images score zero and green against blue scores one`() throws {
        let noise = try Self.noise(12, 9, seed: 7)
        let same = try FLIP.compare(noise, noise)
        #expect(same.mean == 0 && same.percentile99 == 0 && same.map.allSatisfy { $0 == 0 })
        #expect(same.passes(FLIPThreshold(mean: 0, percentile99: 0)))
        #expect(same.width == 12 && same.height == 9 && same.map.count == 108)
        #expect(same.mapImage == (try PixelImage(width: 12, height: 9, filledWith: .black)))

        // The paper normalises the colour error by its largest value: saturated green against saturated blue.
        let green = try PixelImage(width: 6, height: 5, filledWith: .green)
        let blue = try PixelImage(width: 6, height: 5, filledWith: .blue)
        let extreme = try FLIP.compare(green, blue)
        #expect(extreme.map.allSatisfy { abs($0 - 1) < 1e-6 })
        #expect(abs(extreme.mean - 1) < 1e-6 && abs(extreme.percentile99 - 1) < 1e-6)
        #expect(extreme.mapImage == (try PixelImage(width: 6, height: 5, filledWith: .white)))
        // The paper's viewing condition: 67 pixels per degree.
        #expect(abs(FLIP.referencePixelsPerDegree - 67.0206) < 1e-3)
        #expect(abs(FLIP.pixelsPerDegree(distanceMetres: 0.3, pixelsPerMetre: 460 / 0.0254) - 94.825) < 1e-2)
    }

    @Test func `E-GOLD-2 a visible change fails the mean and a local one fails the 99th percentile cap`() throws {
        let grey = try PixelImage(width: 24, height: 24, filledWith: RGBA8(120, 120, 120))
        // Everywhere a little: the mean moves, no pixel stands out.
        let global = try FLIP.compare(try PixelImage(width: 24, height: 24, filledWith: RGBA8(150, 120, 120)), grey)
        #expect(global.mean > 0.05 && abs(global.percentile99 - global.mean) < 1e-9)
        #expect(!global.passes(FLIPThreshold(mean: 0.05, percentile99: 1)))
        #expect(global.passes(FLIPThreshold(mean: global.mean, percentile99: global.percentile99)))

        // A small patch a lot: the mean stays low, the 99th percentile does not.
        var patched = grey
        for y in 10..<14 {
            for x in 10..<14 {
                patched.set(x: x, y: y, to: .red)
            }
        }
        let local = try FLIP.compare(patched, grey)
        #expect(local.mean < 0.1 && local.percentile99 > 0.4)
        #expect(!local.passes(FLIPThreshold(mean: 0.1, percentile99: 0.4)))
        #expect(!local.passes(FLIPThreshold(mean: local.mean / 2, percentile99: 1)))
        #expect(local.passes(FLIPThreshold(mean: 0.1, percentile99: 1)))
        // The map points at the patch.
        #expect(local.map[12 * 24 + 12] > 0.4 && local.map[0] < 0.01)
        #expect((local.mapImage[12, 12]?.r ?? 0) > 100 && local.mapImage[0, 0] == RGBA8(0, 0, 0))
    }

    @Test func `E-GOLD-2 the score is in range symmetric and grows with the error`() throws {
        let one = try FLIP.compare(try PixelImage(width: 1, height: 1, filledWith: .black), try PixelImage(width: 1, height: 1, filledWith: .white))
        #expect(one.map.count == 1 && one.mean == one.percentile99 && one.mean > 0.5 && one.mean <= 1)

        // A flat error grows with its size.
        let grey = try PixelImage(width: 8, height: 8, filledWith: RGBA8(100, 100, 100))
        var previous = 0.0
        for step in [4, 16, 48, 120] {
            let mean = try FLIP.compare(try PixelImage(width: 8, height: 8, filledWith: RGBA8(UInt8(100 + step), 100, 100)), grey).mean
            #expect(mean > previous)
            previous = mean
        }
        // Alpha is not part of the picture.
        #expect(try FLIP.compare(try PixelImage(width: 8, height: 8, filledWith: RGBA8(100, 100, 100, 0)), grey).mean == 0)

        // An edge that moves scores more than the same pixels changing inside a flat area would on colour alone,
        // and any pair of images scores the same in both directions, inside [0, 1].
        var random = SplitMix64(seed: 0x4845_0004)
        for index in 0..<40 {
            let width = Int.random(in: 1...9, using: &random), height = Int.random(in: 1...9, using: &random)
            let a = try Self.noise(width, height, seed: UInt64(index) + 100), b = try Self.noise(width, height, seed: UInt64(index) + 900)
            let forward = try FLIP.compare(a, b, pixelsPerDegree: 30), backward = try FLIP.compare(b, a, pixelsPerDegree: 30)
            #expect(forward.map.allSatisfy { $0 >= 0 && $0 <= 1 })
            #expect(zip(forward.map, backward.map).allSatisfy { abs($0 - $1) < 1e-9 })
            #expect(forward.percentile99 >= forward.mean * 0.999 && forward.percentile99 <= (forward.map.max() ?? 0))
        }
        // The nearest-rank percentile: with 200 values the 198th smallest.
        var ramp = try PixelImage(width: 200, height: 1, filledWith: RGBA8(100, 100, 100))
        ramp.set(x: 0, y: 0, to: .red)
        ramp.set(x: 199, y: 0, to: .red)
        let ranked = try FLIP.compare(ramp, try PixelImage(width: 200, height: 1, filledWith: RGBA8(100, 100, 100)), pixelsPerDegree: 10)
        #expect(ranked.percentile99 == ranked.map.sorted()[197])
    }

    @Test func `E-GOLD-2 the filters are normalised and the colour spaces invert`() {
        for pixelsPerDegree in [10.0, 30, FLIP.referencePixelsPerDegree] {
            let spatial = FLIP.spatialFilters(pixelsPerDegree)
            #expect(spatial.radius == Int((3 * (0.04 / (2 * Double.pi * Double.pi)).squareRoot() * pixelsPerDegree).rounded(.up)))
            for kernel in spatial.kernels {
                #expect(kernel.count == (2 * spatial.radius + 1) * (2 * spatial.radius + 1))
                #expect(abs(kernel.reduce(0, +) - 1) < 1e-12 && kernel.allSatisfy { $0 >= 0 })
                // The centre weighs most.
                #expect(kernel[kernel.count / 2] == kernel.max())
            }
            let detectors = FLIP.featureDetectors(pixelsPerDegree)
            #expect(detectors.radius == Int((3 * 0.5 * 0.082 * pixelsPerDegree).rounded(.up)))
            for kernel in [detectors.edge.x, detectors.edge.y, detectors.point.x, detectors.point.y] {
                #expect(abs(kernel.filter { $0 > 0 }.reduce(0, +) - 1) < 1e-12)
                #expect(abs(kernel.filter { $0 < 0 }.reduce(0, +) + 1) < 1e-12)
            }
            // The x and y detectors are transposes of each other.
            let side = 2 * detectors.radius + 1
            for y in 0..<side {
                for x in 0..<side {
                    #expect(abs(detectors.edge.x[y * side + x] - detectors.edge.y[x * side + y]) < 1e-12)
                    #expect(abs(detectors.point.x[y * side + x] - detectors.point.y[x * side + y]) < 1e-12)
                }
            }
        }
        // sRGB decoding, the matrix and its inverse, and CIELAB at its anchors.
        #expect(FLIP.linearFromSRGB[0] == 0 && FLIP.linearFromSRGB[255] == 1)
        #expect(abs(FLIP.linearFromSRGB[10] - 10.0 / 255 / 12.92) < 1e-15 && abs(FLIP.linearFromSRGB[128] - 0.2158605) < 1e-6)
        let identity = (0..<3).map { row in (0..<3).map { column in (0..<3).reduce(0.0) { $0 + FLIP.toXYZ[row][$1] * FLIP.fromXYZ[$1][column] } } }
        for row in 0..<3 {
            for column in 0..<3 {
                #expect(abs(identity[row][column] - (row == column ? 1 : 0)) < 1e-12)
            }
        }
        #expect(abs(FLIP.toXYZ[1][0] + FLIP.toXYZ[1][1] + FLIP.toXYZ[1][2] - 1) < 1e-12)
        let white = FLIP.lab(linear: (1, 1, 1)), black = FLIP.lab(linear: (0, 0, 0))
        #expect(abs(white.0 - 100) < 1e-9 && abs(white.1) < 1e-9 && abs(white.2) < 1e-9)
        #expect(abs(black.0) < 1e-9 && abs(black.1) < 1e-9 && abs(black.2) < 1e-9)
        let mid = FLIP.lab(linear: (0.18, 0.18, 0.18))
        #expect(abs(mid.0 - 49.496) < 1e-2)
        #expect(FLIP.hunt((50, 10, -20)) == (50, 0.01 * 50 * 10, 0.01 * 50 * -20))
        #expect(FLIP.hyab((50, 3, 4), (40, 0, 0)) == 15 && FLIP.hyab((40, 0, 0), (50, 3, 4)) == 15)
        // The redistribution is continuous at the knee and ends at 1.
        #expect(FLIP.redistribute(0, maximum: 10) == 0)
        #expect(abs(FLIP.redistribute(2, maximum: 10) - 0.475) < 1e-12)
        #expect(abs(FLIP.redistribute(4, maximum: 10) - 0.95) < 1e-12 && abs(FLIP.redistribute(3.999999, maximum: 10) - 0.95) < 1e-6)
        #expect(abs(FLIP.redistribute(7, maximum: 10) - 0.975) < 1e-12 && abs(FLIP.redistribute(10, maximum: 10) - 1) < 1e-12)
        let round = FLIP.clampedLinear(116 * 0.5 - 16, 500 * (0.25 - 0.5), 200 * (0.5 - 0.125))
        let direct = FLIP.multiply(FLIP.fromXYZ, (0.25 * FLIP.white[0], 0.5 * FLIP.white[1], 0.125 * FLIP.white[2]))
        #expect(abs(round.0 - min(1, max(0, direct.0))) < 1e-12 && abs(round.1 - min(1, max(0, direct.1))) < 1e-12 && abs(round.2 - min(1, max(0, direct.2))) < 1e-12)
        #expect(FLIP.clampedLinear(500, 0, 0) == (1, 1, 1) && FLIP.clampedLinear(-500, 0, 0) == (0, 0, 0))
        // A convolution with a normalised kernel leaves a flat plane flat, borders included, and blurs a spike.
        let flat = FLIP.convolve([Double](repeating: 3, count: 12), 4, 3, FLIP.spatialFilters(10).kernels[2], FLIP.spatialFilters(10).radius)
        #expect(flat.allSatisfy { abs($0 - 3) < 1e-12 })
        let box = [Double](repeating: 1.0 / 9, count: 9)
        var spike = [Double](repeating: 0, count: 25)
        spike[12] = 9
        let blurred = FLIP.convolve(spike, 5, 5, box, 1)
        #expect(blurred[12] == 1 && blurred[6] == 1 && blurred[18] == 1 && blurred[0] == 0 && blurred[13] == 1 && blurred[14] == 0)
        // Borders replicate: a spike in the corner is counted four times by the 3x3 box there.
        var corner = [Double](repeating: 0, count: 25)
        corner[0] = 9
        #expect(FLIP.convolve(corner, 5, 5, box, 1)[0] == 4 && FLIP.convolve(corner, 5, 5, box, 1)[1] == 2 && FLIP.convolve(corner, 5, 5, box, 1)[6] == 1)
        // An asymmetric kernel is applied as a correlation: weight (kx, ky) multiplies the pixel at that offset.
        var right = [Double](repeating: 0, count: 9)
        right[5] = 1
        #expect(FLIP.convolve([1, 2, 3, 4, 5, 6], 3, 2, right, 1) == [2, 3, 3, 5, 6, 6])
        var below = [Double](repeating: 0, count: 9)
        below[7] = 1
        #expect(FLIP.convolve([1, 2, 3, 4, 5, 6], 3, 2, below, 1) == [4, 5, 6, 4, 5, 6])
    }

    // MARK: E-GOLD-3

    static func artifactDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hearth-golden-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    }

    @Test func `E-GOLD-3 a passing check writes nothing`() throws {
        let directory = Self.artifactDirectory("pass")
        try? FileManager.default.removeItem(at: directory)
        let image = try Self.noise(6, 4, seed: 3)
        let exact = try GoldenCheck.check(image, against: image, tier: .nearExact(.exact), name: "pass", artifactDirectory: directory)
        #expect(exact.passed && exact.artifacts.isEmpty)
        #expect(exact.summary == "near-exact: largest difference 0/255, 0 of 24 pixels over 0/255")
        let flip = try GoldenCheck.check(image, against: image, tier: .flip(FLIPThreshold(mean: 0.01, percentile99: 0.05), pixelsPerDegree: 30), name: "pass", artifactDirectory: directory)
        #expect(flip.passed && flip.artifacts.isEmpty)
        #expect(flip.summary == "FLIP: mean 0.0 (limit 0.01), 99th percentile 0.0 (limit 0.05)")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func `E-GOLD-3 a failing check writes actual expected and the difference map`() throws {
        let directory = Self.artifactDirectory("fail")
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = try PixelImage(width: 6, height: 4, filledWith: RGBA8(100, 100, 100))
        var actual = expected
        actual.set(x: 2, y: 1, to: .red)

        let exact = try GoldenCheck.check(actual, against: expected, tier: .nearExact(.exact), name: "E-HAR-1 red quad/1x1", artifactDirectory: directory)
        #expect(!exact.passed)
        #expect(exact.summary == "near-exact: largest difference 155/255, 1 of 24 pixels over 0/255")
        #expect(exact.artifacts.map(\.lastPathComponent) == [
            "E-HAR-1-red-quad-1x1.actual.png", "E-HAR-1-red-quad-1x1.expected.png", "E-HAR-1-red-quad-1x1.diff.png",
        ])
        let written = try exact.artifacts.map { try PNGReader.decode([UInt8](Data(contentsOf: $0))) }
        #expect(written[0] == actual && written[1] == expected)
        #expect(written[2] == (try NearExact.differenceMap(actual, expected)))
        #expect(written[2][2, 1] == RGBA8(255, 255, 255) && written[2][0, 0] == RGBA8(0, 0, 0))

        let threshold = FLIPThreshold(mean: 0.001, percentile99: 0.01)
        let flip = try GoldenCheck.check(actual, against: expected, tier: .flip(threshold, pixelsPerDegree: 30), name: "art", artifactDirectory: directory)
        #expect(!flip.passed && flip.summary.hasPrefix("FLIP: mean 0.") && flip.summary.hasSuffix("(limit 0.01)"))
        #expect(flip.artifacts.map(\.lastPathComponent) == ["art.actual.png", "art.expected.png", "art.flip.png"])
        let map = try PNGReader.decode([UInt8](Data(contentsOf: flip.artifacts[2])))
        #expect(map == (try FLIP.compare(actual, expected, pixelsPerDegree: 30)).mapImage)
        #expect((map[2, 1]?.r ?? 0) > 100)

        #expect(GoldenCheck.fileStem("") == "golden")
        #expect(GoldenCheck.fileStem("aZ09-_.") == "aZ09-_.")
        #expect(GoldenCheck.fileStem("a/b c:\u{e9}") == "a-b-c--")
    }

    @Test func `E-GOLD-3 a directory that cannot be written is a typed error and size mismatches write nothing`() throws {
        let directory = Self.artifactDirectory("blocked")
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory)  // a file where the directory should be
        let expected = try PixelImage(width: 2, height: 2, filledWith: .black)
        let actual = try PixelImage(width: 2, height: 2, filledWith: .white)
        do {
            _ = try GoldenCheck.check(actual, against: expected, tier: .nearExact(.exact), name: "blocked", artifactDirectory: directory)
            Issue.record("writing into a file must fail")
        } catch GoldenError.artifactWriteFailed(let message) {
            #expect(message.hasPrefix(directory.path + ": "))
        }
        let other = Self.artifactDirectory("mismatch")
        let wide = try PixelImage(width: 3, height: 2, filledWith: .black)
        for tier in [GoldenTier.nearExact(.catalogue), .flip(FLIPThreshold(mean: 1, percentile99: 1), pixelsPerDegree: 30)] {
            #expect(throws: GoldenError.sizeMismatch(actualWidth: 3, actualHeight: 2, expectedWidth: 2, expectedHeight: 2)) {
                try GoldenCheck.check(wide, against: expected, tier: tier, name: "mismatch", artifactDirectory: other)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func `E-GOLD-3 the PNG encoder is exact and deterministic`() throws {
        #expect(PNGEncoder.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(PNGEncoder.crc32([]) == 0)
        #expect(PNGEncoder.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(PNGEncoder.adler32([]) == 1)
        #expect(PNGEncoder.bigEndian(0x0102_0304) == [1, 2, 3, 4])
        #expect(PNGEncoder.chunk("IEND", []) == [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])

        // The smallest image, byte for byte.
        let pixel = try PixelImage(width: 1, height: 1, bytes: [10, 20, 30, 40])
        let smallest = PNGEncoder.encode(pixel)
        #expect(Array(smallest[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(Array(smallest[8..<29]) == [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])
        // zlib header, one final stored block of 5 bytes (filter byte and one pixel), then Adler-32.
        #expect(Array(smallest[41..<53]) == [0x78, 0x01, 1, 5, 0, 0xFA, 0xFF, 0, 10, 20, 30, 40])
        #expect(try PNGReader.decode(smallest) == pixel)

        // Odd sizes, and rows that cross the 65535-byte limit of a stored block (a 16384-wide row is 65537 bytes).
        for (width, height, seed) in [(3, 5, 1), (257, 129, 2), (16384, 1, 3), (16384, 3, 4), (13107, 5, 5)] {
            let image = try Self.noise(width, height, seed: UInt64(seed))
            let png = PNGEncoder.encode(image)
            #expect(png == PNGEncoder.encode(image))
            #expect(try PNGReader.decode(png) == image)
        }
        // Block boundaries: just under one block, two bytes over, and four full blocks plus five bytes.
        let exact = try Self.noise(16383, 1, seed: 6)
        #expect(try PNGReader.blockLengths(PNGEncoder.encode(exact)) == [65533])
        #expect(try PNGReader.blockLengths(PNGEncoder.encode(try Self.noise(16384, 1, seed: 7))) == [65535, 2])
        #expect(try PNGReader.blockLengths(PNGEncoder.encode(try Self.noise(13107, 5, seed: 8))) == [65535, 65535, 65535, 65535, 5])
    }
}

/// A reader for exactly what `PNGEncoder` writes, strict about every checksum: the test's independent check.
enum PNGReader {
    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    static func chunks(_ png: [UInt8]) throws -> [(type: String, payload: [UInt8])] {
        guard png.count >= 8, Array(png[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { throw Malformed(description: "signature") }
        var out = [(String, [UInt8])]()
        var offset = 8
        while offset < png.count {
            guard offset + 12 <= png.count else { throw Malformed(description: "truncated chunk") }
            let length = Int(png[offset]) << 24 | Int(png[offset + 1]) << 16 | Int(png[offset + 2]) << 8 | Int(png[offset + 3])
            guard offset + 12 + length <= png.count else { throw Malformed(description: "chunk length") }
            let body = Array(png[(offset + 4)..<(offset + 8 + length)])
            let crc = Array(png[(offset + 8 + length)..<(offset + 12 + length)])
            guard crc == PNGReader.bigEndian(PNGReader.crc32(body)) else { throw Malformed(description: "crc") }
            out.append((String(decoding: body[0..<4], as: UTF8.self), Array(body[4...])))
            offset += 12 + length
        }
        return out
    }

    /// The lengths of the stored deflate blocks, and the bytes they hold.
    static func inflateStored(_ data: [UInt8]) throws -> (lengths: [Int], raw: [UInt8]) {
        guard data.count >= 6, data[0] == 0x78, data[1] == 0x01 else { throw Malformed(description: "zlib header") }
        var raw = [UInt8](), lengths = [Int]()
        var offset = 2
        var last = false
        while !last {
            guard offset + 5 <= data.count else { throw Malformed(description: "truncated block") }
            guard data[offset] <= 1 else { throw Malformed(description: "not a stored block") }
            last = data[offset] == 1
            let length = Int(data[offset + 1]) | Int(data[offset + 2]) << 8
            let inverse = Int(data[offset + 3]) | Int(data[offset + 4]) << 8
            guard length ^ inverse == 0xFFFF, offset + 5 + length <= data.count else { throw Malformed(description: "block length") }
            raw += data[(offset + 5)..<(offset + 5 + length)]
            lengths.append(length)
            offset += 5 + length
        }
        guard offset + 4 == data.count else { throw Malformed(description: "trailing bytes") }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        guard Array(data[offset...]) == bigEndian(b << 16 | a) else { throw Malformed(description: "adler") }
        return (lengths, raw)
    }

    static func blockLengths(_ png: [UInt8]) throws -> [Int] {
        let parts = try chunks(png)
        return try inflateStored(parts[1].payload).lengths
    }

    static func decode(_ png: [UInt8]) throws -> PixelImage {
        let parts = try chunks(png)
        guard parts.map(\.type) == ["IHDR", "IDAT", "IEND"], parts[0].payload.count == 13, parts[2].payload.isEmpty else {
            throw Malformed(description: "chunks")
        }
        let header = parts[0].payload
        guard Array(header[8...]) == [8, 6, 0, 0, 0] else { throw Malformed(description: "header") }
        let width = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        let height = Int(header[4]) << 24 | Int(header[5]) << 16 | Int(header[6]) << 8 | Int(header[7])
        let raw = try inflateStored(parts[1].payload).raw
        guard raw.count == height * (width * 4 + 1) else { throw Malformed(description: "scanlines") }
        var bytes = [UInt8]()
        for row in 0..<height {
            let start = row * (width * 4 + 1)
            guard raw[start] == 0 else { throw Malformed(description: "filter") }
            bytes += raw[(start + 1)..<(start + 1 + width * 4)]
        }
        return try PixelImage(width: width, height: height, bytes: bytes)
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    /// The table-driven form, written independently of the encoder's bitwise one.
    static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
