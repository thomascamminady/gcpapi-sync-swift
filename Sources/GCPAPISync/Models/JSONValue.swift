/// Any JSON value, for payloads without a fixed shape.
///
/// Integers and floating-point numbers are kept apart, so identifiers and epoch
/// milliseconds survive a round trip exactly.
public enum JSONValue: Hashable, Sendable {
    /// `null`.
    case null
    /// `true` or `false`.
    case bool(Bool)
    /// A number without a fractional part.
    case integer(Int)
    /// Any other number.
    case number(Double)
    /// A string.
    case string(String)
    /// An array.
    case array([Self])
    /// An object.
    case object([String: Self])

    /// The object's members, if this is an object.
    public var objectValue: [String: Self]? {
        if case .object(let members) = self { members } else { nil }
    }

    /// The array's elements, if this is an array.
    public var arrayValue: [Self]? {
        if case .array(let elements) = self { elements } else { nil }
    }

    /// The string, if this is a string.
    public var stringValue: String? {
        if case .string(let text) = self { text } else { nil }
    }

    /// The number as a `Double`, if this is a number.
    public var doubleValue: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }

    /// The member named `key`, if this is an object that has it.
    public subscript(key: String) -> Self? {
        objectValue?[key]
    }
}

extension JSONValue: Codable {
    /// Decode any JSON value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }

    /// Encode the value as JSON.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    /// `null`.
    public init(nilLiteral _: ()) { self = .null }
    /// A boolean.
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    /// An integer.
    public init(integerLiteral value: Int) { self = .integer(value) }
    /// A number.
    public init(floatLiteral value: Double) { self = .number(value) }
    /// A string.
    public init(stringLiteral value: String) { self = .string(value) }
    /// An array.
    public init(arrayLiteral elements: Self...) { self = .array(elements) }
    /// An object.
    public init(dictionaryLiteral elements: (String, Self)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}
