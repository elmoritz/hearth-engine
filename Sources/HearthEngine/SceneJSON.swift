/// The JSON of a scene file, with one fixed spelling (E-SER-3). The engine writes and reads it itself, rather than
/// through `JSONEncoder` and `JSONDecoder`, for two reasons: the writer's layout and number format are part of the
/// format, and a number is kept as its text and converted to `Float` once, correctly rounded, so a `Float` survives
/// a round trip bit for bit (E-SER-1). Going through `Double` first would round twice.
indirect enum SceneJSON: Sendable, Equatable {
    /// Members in no order: the writer sorts the keys, so no caller decides the order (E-SER-3).
    case object([String: SceneJSON])
    case array([SceneJSON])
    case string(String)
    /// The number's text: as the writer spells it, or as the reader found it (already checked against the grammar).
    case number(String)
    case bool(Bool)
    case null

    /// Containers deeper than this are refused, so a hostile file cannot exhaust the stack (E-HAR-4).
    static let maximumDepth = 32

    static func float(_ value: Float) -> SceneJSON {
        .number(spelling(of: value))
    }

    static func int(_ value: Int) -> SceneJSON {
        .number(String(value))
    }

    /// Swift's shortest decimal that reads back as the same `Float`, without a trailing `.0`: `64`, `0.5`, `-0`,
    /// `1e-45`, `3.4028235e+38`. The caller has checked that the value is finite.
    static func spelling(of value: Float) -> String {
        let text = value.description
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// Whether the value is written inline by its container's layout rule.
    private var isScalar: Bool {
        switch self {
        case .object, .array: false
        case .string, .number, .bool, .null: true
        }
    }

    // MARK: Writing

    /// The canonical bytes: keys sorted by their UTF-8 bytes, two-space indent, a container that is empty or holds
    /// only scalars on one line and any other one member per line, a newline at the end.
    func written() -> [UInt8] {
        var out = [UInt8]()
        write(into: &out, indent: 0)
        out.append(0x0A)
        return out
    }

    /// Whether `a` sorts before `b` in the writer's key order: by UTF-8 bytes, independent of locale and of
    /// `String`'s Unicode comparison.
    static func keyPrecedes(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    private func write(into out: inout [UInt8], indent: Int) {
        switch self {
        case .object(let members):
            let sorted = members.sorted { Self.keyPrecedes($0.key, $1.key) }
            Self.writeContainer(
                into: &out, indent: indent, open: 0x7B, close: 0x7D, inline: members.values.allSatisfy(\.isScalar),
                count: sorted.count
            ) { out, index, indent in
                Self.writeString(sorted[index].key, into: &out)
                out.append(contentsOf: [0x3A, 0x20])
                sorted[index].value.write(into: &out, indent: indent)
            }
        case .array(let elements):
            Self.writeContainer(
                into: &out, indent: indent, open: 0x5B, close: 0x5D, inline: elements.allSatisfy(\.isScalar),
                count: elements.count
            ) { out, index, indent in
                elements[index].write(into: &out, indent: indent)
            }
        case .string(let text):
            Self.writeString(text, into: &out)
        case .number(let text):
            out.append(contentsOf: text.utf8)
        case .bool(let value):
            out.append(contentsOf: (value ? "true" : "false").utf8)
        case .null:
            out.append(contentsOf: "null".utf8)
        }
    }

    private static func writeContainer(
        into out: inout [UInt8], indent: Int, open: UInt8, close: UInt8, inline: Bool, count: Int,
        member: (inout [UInt8], Int, Int) -> Void
    ) {
        out.append(open)
        for index in 0..<count {
            if index > 0 {
                out.append(0x2C)
                if inline { out.append(0x20) }
            }
            if !inline { newline(into: &out, indent: indent + 2) }
            member(&out, index, indent + 2)
        }
        if !inline && count > 0 { newline(into: &out, indent: indent) }
        out.append(close)
    }

    private static func newline(into out: inout [UInt8], indent: Int) {
        out.append(0x0A)
        out.append(contentsOf: repeatElement(0x20, count: indent))
    }

    private static func writeString(_ text: String, into out: inout [UInt8]) {
        out.append(0x22)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: [0x5C, 0x22])
            case "\\": out.append(contentsOf: [0x5C, 0x5C])
            case "\n": out.append(contentsOf: [0x5C, 0x6E])
            case "\r": out.append(contentsOf: [0x5C, 0x72])
            case "\t": out.append(contentsOf: [0x5C, 0x74])
            case "\u{08}": out.append(contentsOf: [0x5C, 0x62])
            case "\u{0C}": out.append(contentsOf: [0x5C, 0x66])
            case _ where scalar.value < 0x20:
                let hex = Array("0123456789abcdef".utf8)
                out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hex[Int(scalar.value >> 4)], hex[Int(scalar.value & 0xF)]])
            default:
                out.append(contentsOf: String(scalar).utf8)
            }
        }
        out.append(0x22)
    }

    // MARK: Reading

    /// Parses one JSON value that fills `bytes` (whitespace around it allowed). Any layout and key order reads;
    /// everything else that is not JSON throws `invalidSceneFile` at the byte where it stops being JSON. Duplicate
    /// keys are refused, so no member is silently dropped.
    static func parse(_ bytes: [UInt8]) throws(EngineError) -> SceneJSON {
        // A file that is not UTF-8 decodes with replacement characters, which no longer spell the same bytes.
        guard Array(String(decoding: bytes, as: UTF8.self).utf8) == bytes else {
            throw .invalidSceneFile(path: "file", reason: "not valid UTF-8")
        }
        var parser = Parser(bytes: bytes)
        parser.skipWhitespace()
        let value = try parser.value(depth: 1)
        parser.skipWhitespace()
        guard parser.offset == bytes.count else { throw parser.failure("content after the end of the value") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        func failure(_ reason: String) -> EngineError {
            .invalidSceneFile(path: "byte \(offset)", reason: reason)
        }

        private var current: UInt8? {
            offset < bytes.count ? bytes[offset] : nil
        }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                offset += 1
            }
        }

        mutating func value(depth: Int) throws(EngineError) -> SceneJSON {
            guard let byte = current else { throw failure("unexpected end of file") }
            switch byte {
            case 0x7B: return try object(depth: depth)
            case 0x5B: return try array(depth: depth)
            case 0x22: return .string(try string())
            case 0x74: try literal("true"); return .bool(true)
            case 0x66: try literal("false"); return .bool(false)
            case 0x6E: try literal("null"); return .null
            case 0x2D, 0x30...0x39: return .number(try number())
            default: throw failure("unexpected character")
            }
        }

        private mutating func enter(depth: Int) throws(EngineError) {
            guard depth <= SceneJSON.maximumDepth else {
                throw failure("nested deeper than \(SceneJSON.maximumDepth) levels")
            }
            offset += 1
            skipWhitespace()
        }

        private mutating func object(depth: Int) throws(EngineError) -> SceneJSON {
            try enter(depth: depth)
            var members = [String: SceneJSON]()
            if current == 0x7D {
                offset += 1
                return .object(members)
            }
            while true {
                guard current == 0x22 else { throw failure("expected a key") }
                let keyOffset = offset
                let key = try string()
                skipWhitespace()
                guard current == 0x3A else { throw failure("expected ':'") }
                offset += 1
                skipWhitespace()
                let member = try value(depth: depth + 1)
                guard members.updateValue(member, forKey: key) == nil else {
                    throw .invalidSceneFile(path: "byte \(keyOffset)", reason: "duplicate key \"\(key)\"")
                }
                skipWhitespace()
                if current == 0x7D {
                    offset += 1
                    return .object(members)
                }
                guard current == 0x2C else { throw failure("expected ',' or '}'") }
                offset += 1
                skipWhitespace()
            }
        }

        private mutating func array(depth: Int) throws(EngineError) -> SceneJSON {
            try enter(depth: depth)
            var elements = [SceneJSON]()
            if current == 0x5D {
                offset += 1
                return .array(elements)
            }
            while true {
                elements.append(try value(depth: depth + 1))
                skipWhitespace()
                if current == 0x5D {
                    offset += 1
                    return .array(elements)
                }
                guard current == 0x2C else { throw failure("expected ',' or ']'") }
                offset += 1
                skipWhitespace()
            }
        }

        private mutating func literal(_ word: String) throws(EngineError) {
            let spelled = Array(word.utf8)
            guard bytes.count - offset >= spelled.count, Array(bytes[offset..<offset + spelled.count]) == spelled else {
                throw failure("unexpected character")
            }
            offset += spelled.count
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, returned as written.
        private mutating func number() throws(EngineError) -> String {
            let start = offset
            if current == 0x2D { offset += 1 }
            if current == 0x30 {
                offset += 1
            } else {
                guard digits() else { throw failure("expected a digit") }
            }
            if current == 0x2E {
                offset += 1
                guard digits() else { throw failure("expected a digit after '.'") }
            }
            if current == 0x65 || current == 0x45 {
                offset += 1
                if current == 0x2B || current == 0x2D { offset += 1 }
                guard digits() else { throw failure("expected a digit in the exponent") }
            }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }

        /// Consumes `[0-9]+`; false when there was none.
        private mutating func digits() -> Bool {
            let start = offset
            while let byte = current, (0x30...0x39).contains(byte) {
                offset += 1
            }
            return offset > start
        }

        private mutating func string() throws(EngineError) -> String {
            offset += 1
            var out = [UInt8]()
            while true {
                guard let byte = current else { throw failure("unterminated string") }
                switch byte {
                case 0x22:
                    offset += 1
                    return String(decoding: out, as: UTF8.self)
                case 0x5C:
                    offset += 1
                    out.append(contentsOf: try escape())
                case 0x00..<0x20:
                    throw failure("control character in a string")
                default:
                    out.append(byte)
                    offset += 1
                }
            }
        }

        /// The bytes of one escape; `offset` is past the backslash.
        private mutating func escape() throws(EngineError) -> [UInt8] {
            guard let byte = current else { throw failure("unterminated string") }
            offset += 1
            switch byte {
            case 0x22, 0x5C, 0x2F: return [byte]
            case 0x62: return [0x08]
            case 0x66: return [0x0C]
            case 0x6E: return [0x0A]
            case 0x72: return [0x0D]
            case 0x74: return [0x09]
            case 0x75:
                let unit = try hexUnit()
                var value = UInt32(unit)
                if (0xD800...0xDBFF).contains(unit) {
                    guard current == 0x5C, offset + 1 < bytes.count, bytes[offset + 1] == 0x75 else {
                        throw failure("a high surrogate without its low surrogate")
                    }
                    offset += 2
                    let low = try hexUnit()
                    guard (0xDC00...0xDFFF).contains(low) else { throw failure("a high surrogate without its low surrogate") }
                    value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(unit) {
                    throw failure("a low surrogate without its high surrogate")
                }
                guard let scalar = Unicode.Scalar(value) else { throw failure("not a Unicode scalar") } // cov:allow - every non-surrogate code point the branches above let through is a scalar
                return Array(String(scalar).utf8)
            default:
                offset -= 1
                throw failure("unknown escape")
            }
        }

        private mutating func hexUnit() throws(EngineError) -> UInt16 {
            guard bytes.count - offset >= 4 else { throw failure("expected four hex digits") }
            var unit: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[offset]
                let digit: UInt8
                switch byte {
                case 0x30...0x39: digit = byte - 0x30
                case 0x41...0x46: digit = byte - 0x41 + 10
                case 0x61...0x66: digit = byte - 0x61 + 10
                default: throw failure("expected four hex digits")
                }
                unit = unit << 4 | UInt16(digit)
                offset += 1
            }
            return unit
        }
    }
}
