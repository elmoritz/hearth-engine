import CryptoKit
import HearthEngine

extension PixelImage {
    /// SHA-256 over the size and the pixels, as lowercase hex. Two images hash alike only when both agree.
    public var sha256: String {
        var hash = SHA256()
        var header = [UInt8]()
        for side in [UInt32(width), UInt32(height)] {
            header += [UInt8(side & 0xff), UInt8((side >> 8) & 0xff), UInt8((side >> 16) & 0xff), UInt8(side >> 24)]
        }
        hash.update(data: header)
        hash.update(data: bytes)
        return hash.finalize().map { byte in
            let digits = Array("0123456789abcdef")
            return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
        }.joined()
    }
}
