import HearthEngine

/// A PNG writer for evidence a human looks at: 8-bit RGBA, stored (uncompressed) deflate blocks.
///
/// Deterministic by construction and free of any image framework, so artifacts are byte-stable across OS versions.
public enum PNGEncoder {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// The largest payload of one stored deflate block.
    static let storedBlockLimit = 65535

    public static func encode(_ image: PixelImage) -> [UInt8] {
        var header = bigEndian(UInt32(image.width)) + bigEndian(UInt32(image.height))
        header += [8, 6, 0, 0, 0]  // 8 bits per channel, RGBA, deflate, adaptive filtering, no interlace

        var raw = [UInt8]()
        raw.reserveCapacity(image.height * (image.width * 4 + 1))
        for row in 0..<image.height {
            raw.append(0)  // filter type: none
            raw += image.bytes[(row * image.width * 4)..<((row + 1) * image.width * 4)]
        }

        var data: [UInt8] = [0x78, 0x01]  // zlib header: deflate, 32 K window, no preset dictionary
        var offset = 0
        while offset < raw.count {
            let count = min(storedBlockLimit, raw.count - offset)
            let last: UInt8 = offset + count == raw.count ? 1 : 0
            data.append(last)
            data += [UInt8(count & 0xff), UInt8(count >> 8), UInt8(~count & 0xff), UInt8((~count >> 8) & 0xff)]
            data += raw[offset..<(offset + count)]
            offset += count
        }
        data += bigEndian(adler32(raw))

        return signature + chunk("IHDR", header) + chunk("IDAT", data) + chunk("IEND", [])
    }

    static func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + payload
        return bigEndian(UInt32(payload.count)) + body + bigEndian(crc32(body))
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
