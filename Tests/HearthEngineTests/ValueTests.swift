import HearthHarness
import Testing

@testable import HearthEngine

/// Pure values: time, images, errors and the frame plan. No GPU.
@Suite struct ValueTests {
    // MARK: E-HAR-2, time as a value

    @Test func `E-HAR-2 time zero negative huge and non-finite give a phase in range`() {
        #expect(EngineTime.zero.phase(period: 4) == 0)
        #expect(EngineTime(seconds: -0.0).phase(period: 4) == 0)
        #expect(EngineTime(seconds: 1).phase(period: 4) == 0.25)
        #expect(EngineTime(seconds: -1).phase(period: 4) == 0.75)
        #expect(EngineTime(seconds: 4).phase(period: 4) == 0)
        #expect(EngineTime(seconds: -4).phase(period: 4) == 0)
        #expect(EngineTime(seconds: 1e12 + 1).phase(period: 4) == 0.25)
        #expect(EngineTime(seconds: -1e-20).phase(period: 1) == 0)
        for seconds in [Double.nan, .infinity, -.infinity] {
            #expect(EngineTime(seconds: seconds).phase(period: 4) == 0)
        }
        for period in [0, -4, Double.nan, .infinity] {
            #expect(EngineTime(seconds: 1).phase(period: period) == 0)
        }
        #expect(EngineTime(seconds: 1) < EngineTime(seconds: 2))
        #expect(!(EngineTime(seconds: 2) < EngineTime(seconds: 2)))
    }

    @Test func `E-HAR-2 phase is periodic bounded and monotonic over 1000 seeded cases`() {
        var random = SplitMix64(seed: 0x4845_0001)
        for _ in 0..<1000 {
            let period = Double.random(in: 0.25...64, using: &random)
            let seconds = Double.random(in: -86_400...2_592_000, using: &random)
            let phase = EngineTime(seconds: seconds).phase(period: period)
            #expect(phase >= 0 && phase < 1)

            // A whole number of periods later the phase is the same, up to the rounding of the shift itself.
            let shifted = EngineTime(seconds: seconds + period * 3).phase(period: period)
            let distance = abs(shifted - phase)
            #expect(min(distance, 1 - distance) < 1e-6)

            // Inside one period the phase grows with time.
            let start = Double.random(in: 0..<0.5, using: &random) * period
            let step = Double.random(in: 0.01..<0.49, using: &random) * period
            #expect(EngineTime(seconds: start).phase(period: period) < EngineTime(seconds: start + step).phase(period: period))
        }
    }

    // MARK: E-HAR-4, pure rows

    @Test func `E-HAR-4 a malformed image header throws malformedAssetHeader`() {
        let cases: [(Int, Int, Int)] = [
            (0, 4, 0), (4, 0, 0), (-1, 4, 16), (4, -1, 16), (16385, 1, 65540), (1, 16385, 65540), (2, 2, 15), (2, 2, 17), (2, 2, 0),
        ]
        for (width, height, count) in cases {
            #expect(throws: EngineError.malformedAssetHeader(width: width, height: height, byteCount: count)) {
                try PixelImage(width: width, height: height, bytes: [UInt8](repeating: 0, count: count))
            }
        }
        for (width, height) in [(0, 1), (1, 0), (-3, 1), (1, -3), (16385, 1), (1, 16385)] {
            #expect(throws: EngineError.malformedAssetHeader(width: width, height: height, byteCount: 0)) {
                try PixelImage(width: width, height: height, filledWith: .red)
            }
        }
    }

    @Test func `E-HAR-4 image headers at the boundary are accepted`() throws {
        #expect(try PixelImage(width: 1, height: 1, bytes: [1, 2, 3, 4])[0, 0] == RGBA8(1, 2, 3, 4))
        #expect(try PixelImage(width: 16384, height: 1, filledWith: .red).pixelCount == 16384)
        #expect(try PixelImage(width: 1, height: 16384, filledWith: .red)[0, 16383] == .red)
        #expect(try PixelImage(width: 16384, height: 1, bytes: [UInt8](repeating: 7, count: 65536)).bytes.count == 65536)

        var image = try PixelImage(width: 3, height: 2, filledWith: RGBA8(9, 8, 7, 6))
        #expect(image.bytes == (0..<6).flatMap { _ in [UInt8(9), 8, 7, 6] })
        let inside = image.set(x: 2, y: 1, to: .blue)
        #expect(inside)
        #expect(image[2, 1] == .blue)
        #expect(image[1, 1] == RGBA8(9, 8, 7, 6))
        #expect(image.bytes[20...] == [0, 0, 255, 255])
        for (x, y) in [(-1, 0), (0, -1), (3, 0), (0, 2)] {
            #expect(image[x, y] == nil)
            let outside = image.set(x: x, y: y, to: .red)
            #expect(!outside)
        }
        #expect(image[0, 0] == RGBA8(9, 8, 7, 6))
        #expect(RGBA8(1, 2, 3).a == 255)
    }

    @Test func `E-HAR-4 every error describes itself`() {
        let errors: [EngineError] = [
            .noDevice, .missingTexture("grass"), .malformedAssetHeader(width: 2, height: 3, byteCount: 5),
            .unsupportedFormat(.rgba16Float), .invalidTargetSize(width: 0, height: 9), .invalidQuad(index: 7),
            .gpuFailure("render target"), .opaqueAfterBlended(index: 3),
            .textureTooLarge(width: 9000, height: 2, limit: 8192),
        ]
        #expect(errors.map(\.description) == [
            "no Metal device", "missing texture 'grass'", "malformed asset header: 2x3 with 5 bytes",
            "unsupported format rgba16Float", "invalid target size 0x9", "quad 7 has a rectangle that is not finite",
            "GPU failure: render target", "quad 3 is opaque but follows a blended quad",
            "texture 9000x2 exceeds this device's limit of 8192",
        ])
    }

    @Test func `E-HAR-4 a missing GPU object throws gpuFailure`() throws {
        struct Refused: Error {}
        #expect(throws: EngineError.gpuFailure("sampler: the device returned nothing")) {
            let _: Int = try requireGPU("sampler") { nil }
        }
        #expect(throws: EngineError.gpuFailure("pipeline: Refused()")) {
            let _: Int = try requireGPU("pipeline") { throw Refused() }
        }
        #expect(try requireGPU("buffer") { 42 } == 42)
    }

    @Test func `E-HAR-4 an unsupported format throws unsupportedFormat`() {
        #expect(PixelFormat.allCases.filter(\.isEightBit) == [.rgba8Unorm, .bgra8Unorm])
        #expect(throws: EngineError.unsupportedFormat(.rgba16Float)) {
            try FramePlan(frame: FrameDescription(), target: RenderTarget(width: 4, height: 4, format: .rgba16Float), options: RenderOptions()) { _ in true }
        }
        #expect(PixelFormat.rgba8Unorm.metal == .rgba8Unorm)
        #expect(PixelFormat.bgra8Unorm.metal == .bgra8Unorm)
        #expect(PixelFormat.rgba16Float.metal == .rgba16Float)
    }

    @Test func `E-HAR-4 a missing texture throws missingTexture`() throws {
        let frame = FrameDescription(quads: [
            Quad(x: 0, y: 0, width: 1, height: 1, texture: "held"), Quad(x: 1, y: 0, width: 1, height: 1, texture: "absent"),
        ])
        let target = RenderTarget(width: 4, height: 4)
        #expect(throws: EngineError.missingTexture("absent")) {
            try FramePlan(frame: frame, target: target, options: RenderOptions()) { $0 == "held" }
        }
        #expect(RenderOptions().missingTexture == .throwError)
        let plan = try FramePlan(frame: frame, target: target, options: RenderOptions(missingTexture: .fallback)) { $0 == "held" }
        #expect(plan.draws == [
            FramePlan.Draw(firstVertex: 0, source: .texture("held"), blend: .opaque), FramePlan.Draw(firstVertex: 6, source: .color(.magenta), blend: .opaque),
        ])
        #expect(TextureID("held") == "held")
    }

    // MARK: E-HAR-1, the plan

    @Test func `E-HAR-1 a target of size zero or past the maximum throws invalidTargetSize`() throws {
        for (width, height) in [(0, 4), (4, 0), (-1, 4), (4, -1), (16385, 4), (4, 16385)] {
            #expect(throws: EngineError.invalidTargetSize(width: width, height: height)) {
                try FramePlan(frame: FrameDescription(), target: RenderTarget(width: width, height: height), options: RenderOptions()) { _ in true }
            }
        }
        for (width, height) in [(1, 1), (16384, 16384)] {
            let plan = try FramePlan(frame: FrameDescription(clearColor: .red), target: RenderTarget(width: width, height: height), options: RenderOptions()) { _ in true }
            #expect(plan.clearColor == .red)
            #expect(plan.draws.isEmpty && plan.vertices.isEmpty)
        }
    }

    @Test func `E-HAR-1 a non-finite quad throws invalidQuad with its index`() throws {
        let target = RenderTarget(width: 8, height: 8)
        let bad: [Float] = [.nan, .infinity, -.infinity]
        for value in bad {
            for field in 0..<4 {
                var rect = PixelRect(x: 1, y: 1, width: 1, height: 1)
                switch field {
                case 0: rect.x = value
                case 1: rect.y = value
                case 2: rect.width = value
                default: rect.height = value
                }
                let frame = FrameDescription(quads: [Quad(x: 0, y: 0, width: 1, height: 1, color: .red), Quad(rect: rect, fill: .color(.red))])
                #expect(throws: EngineError.invalidQuad(index: 1)) {
                    try FramePlan(frame: frame, target: target, options: RenderOptions()) { _ in true }
                }
            }
        }
        // Finite fields whose far edge overflows are refused as well.
        let overflow = FrameDescription(quads: [Quad(x: .greatestFiniteMagnitude, y: 0, width: .greatestFiniteMagnitude, height: 1, color: .red)])
        #expect(throws: EngineError.invalidQuad(index: 0)) {
            try FramePlan(frame: overflow, target: target, options: RenderOptions()) { _ in true }
        }
    }

    @Test func `E-HAR-1 the plan holds six vertices per visible quad in draw order`() throws {
        let frame = FrameDescription(quads: [
            Quad(x: 1, y: 2, width: 3, height: 4, color: .red),
            Quad(x: 0, y: 0, width: 0, height: 4, color: .green),
            Quad(x: 0, y: 0, width: 4, height: 0, color: .green),
            Quad(x: 0, y: 0, width: -1, height: 4, color: .green),
            Quad(x: 0, y: 0, width: 4, height: -1, texture: "absent"),
            Quad(x: 5, y: 6, width: 1, height: 1, color: .blue),
        ])
        let plan = try FramePlan(frame: frame, target: RenderTarget(width: 8, height: 8), options: RenderOptions()) { _ in false }
        #expect(plan.draws == [
            FramePlan.Draw(firstVertex: 0, source: .color(.red), blend: .opaque), FramePlan.Draw(firstVertex: 6, source: .color(.blue), blend: .opaque),
        ])
        #expect(plan.vertices.count == 2 * FramePlan.verticesPerQuad * FramePlan.floatsPerVertex)
        #expect(Array(plan.vertices[0..<24]) == [
            1, 2, 0, 0, 4, 2, 1, 0, 1, 6, 0, 1,
            4, 2, 1, 0, 4, 6, 1, 1, 1, 6, 0, 1,
        ])
        #expect(Array(plan.vertices[24..<28]) == [5, 6, 0, 0])
    }
}
