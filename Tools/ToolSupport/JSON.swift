/// An order-preserving JSON value: generated files must not depend on hash order.
public enum JSON: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByBooleanLiteral
{
    /// An object, members in document order.
    case object([Member])
    case array([Self])
    case string(String)
    /// A number, kept as written.
    case number(String)
    case bool(Bool)
    case null

    /// One member of an object.
    public struct Member: Sendable, Equatable {
        /// The member's name.
        public var key: String
        /// The member's value.
        public var value: JSON

        /// A member.
        public init(key: String, value: JSON) {
            self.key = key
            self.value = value
        }
    }

    /// A string.
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    /// An object, in source order.
    public init(dictionaryLiteral elements: (String, Self)...) {
        self = .object(elements.map { Member(key: $0.0, value: $0.1) })
    }

    /// A boolean.
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }

    /// The value of the member `key`, if this is an object that has it.
    public subscript(key: String) -> Self? {
        members.first { $0.key == key }?.value
    }

    /// The object's members (empty for anything else).
    public var members: [Member] {
        if case .object(let members) = self { members } else { [] }
    }

    /// The string, if this is one.
    public var string: String? {
        if case .string(let text) = self { text } else { nil }
    }

    /// The elements, if this is an array.
    public var array: [Self]? {
        if case .array(let elements) = self { elements } else { nil }
    }

    /// Whether this is an object.
    public var isObject: Bool {
        if case .object = self { true } else { false }
    }

    /// Replace the member `key`, or append it.
    public mutating func set(_ key: String, _ value: Self) {
        var updated = members
        if let index = updated.firstIndex(where: { $0.key == key }) {
            updated[index].value = value
        } else {
            updated.append(Member(key: key, value: value))
        }
        self = .object(updated)
    }

    /// Text for regex matching, like Python's `str()` of a decoded value.
    public var plainText: String {
        switch self {
        case .string(let text): text
        case .number(let text): text
        case .bool(let value): value ? "True" : "False"
        case .null: "None"
        default: JSONWriter.write(self, indent: nil)
        }
    }
}

/// A JSON parser that keeps member order and, like Python's `json.loads(strict=False)`,
/// accepts raw control characters inside strings.
public struct JSONParser {
    /// Why parsing failed.
    public struct Failure: Error, CustomStringConvertible {
        /// The problem and its position.
        public let description: String
    }

    private let bytes: [UInt8]
    private var index = 0

    /// Parse `text`.
    ///
    /// - Parameter text: A JSON document.
    /// - Returns: The value, members in document order.
    /// - Throws: ``Failure`` for invalid JSON.
    public static func parse(_ text: String) throws -> JSON {
        var parser = Self(bytes: Array(text.utf8))
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw Failure(description: "trailing data at offset \(parser.index)")
        }
        return value
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func expect(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
            Array(bytes[index..<index + expected.count]) == expected
        else { throw Failure(description: "expected \(literal) at offset \(index)") }
        index += expected.count
    }

    private mutating func value() throws -> JSON {
        skipWhitespace()
        guard index < bytes.count else { throw Failure(description: "unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"):
            try expect("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expect("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expect("null")
            return .null
        default: return try number()
        }
    }

    private mutating func object() throws -> JSON {
        index += 1
        var members: [JSON.Member] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            let key = try string()
            skipWhitespace()
            try expect(":")
            members.append(JSON.Member(key: key, value: try value()))
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            try expect("}")
            return .object(members)
        }
    }

    private mutating func array() throws -> JSON {
        index += 1
        var elements: [JSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            elements.append(try value())
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            try expect("]")
            return .array(elements)
        }
    }

    private mutating func hexQuad() throws -> UInt32 {
        guard index + 4 <= bytes.count,
            let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw Failure(description: "bad \\u escape at offset \(index)") }
        index += 4
        return value
    }

    private mutating func string() throws -> String {
        try expect("\"")
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() {
            scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
            raw.removeAll()
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") {
                flush()
                return String(scalars)
            }
            guard byte == UInt8(ascii: "\\") else {
                raw.append(byte)
                continue
            }
            flush()
            guard index < bytes.count else { break }
            let escape = bytes[index]
            index += 1
            let simple: [UInt8: Unicode.Scalar] = [
                UInt8(ascii: "\""): "\"", UInt8(ascii: "\\"): "\\", UInt8(ascii: "/"): "/",
                UInt8(ascii: "b"): "\u{08}", UInt8(ascii: "f"): "\u{0C}", UInt8(ascii: "n"): "\n",
                UInt8(ascii: "r"): "\r", UInt8(ascii: "t"): "\t",
            ]
            if let scalar = simple[escape] {
                scalars.append(scalar)
                continue
            }
            guard escape == UInt8(ascii: "u") else {
                throw Failure(description: "bad escape at offset \(index)")
            }
            var code = try hexQuad()
            if (0xD800..<0xDC00).contains(code), index + 6 <= bytes.count,
                bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
            {
                index += 2
                let low = try hexQuad()
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            }
            scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
        }
        throw Failure(description: "unterminated string")
    }

    private mutating func number() throws -> JSON {
        let start = index
        while index < bytes.count, Array("+-0123456789.eE".utf8).contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw Failure(description: "unexpected byte at \(start)") }
        return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }
}

/// Serializes JSON exactly like Python's `json.dumps(value, indent=2)` (ASCII only).
public enum JSONWriter {
    /// `value` as text: indented by `indent` spaces per level, or on one line for `nil`.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - indent: Spaces per level, or `nil` for one line.
    ///   - level: The nesting level of `value`.
    /// - Returns: The JSON text.
    public static func write(_ value: JSON, indent: Int? = 2, level: Int = 0) -> String {
        let newline = indent.map { "\n" + String(repeating: " ", count: $0 * (level + 1)) } ?? ""
        let closing = indent.map { "\n" + String(repeating: " ", count: $0 * level) } ?? ""
        let separator = indent == nil ? ", " : ","
        switch value {
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let items = members.map {
                newline + quote($0.key) + ": " + write($0.value, indent: indent, level: level + 1)
            }
            return "{" + items.joined(separator: separator) + closing + "}"
        case .array(let elements):
            guard !elements.isEmpty else { return "[]" }
            let items = elements.map { newline + write($0, indent: indent, level: level + 1) }
            return "[" + items.joined(separator: separator) + closing + "]"
        case .string(let text): return quote(text)
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    /// `text` as a JSON string literal, escaping everything outside printable ASCII.
    public static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value > 0x7E {
                    for unit in String(scalar).utf16 {
                        let hex = String(unit, radix: 16)
                        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
