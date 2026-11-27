import Foundation
import HearthEngine
import Testing

@testable import HearthHarness

/// `FLIP` against the NVlabs reference on real image pairs (E-GOLD-6). The reference ran outside the package
/// (`scripts/flip-reference.py`, in a virtual environment with the reference installed); only its numbers are here.
/// No GPU.
@Suite struct FLIPReferenceTests {
    /// The reference the numbers come from: `pip install flip-evaluator==1.7` (NVlabs/flip, `FLIP.h` underneath).
    static let referenceVersion = "flip-evaluator 1.7"
    /// The ticket's tolerance on the mean and on the 99th percentile.
    static let tolerance = 1e-3

    struct Pair {
        let name: String
        let actual: PixelImage
        let expected: PixelImage
    }

    /// One viewing condition and the reference's (mean, 99th percentile) per pair, in `pairs()` order.
    struct Condition {
        let name: String
        let pixelsPerDegree: Double
        let reference: [(mean: Double, percentile99: Double)]
    }

    /// `image` moved one pixel to the right, its first column repeated.
    static func shiftedRight(_ image: PixelImage) -> PixelImage {
        var out = image
        for y in 0..<image.height {
            for x in 0..<image.width {
                if let pixel = image[max(0, x - 1), y] {
                    out.set(x: x, y: y, to: pixel)
                }
            }
        }
        return out
    }

    /// The pairs `scripts/flip-reference.py` ran on, in its order.
    static func pairs() throws -> [Pair] {
        let ramp = try SyntheticCorpus.colourRamp(width: 64, height: 64)
        return [
            // Same ground colour, only the digit differs: the feature pipeline.
            Pair(
                name: "digits", actual: try SyntheticCorpus.numberedTile(7, projection: .orthogonal),
                expected: try SyntheticCorpus.numberedTile(1, projection: .orthogonal)),
            // Ground colour and digit, a non-square image with transparent corners.
            Pair(
                name: "tiles", actual: try SyntheticCorpus.numberedTile(1, projection: .diamond48x28),
                expected: try SyntheticCorpus.numberedTile(0, projection: .diamond48x28)),
            // Saturated colour error near the top of the scale.
            Pair(
                name: "ramp-grid", actual: try SyntheticCorpus.saturatedNeighbours(cell: 8, columns: 8, rows: 8),
                expected: ramp),
            // A gradient one pixel off: the low range where art-tier thresholds sit.
            Pair(name: "ramp-shift", actual: shiftedRight(ramp), expected: ramp),
        ]
    }

    /// What `scripts/flip-reference.py` printed for its images: (actual, expected) per pair.
    static let hashes: [(String, String)] = [
        ("65a06306a7ee2d4c0295ce11c882344babd6ecefb4f58ef1cadb65aad7ba19e8", "52732e2a380de228190766376c65847993a9a0900ea9c32cec78708aa68f8adf"),
        ("5a9ac7ff8e0e4a91f55529853daec2198a2549375d4c7a8ae00aa8c8795f21dc", "7bfd0d9724cf91b32c80abfbf7f7098e75597f00529e3cfb4edd54686e0a34ba"),
        ("52e22145d00e5b5ca239d37b8fb7e508c5be2864fb83bed202b2cd1a27e127ac", "4c6675eef755cc0b559991605d6fbb6a161407d65e7a59bebe9ec0604c27dd28"),
        ("1e038ccd5016dfb432dd56334f46b16ec2eefa07fd5fc585bd27147e34d555ee", "4c6675eef755cc0b559991605d6fbb6a161407d65e7a59bebe9ec0604c27dd28"),
    ]

    /// Pixels per degree of a screen seen from `distance` metres: FLIP's own conversion, small-angle,
    /// `ppd = distance * pixelsPerMetre * pi / 180`.
    static func phone(ppi: Double, distance: Double = 0.3) -> Double {
        FLIP.pixelsPerDegree(distanceMetres: distance, pixelsPerMetre: ppi / 0.0254)
    }

    /// The paper's monitor (the default), the D2 phone floor (iPhone 11 family, iPhone SE 2nd gen: 326 ppi) and the
    /// newest iPhone Pro (460 ppi), both at 0.3 m.
    static let conditions: [Condition] = [
        Condition(
            name: "paper monitor", pixelsPerDegree: FLIP.referencePixelsPerDegree,
            reference: [(0.100008, 0.923482), (0.599259, 0.972967), (0.946519, 0.994051), (0.091118, 0.130927)]),
        Condition(
            name: "326 ppi at 0.3 m", pixelsPerDegree: phone(ppi: 326),
            reference: [(0.100056, 0.922838), (0.599522, 0.972920), (0.946501, 0.994043), (0.091121, 0.130931)]),
        Condition(
            name: "460 ppi at 0.3 m", pixelsPerDegree: phone(ppi: 460),
            reference: [(0.103719, 0.792475), (0.634800, 0.969582), (0.939182, 0.992354), (0.091481, 0.133187)]),
    ]

    /// The one comparison every assertion goes through: both numbers within the tolerance; NaN never matches.
    static func matches(_ result: FLIPResult, mean: Double, percentile99: Double) -> Bool {
        abs(result.mean - mean) <= tolerance && abs(result.percentile99 - percentile99) <= tolerance
    }

    func check(_ condition: Condition) throws {
        let pairs = try Self.pairs()
        #expect(condition.reference.count == pairs.count)
        for (pair, reference) in zip(pairs, condition.reference) {
            for (actual, expected) in [(pair.actual, pair.expected), (pair.expected, pair.actual)] {
                let result = try FLIP.compare(actual, expected, pixelsPerDegree: condition.pixelsPerDegree)
                #expect(
                    Self.matches(result, mean: reference.mean, percentile99: reference.percentile99),
                    "\(pair.name) at \(condition.name): mean \(result.mean), p99 \(result.percentile99); \(Self.referenceVersion) says \(reference.mean), \(reference.percentile99)"
                )
            }
        }
    }

    @Test func `E-GOLD-6 the corpus pairs are the images the reference was run on`() throws {
        let pairs = try Self.pairs()
        #expect(pairs.map(\.name) == ["digits", "tiles", "ramp-grid", "ramp-shift"])
        #expect(pairs.count == Self.hashes.count)
        for (pair, hash) in zip(pairs, Self.hashes) {
            #expect(pair.actual.sha256 == hash.0, "\(pair.name) actual")
            #expect(pair.expected.sha256 == hash.1, "\(pair.name) expected")
            #expect(pair.actual.width == pair.expected.width && pair.actual.height == pair.expected.height)
        }
        // Non-square, with transparent corners the comparison reads as black; the shift repeats the first column.
        #expect(pairs[1].actual.width == 48 && pairs[1].actual.height == 28 && pairs[1].actual[0, 0] == .clear)
        #expect(pairs[3].actual[0, 5] == pairs[3].expected[0, 5] && pairs[3].actual[1, 5] == pairs[3].expected[0, 5])
        #expect(pairs[3].actual[63, 5] == pairs[3].expected[62, 5])
    }

    @Test func `E-GOLD-6 FLIP equals flip-evaluator 1.7 on four corpus pairs at the paper's viewing condition`() throws {
        #expect(Self.referenceVersion == "flip-evaluator 1.7")
        #expect(Self.tolerance == 1e-3)
        #expect(Self.conditions[0].pixelsPerDegree == FLIP.referencePixelsPerDegree)
        try check(Self.conditions[0])
    }

    @Test func `E-GOLD-6 FLIP equals flip-evaluator 1.7 on four corpus pairs on phone screens`() throws {
        // At 460 ppi the kernels are larger than at the default: a kernel-radius difference would show here.
        let pro = Self.conditions[2].pixelsPerDegree
        #expect(FLIP.spatialFilters(pro).radius == 13 && FLIP.featureDetectors(pro).radius == 12)
        try check(Self.conditions[1])
        try check(Self.conditions[2])
    }

    @Test func `E-GOLD-6 the comparison fails on a wrong viewing condition and at 1.1e-3`() throws {
        let pairs = try Self.pairs()
        let paper = Self.conditions[0], pro = Self.conditions[2]
        // Negative control: the same pairs at the wrong viewing condition (kernels about 40% wider) do not match.
        var mismatches = 0
        for (index, pair) in pairs.enumerated() {
            let atPro = try FLIP.compare(pair.actual, pair.expected, pixelsPerDegree: pro.pixelsPerDegree)
            let atPaper = try FLIP.compare(pair.actual, pair.expected, pixelsPerDegree: paper.pixelsPerDegree)
            if !Self.matches(atPro, mean: paper.reference[index].mean, percentile99: paper.reference[index].percentile99) {
                mismatches += 1
            }
            if !Self.matches(atPaper, mean: pro.reference[index].mean, percentile99: pro.reference[index].percentile99) {
                mismatches += 1
            }
        }
        #expect(mismatches == 2 * pairs.count)

        // The boundary: 0.9e-3 away matches, 1.1e-3 does not, in either direction, for each number on its own.
        let result = try FLIP.compare(pairs[0].actual, pairs[0].expected)
        for offset in [0.9e-3, -0.9e-3] {
            #expect(Self.matches(result, mean: result.mean + offset, percentile99: result.percentile99))
            #expect(Self.matches(result, mean: result.mean, percentile99: result.percentile99 + offset))
        }
        for offset in [1.1e-3, -1.1e-3] {
            #expect(!Self.matches(result, mean: result.mean + offset, percentile99: result.percentile99))
            #expect(!Self.matches(result, mean: result.mean, percentile99: result.percentile99 + offset))
        }
        #expect(!Self.matches(result, mean: .nan, percentile99: result.percentile99))
        #expect(!Self.matches(result, mean: result.mean, percentile99: .nan))
    }

    @Test func `E-GOLD-6 the phone floor at 30 cm is the default viewing condition`() throws {
        // The ticket's decision, recorded: D2's smallest phone density is 326 ppi (iPhone 11 family, iPhone SE 2nd
        // gen). At 0.3 m that is 0.3 * (326 / 0.0254) * pi / 180 = 67.20 pixels per degree; the default
        // (`referencePixelsPerDegree`, the paper's monitor) is 67.02. They differ by 0.27%, give the same kernel
        // radii, and score the stored pairs within the tolerance of each other, so the default stays. The newest
        // iPhone Pro (460 ppi) is 94.82 at 0.3 m.
        let floor = Self.phone(ppi: 326)
        #expect(abs(floor - 67.20) < 1e-2)
        #expect(abs(Self.phone(ppi: 460) - 94.82) < 1e-2)
        #expect(abs(floor / FLIP.referencePixelsPerDegree - 1) < 0.003)
        #expect(FLIP.spatialFilters(floor).radius == 10 && FLIP.spatialFilters(FLIP.referencePixelsPerDegree).radius == 10)
        #expect(FLIP.featureDetectors(floor).radius == 9 && FLIP.featureDetectors(FLIP.referencePixelsPerDegree).radius == 9)
        for (index, pair) in try Self.pairs().enumerated() {
            let reference = Self.conditions[0].reference[index]
            let result = try FLIP.compare(pair.actual, pair.expected, pixelsPerDegree: floor)
            #expect(Self.matches(result, mean: reference.mean, percentile99: reference.percentile99), "\(pair.name)")
        }
    }
}
