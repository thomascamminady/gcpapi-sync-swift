import Foundation

/// A Garmin response model.
///
/// * Property names are Garmin's JSON names (`camelCase` already), so the API
///   documentation applies unchanged.
/// * Every property is optional, because Garmin omits and nulls fields freely; only
///   activity identifiers are required.
/// * Fields the model does not describe are kept in ``extraFields``, so new API fields
///   never break decoding and are not silently dropped.
/// * Timestamps are `Date`s for Garmin's UTC fields and ``LocalDateTime`` wall-clock
///   readings for `*Local` fields, whether Garmin sent ISO strings or epoch milliseconds;
///   calendar days are ``GarminDate`` and times of day ``GarminTime``.
public protocol GarminModel: Codable, Hashable, Sendable {
    /// Fields Garmin sent that the model does not describe, by their JSON names.
    var extraFields: [String: JSONValue] { get set }
}

extension GarminModel {
    /// The paths of fields that ended up in ``extraFields`` anywhere in this model,
    /// such as `DailySleep.dailySleep.newField`. Names only, never values.
    ///
    /// A non-empty result means Garmin returned fields this package does not know yet.
    public var undocumentedFields: Set<String> {
        UndocumentedFields.collect(self, path: String(describing: Self.self))
    }
}

/// One row of a time series.
///
/// Columns are described by a sibling `*Descriptor(s)` field; the first column is usually
/// an epoch-millisecond timestamp.
public typealias SeriesRow = [Double?]

/// A coding key for any JSON member name.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) {
        stringValue = name
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

extension Decoder {
    /// The members of the current object whose names are not in `known`.
    func extraFields(known: Set<String>) throws -> [String: JSONValue] {
        let container = try container(keyedBy: AnyCodingKey.self)
        var extra: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extra[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extra
    }
}

extension Encoder {
    /// Write `fields` as members of the current object.
    func encodeExtraFields(_ fields: [String: JSONValue]) throws {
        var container = container(keyedBy: AnyCodingKey.self)
        for (name, value) in fields {
            try container.encode(value, forKey: AnyCodingKey(name))
        }
    }
}

extension KeyedDecodingContainer {
    /// A UTC timestamp (ISO string or epoch milliseconds), if present and not null.
    func decodeUTC(_ key: Key) throws -> Date? {
        try decodeIfPresent(UTCTimestamp.self, forKey: key)?.date
    }

    /// A list of UTC timestamps, if present and not null.
    func decodeUTCList(_ key: Key) throws -> [Date]? {
        try decodeIfPresent([UTCTimestamp].self, forKey: key)?.map(\.date)
    }
}

extension KeyedEncodingContainer {
    /// Write a UTC timestamp as ISO 8601, unless it is `nil`.
    mutating func encodeUTC(_ date: Date?, forKey key: Key) throws {
        try encodeIfPresent(date.map(UTCTimestamp.init), forKey: key)
    }

    /// Write UTC timestamps as ISO 8601, unless the list is `nil`.
    mutating func encodeUTCList(_ dates: [Date]?, forKey key: Key) throws {
        try encodeIfPresent(dates?.map(UTCTimestamp.init), forKey: key)
    }
}

/// Walks models with reflection to find fields that landed in `extraFields`.
enum UndocumentedFields {
    static func collect(_ value: Any, path: String) -> Set<String> {
        var found: Set<String> = []
        if let model = value as? any GarminModel {
            found.formUnion(model.extraFields.keys.map { "\(path).\($0)" })
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            if let wrapped = mirror.children.first {
                found.formUnion(collect(wrapped.value, path: path))
            }
        case .collection:
            for child in mirror.children {
                found.formUnion(collect(child.value, path: path))
            }
        case .struct where value is any GarminModel:
            for child in mirror.children {
                if let label = child.label, label != "extraFields" {
                    found.formUnion(collect(child.value, path: "\(path).\(label)"))
                }
            }
        default:
            break
        }
        return found
    }
}
