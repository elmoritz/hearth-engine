import HearthEngine
import Testing

@testable import HearthHarness

/// E-CORPUS-1: the synthetic tier is code, and the same code gives the same bytes.
@Suite struct CorpusTests {
    @Test func `E-CORPUS-1 two generations are byte-identical`() throws {
        let first = try SyntheticCorpus.generate()
        let second = try SyntheticCorpus.generate()
        #expect(SyntheticCorpus.serialize(first) == SyntheticCorpus.serialize(second))
        #expect(first == second)
        #expect(Set(first.map(\.name)).count == first.count)
        #expect(first.count == 6 + 3 * SyntheticCorpus.tilesPerProjection + 1)
        #expect(first.first?.name == "flat/white" && first.last?.name == "sheet/numbered")
        #expect(first[6].name == "tile/diamond48x28/0" && first[6].textureID == TextureID("tile/diamond48x28/0"))
        // The serialised form is the name, the size and the pixels of every entry, in order.
        let tiny = [CorpusEntry(name: "ab", image: try PixelImage(width: 2, height: 1, bytes: [1, 2, 3, 4, 5, 6, 7, 8]))]
        #expect(SyntheticCorpus.serialize(tiny) == [2, 0, 0, 0, 97, 98, 2, 0, 0, 0, 1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(SyntheticCorpus.serialize([]) == [])
        let wide = [CorpusEntry(name: "", image: try PixelImage(width: 258, height: 1, filledWith: .clear))]
        #expect(Array(SyntheticCorpus.serialize(wide)[0..<12]) == [0, 0, 0, 0, 2, 1, 0, 0, 1, 0, 0, 0])
    }

    @Test func `E-CORPUS-1 negative control a changed entry changes the bytes`() throws {
        let entries = try SyntheticCorpus.generate()
        let bytes = SyntheticCorpus.serialize(entries)
        for index in [0, entries.count / 2, entries.count - 1] {
            var changed = entries
            var image = changed[index].image
            let old = try #require(image[0, 0])
            image.set(x: 0, y: 0, to: RGBA8(old.r ^ 1, old.g, old.b, old.a))
            changed[index] = CorpusEntry(name: changed[index].name, image: image)
            #expect(SyntheticCorpus.serialize(changed) != bytes)
        }
        var renamed = entries
        renamed[3] = CorpusEntry(name: "ramp/other", image: renamed[3].image)
        #expect(SyntheticCorpus.serialize(renamed) != bytes)
        #expect(SyntheticCorpus.serialize(Array(entries.reversed())) != bytes)
        // A tile differs from its neighbour in number, and from the same number on another projection.
        #expect(try SyntheticCorpus.numberedTile(1, projection: .orthogonal) != SyntheticCorpus.numberedTile(2, projection: .orthogonal))
        #expect(try SyntheticCorpus.numberedTile(1, projection: .diamond2to1).width != SyntheticCorpus.numberedTile(1, projection: .diamond48x28).width)
    }

    #if os(macOS)
    @Test func `E-CORPUS-1 the repo holds no binary asset for the synthetic tier`() {
        let files = Repo.sourceFiles()
        #expect(files.contains("Sources/HearthHarness/Corpus/SyntheticCorpus.swift"))
        #expect(files.contains("Tests/HearthEngineTests/CorpusTests.swift"))
        #expect(Repo.binaryAssets(in: files) == [])
    }

    @Test func `E-CORPUS-1 the binary-asset check flags an image file`() {
        let fixture = [
            "Sources/HearthHarness/Corpus/SyntheticCorpus.swift", "Tests/Corpus/tile.png", "Tests/Corpus/TILE.KTX2",
            "Sources/HearthEngine/Shaders/Quad.metal", "Tests/Corpus/sheet.astc", "Tests/Corpus/png", "Tests/Corpus/ramp.bin",
        ]
        #expect(Repo.binaryAssets(in: fixture) == ["Tests/Corpus/tile.png", "Tests/Corpus/TILE.KTX2", "Tests/Corpus/sheet.astc", "Tests/Corpus/ramp.bin"])
        #expect(Repo.binaryAssets(in: []) == [])
    }
    #endif

    @Test func `E-CORPUS-1 ramps tiles and sheets hold their analytic values`() throws {
        // Flat.
        #expect(try SyntheticCorpus.flat(RGBA8(1, 2, 3, 4), width: 3, height: 2) == PixelImage(width: 3, height: 2, bytes: (0..<6).flatMap { _ in [UInt8(1), 2, 3, 4] }))

        // Ramps: 0 at the first step, 255 at the last, linear between.
        #expect(SyntheticCorpus.ramp(0, 256) == 0 && SyntheticCorpus.ramp(128, 256) == 128 && SyntheticCorpus.ramp(255, 256) == 255)
        #expect(SyntheticCorpus.ramp(0, 2) == 0 && SyntheticCorpus.ramp(1, 2) == 255 && SyntheticCorpus.ramp(1, 3) == 127 && SyntheticCorpus.ramp(0, 1) == 255)
        let alpha = try SyntheticCorpus.alphaRamp(width: 256, height: 8)
        for x in [0, 1, 100, 255] {
            #expect(alpha[x, 0] == RGBA8(255, 255, 255, UInt8(x)) && alpha[x, 7] == RGBA8(255, 255, 255, UInt8(x)))
        }
        #expect(try SyntheticCorpus.alphaRamp(width: 3, height: 1, color: RGBA8(9, 8, 7)).bytes == [9, 8, 7, 0, 9, 8, 7, 127, 9, 8, 7, 255])
        let colour = try SyntheticCorpus.colourRamp(width: 64, height: 64)
        #expect(colour[0, 0] == RGBA8(0, 0, 255) && colour[63, 0] == RGBA8(255, 0, 0) && colour[0, 63] == RGBA8(0, 255, 255) && colour[63, 63] == RGBA8(255, 255, 0))
        #expect(colour[21, 42] == RGBA8(85, 170, 170))
        #expect(try SyntheticCorpus.colourRamp(width: 1, height: 1).bytes == [255, 255, 0, 255])

        // Saturated neighbours: every cell is one flat saturated colour and differs from the cells beside and below it.
        let cells = try SyntheticCorpus.saturatedNeighbours(cell: 8, columns: 6, rows: 4)
        #expect(cells.width == 48 && cells.height == 32)
        #expect(cells[0, 0] == RGBA8(255, 0, 0) && cells[7, 7] == RGBA8(255, 0, 0) && cells[8, 0] == RGBA8(0, 255, 255) && cells[0, 8] == RGBA8(0, 255, 0))
        for row in 0..<4 {
            for column in 0..<6 {
                let here = try #require(cells[column * 8, row * 8])
                #expect(SyntheticCorpus.saturated.contains(here))
                #expect(cells[column * 8 + 7, row * 8 + 7] == here)
                if column < 5 { #expect(cells[column * 8 + 8, row * 8] != here) }
                if row < 3 { #expect(cells[column * 8, row * 8 + 8] != here) }
            }
        }
        #expect(Set(SyntheticCorpus.saturated).count == 6 && Set(SyntheticCorpus.muted).count == 6)

        // Tiles on the three projections.
        #expect(CorpusProjection.allCases.map { [$0.tileWidth, $0.tileHeight] } == [[48, 28], [64, 32], [32, 32]])
        func span(_ projection: CorpusProjection, row: Int) -> [Int] {
            (0..<projection.tileWidth).filter { projection.covers(x: $0, y: row) }
        }
        // (48, 28): the top row holds the two centre pixels; the two middle rows run from 1 to 46.
        #expect(span(.diamond48x28, row: 0) == [23, 24] && span(.diamond48x28, row: 27) == [23, 24])
        #expect(span(.diamond48x28, row: 13) == Array(1...46) && span(.diamond48x28, row: 14) == Array(1...46))
        // 2:1: each row is four pixels wider than the one above it, from 2 at the tip to 62 in the middle.
        #expect(span(.diamond2to1, row: 0) == [31, 32] && span(.diamond2to1, row: 1) == Array(29...34))
        #expect(span(.diamond2to1, row: 15) == Array(1...62) && span(.diamond2to1, row: 16) == Array(1...62) && span(.diamond2to1, row: 31) == [31, 32])
        #expect(span(.orthogonal, row: 0) == Array(0...31) && span(.orthogonal, row: 31) == Array(0...31))
        for projection in CorpusProjection.allCases {
            let w = projection.tileWidth, h = projection.tileHeight
            for (x, y) in [(-1, 0), (0, -1), (w, 0), (0, h)] {
                #expect(!projection.covers(x: x, y: y))
            }
            // The footprint is symmetric left to right and top to bottom, and the tile is clear outside it.
            let tile = try SyntheticCorpus.numberedTile(4, projection: projection)
            #expect(tile.width == w && tile.height == h)
            for y in 0..<h {
                for x in 0..<w {
                    #expect(projection.covers(x: x, y: y) == projection.covers(x: w - 1 - x, y: h - 1 - y))
                    #expect(projection.covers(x: x, y: y) == projection.covers(x: w - 1 - x, y: y))
                    #expect((tile[x, y] == .clear) == !projection.covers(x: x, y: y))
                }
            }
            #expect(tile[w / 2, 1] == SyntheticCorpus.muted[4])
            #expect(try SyntheticCorpus.numberedTile(-4, projection: projection) == tile)
            #expect(try SyntheticCorpus.numberedTile(6, projection: projection)[w / 2, 1] == SyntheticCorpus.muted[0])
        }

        // The sheet: a black frame around every cell, the cell's colour inside, its number in the middle.
        let sheet = try SyntheticCorpus.numberedSheet(columns: 4, rows: 2, cellWidth: 32, cellHeight: 32)
        #expect(sheet.width == 128 && sheet.height == 64)
        #expect(sheet[0, 0] == .black && sheet[1, 1] == SyntheticCorpus.muted[0] && sheet[30, 30] == SyntheticCorpus.muted[0] && sheet[31, 31] == .black)
        #expect(sheet[32, 0] == .black && sheet[33, 1] == SyntheticCorpus.muted[1] && sheet[97, 33] == SyntheticCorpus.muted[1] && sheet[126, 62] == SyntheticCorpus.muted[1])
        #expect(sheet[127, 63] == .black && sheet[1, 33] == SyntheticCorpus.muted[4])
        // Each cell shows its own index: cut out, it equals a cell drawn alone.
        for index in 0..<8 {
            var alone = try PixelImage(width: 32, height: 32, filledWith: .black)
            var cell = alone
            for y in 0..<32 {
                for x in 0..<32 {
                    cell.set(x: x, y: y, to: try #require(sheet[(index % 4) * 32 + x, (index / 4) * 32 + y]))
                    if (1..<31).contains(x) && (1..<31).contains(y) { alone.set(x: x, y: y, to: SyntheticCorpus.muted[index % 6]) }
                }
            }
            SyntheticCorpus.draw(index, into: &alone, originX: 0, originY: 0, width: 32, height: 32, scale: 2)
            #expect(cell == alone)
        }
        #expect(try SyntheticCorpus.numberedSheet(columns: 1, rows: 1, cellWidth: 1, cellHeight: 1).bytes == [0, 0, 0, 255])
        // A cell too small for its number keeps its border and never bleeds into its neighbour: of a 3x3 cell only
        // the centre pixel is inside, and it shows what the centred glyph has there (nothing for 0, a stroke for 1).
        let small = try SyntheticCorpus.numberedSheet(columns: 2, rows: 1, cellWidth: 3, cellHeight: 3)
        #expect(small == (try expectedImage(width: 6, height: 3, clear: .black) { x, y in
            y == 1 && x == 1 ? SyntheticCorpus.muted[0] : (y == 1 && x == 4 ? .white : nil)
        }))
        // The box clips on each of its four sides, with and without an inset.
        var clipped = try PixelImage(width: 12, height: 12, filledWith: .black)
        SyntheticCorpus.draw(8, into: &clipped, originX: 4, originY: 4, width: 4, height: 4, scale: 2)
        var inset = try PixelImage(width: 12, height: 12, filledWith: .black)
        SyntheticCorpus.draw(8, into: &inset, originX: 4, originY: 4, width: 4, height: 4, scale: 2, inset: 1)
        var empty = inset
        SyntheticCorpus.draw(8, into: &empty, originX: 4, originY: 4, width: 4, height: 4, scale: 2, inset: 2)
        SyntheticCorpus.draw(8, into: &empty, originX: 4, originY: 4, width: 4, height: 4, scale: 2, inset: 3)
        #expect(empty == inset)
        // 8 at scale 2 is 6x10, centred on the 4x4 box at (4, 4): left 3, top 1. Rows 5 and 6 are the glyph's
        // middle bar (all on); rows 4 and 7 are its sides (on, off, on).
        for y in 0..<12 {
            for x in 0..<12 {
                let inBox = (4..<8).contains(x) && (4..<8).contains(y)
                let lit = y == 5 || y == 6 || (x - 3) / 2 != 1
                #expect((clipped[x, y] == .white) == (inBox && lit))
                let inInset = (5..<7).contains(x) && (5..<7).contains(y)
                #expect((inset[x, y] == .white) == (inInset && lit))
            }
        }
    }

    @Test func `E-CORPUS-1 numbers render distinctly from 0 to 9 and with several digits`() throws {
        func drawn(_ number: Int, width: Int = 16, height: Int = 7, scale: Int = 1) throws -> PixelImage {
            var image = try PixelImage(width: width, height: height, filledWith: .black)
            SyntheticCorpus.draw(number, into: &image, originX: 0, originY: 0, width: width, height: height, scale: scale)
            return image
        }
        func rows(_ image: PixelImage) -> [String] {
            (0..<image.height).map { y in (0..<image.width).map { image[$0, y] == .white ? "#" : "." }.joined() }
        }
        #expect(Set(try (0...9).map { try drawn($0) }).count == 10)
        #expect(SyntheticCorpus.glyphs.count == 10 && SyntheticCorpus.glyphs.allSatisfy { $0.count == 5 && $0.allSatisfy { $0 < 8 } })
        // One digit, centred in 16x7: three columns starting at (16 - 3) / 2 = 6, five rows starting at 1.
        #expect(rows(try drawn(7)) == [
            "................", "......###.......", "........#.......", "........#.......", "........#.......", "........#.......", "................",
        ])
        #expect(rows(try drawn(1, width: 5, height: 5)) == ["..#..", ".##..", "..#..", "..#..", ".###."])
        // Two digits with one column between them: seven columns starting at (16 - 7) / 2 = 4.
        #expect(rows(try drawn(10)) == [
            "................", ".....#..###.....", "....##..#.#.....", ".....#..#.#.....", ".....#..#.#.....", "....###.###.....", "................",
        ])
        #expect(try drawn(99) != drawn(9) && drawn(-10) == drawn(10) && drawn(0) != drawn(8))
        // At scale 2 every glyph pixel is a 2x2 block.
        let big = try drawn(1, width: 6, height: 10, scale: 2)
        #expect(rows(big) == ["..##..", "..##..", "####..", "####..", "..##..", "..##..", "..##..", "..##..", "######", "######"])
        // Text wider than its box is clipped, never an error.
        #expect(rows(try drawn(123456, width: 4, height: 5)).allSatisfy { $0.count == 4 })
    }

    @Test func `E-CORPUS-1 generation is deterministic and sized as declared over 1000 seeded parameters`() throws {
        var random = SplitMix64(seed: 0x4845_0005)
        for _ in 0..<1000 {
            let width = Int.random(in: 1...24, using: &random), height = Int.random(in: 1...24, using: &random)
            let number = Int.random(in: -99...999, using: &random)
            let projection = try #require(CorpusProjection.allCases.randomElement(using: &random))
            let columns = Int.random(in: 1...4, using: &random), rows = Int.random(in: 1...4, using: &random)

            let images = [
                try SyntheticCorpus.alphaRamp(width: width, height: height), try SyntheticCorpus.colourRamp(width: width, height: height),
                try SyntheticCorpus.saturatedNeighbours(cell: width, columns: columns, rows: rows),
                try SyntheticCorpus.numberedSheet(columns: columns, rows: rows, cellWidth: width, cellHeight: height),
                try SyntheticCorpus.numberedTile(number, projection: projection),
            ]
            let again = [
                try SyntheticCorpus.alphaRamp(width: width, height: height), try SyntheticCorpus.colourRamp(width: width, height: height),
                try SyntheticCorpus.saturatedNeighbours(cell: width, columns: columns, rows: rows),
                try SyntheticCorpus.numberedSheet(columns: columns, rows: rows, cellWidth: width, cellHeight: height),
                try SyntheticCorpus.numberedTile(number, projection: projection),
            ]
            #expect(images == again)
            #expect(images.map(\.width) == [width, width, width * columns, width * columns, projection.tileWidth])
            #expect(images.map(\.height) == [height, height, width * rows, height * rows, projection.tileHeight])
            #expect(images.allSatisfy { $0.bytes.count == $0.width * $0.height * 4 })
        }
    }

    @Test func `E-CORPUS-1 a generator refuses a size it cannot make`() throws {
        #expect(throws: EngineError.malformedAssetHeader(width: 0, height: 4, byteCount: 0)) { try SyntheticCorpus.flat(.red, width: 0, height: 4) }
        #expect(throws: EngineError.malformedAssetHeader(width: 4, height: 0, byteCount: 0)) { try SyntheticCorpus.alphaRamp(width: 4, height: 0) }
        #expect(throws: EngineError.malformedAssetHeader(width: -1, height: 4, byteCount: 0)) { try SyntheticCorpus.colourRamp(width: -1, height: 4) }
        for (cell, columns, rows) in [(0, 2, 2), (2, 0, 2), (2, 2, 0), (-1, 2, 2)] {
            #expect(throws: EngineError.malformedAssetHeader(width: cell * columns, height: cell * rows, byteCount: 0)) {
                try SyntheticCorpus.saturatedNeighbours(cell: cell, columns: columns, rows: rows)
            }
        }
        for (columns, rows, width, height) in [(0, 1, 4, 4), (1, 0, 4, 4), (1, 1, 0, 4), (1, 1, 4, 0)] {
            #expect(throws: EngineError.malformedAssetHeader(width: columns * width, height: rows * height, byteCount: 0)) {
                try SyntheticCorpus.numberedSheet(columns: columns, rows: rows, cellWidth: width, cellHeight: height)
            }
        }
        // Factors are refused before they are multiplied: the largest integers throw instead of overflowing, and
        // the error reports the product clamped to what an Int holds.
        #expect(throws: EngineError.malformedAssetHeader(width: Int.max, height: Int.max, byteCount: 0)) { try SyntheticCorpus.saturatedNeighbours(cell: Int.max, columns: 2, rows: 2) }
        #expect(throws: EngineError.malformedAssetHeader(width: 2, height: Int.max, byteCount: 0)) { try SyntheticCorpus.saturatedNeighbours(cell: 1, columns: 2, rows: Int.max) }
        #expect(throws: EngineError.malformedAssetHeader(width: Int.max, height: 4, byteCount: 0)) { try SyntheticCorpus.saturatedNeighbours(cell: 2, columns: Int.max, rows: 2) }
        #expect(throws: EngineError.malformedAssetHeader(width: Int.max, height: Int.max, byteCount: 0)) {
            try SyntheticCorpus.numberedSheet(columns: Int.max, rows: Int.max, cellWidth: Int.max, cellHeight: Int.max)
        }
        #expect(throws: EngineError.malformedAssetHeader(width: Int.min, height: 4, byteCount: 0)) {
            try SyntheticCorpus.numberedSheet(columns: Int.min, rows: 1, cellWidth: 2, cellHeight: 4)
        }
        #expect(throws: EngineError.malformedAssetHeader(width: 4, height: Int.max, byteCount: 0)) {
            try SyntheticCorpus.numberedSheet(columns: 1, rows: 3, cellWidth: 4, cellHeight: Int.max)
        }
        #expect(throws: EngineError.malformedAssetHeader(width: 4, height: Int.max, byteCount: 0)) {
            try SyntheticCorpus.numberedSheet(columns: 1, rows: Int.max, cellWidth: 4, cellHeight: 3)
        }
        #expect(throws: EngineError.malformedAssetHeader(width: Int.max, height: 4, byteCount: 0)) {
            try SyntheticCorpus.numberedSheet(columns: 1, rows: 1, cellWidth: Int.max, cellHeight: 4)
        }
        #expect(SyntheticCorpus.product(3, 4) == 12 && SyntheticCorpus.product(-3, 4) == -12)
        #expect(SyntheticCorpus.product(Int.min, 2) == Int.min && SyntheticCorpus.product(2, Int.min) == Int.min)
        #expect(SyntheticCorpus.product(Int.min, -2) == Int.max && SyntheticCorpus.product(Int.max, 2) == Int.max)
        #expect(SyntheticCorpus.sides == 1...16384)
        // Each factor may be the maximum on its own, as long as the side is not past it.
        #expect(try SyntheticCorpus.saturatedNeighbours(cell: 1, columns: 16384, rows: 1).width == 16384)
        #expect(try SyntheticCorpus.numberedSheet(columns: 1, rows: 16384, cellWidth: 1, cellHeight: 1).height == 16384)
        #expect(try SyntheticCorpus.numberedSheet(columns: 16384, rows: 1, cellWidth: 1, cellHeight: 1).width == 16384)
        #expect(try SyntheticCorpus.numberedSheet(columns: 1, rows: 1, cellWidth: 16384, cellHeight: 1).width == 16384)
        #expect(try SyntheticCorpus.numberedSheet(columns: 1, rows: 1, cellWidth: 1, cellHeight: 16384).height == 16384)
        // Cells are square, so a cell past the maximum is too large on both sides.
        #expect(throws: EngineError.malformedAssetHeader(width: 16385, height: 16385, byteCount: 0)) { try SyntheticCorpus.saturatedNeighbours(cell: 16385, columns: 1, rows: 1) }
        #expect(throws: EngineError.malformedAssetHeader(width: 16385, height: 1, byteCount: 0)) { try SyntheticCorpus.numberedSheet(columns: 1, rows: 1, cellWidth: 16385, cellHeight: 1) }
    }
}
