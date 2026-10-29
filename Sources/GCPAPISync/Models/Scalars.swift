public import Foundation

// Garmin's API encodes the same concept in several ways, sometimes contradicting its own
// OpenAPI document: timestamps arrive as ISO strings without an offset
// ("2026-10-21T07:15:54.0") or as epoch milliseconds, and dates as plain strings or
// {"date": ..., "localDate": ...} objects. The types below accept every observed form
// and normalize it to one Swift type. Calendar arithmetic is exact integer math in the
// proleptic Gregorian calendar, independent of the device's locale and time zone.

/// A calendar date without a time or time zone, such as Garmin's `calendarDate`.
///
/// Create one from its parts, from a `YYYY-MM-DD` string, or from a `Date` in a time
/// zone. As a model field it also accepts ISO date-times, epoch milliseconds and
/// Garmin's `{"localDate": ...}` objects.
public struct GarminDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The year (1 to 9999).
    public let year: Int
    /// The month (1 to 12).
    public let month: Int
    /// The day of the month (1 to 31).
    public let day: Int

    /// A validated date.
    ///
    /// - Throws: ``InvalidArgumentError`` if the parts do not form a valid date.
    public init(year: Int, month: Int, day: Int) throws {
        guard Civil.isValid(year: year, month: month, day: day) else {
            throw InvalidArgumentError("\(year)-\(month)-\(day) is not a valid date")
        }
        self.init(unchecked: year, month, day)
    }

    /// Parse a `YYYY-MM-DD` string.
    ///
    /// - Throws: ``InvalidArgumentError`` if `text` is not an ISO calendar date.
    public init(_ text: String) throws {
        guard let parsed = Self(iso: text) else {
            throw InvalidArgumentError("expected a YYYY-MM-DD date, got \(Self.quoted(text))")
        }
        self = parsed
    }

    /// The calendar date of `date` in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone = .current) {
        let seconds =
            Int(date.timeIntervalSince1970.rounded(.down))
            + timeZone.secondsFromGMT(for: date)
        self.init(daysSinceEpoch: Civil.floorDivide(seconds, 86_400))
    }

    /// Today in `timeZone`.
    public static func today(in timeZone: TimeZone = .current) -> Self {
        Self(Date(), in: timeZone)
    }

    init(unchecked year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(daysSinceEpoch days: Int) {
        let (year, month, day) = Civil.date(daysSinceEpoch: days)
        self.init(unchecked: year, month, day)
    }

    init?(iso text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, let (year, month, day) = ISOParser.date(bytes, at: 0),
            Civil.isValid(year: year, month: month, day: day)
        else { return nil }
        self.init(unchecked: year, month, day)
    }

    /// Days since 1970-01-01.
    var daysSinceEpoch: Int { Civil.days(year: year, month: month, day: day) }

    /// The date `days` days later (or earlier, for negative values).
    public func adding(days: Int) -> Self {
        Self(daysSinceEpoch: daysSinceEpoch + days)
    }

    /// The number of days from this date to `other` (negative if `other` is earlier).
    public func days(to other: Self) -> Int {
        other.daysSinceEpoch - daysSinceEpoch
    }

    /// Midnight at the start of this date in `timeZone`.
    public func startOfDay(in timeZone: TimeZone) -> Date {
        let utc = Date(timeIntervalSince1970: Double(daysSinceEpoch) * 86_400)
        return utc.addingTimeInterval(-Double(timeZone.secondsFromGMT(for: utc)))
    }

    /// `YYYY-MM-DD`.
    public var description: String {
        "\(Civil.pad(year, 4))-\(Civil.pad(month, 2))-\(Civil.pad(day, 2))"
    }

    /// Order by date.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    static func quoted(_ text: String) -> String {
        "\"\(text.prefix(40))\""
    }
}

/// A time of day without a date or time zone, such as a meal's start time.
///
/// As a model field it accepts `HH:MM[:SS[.fraction]]` strings and Garmin's
/// `{hour, minute, second, nano}` objects.
public struct GarminTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The hour (0 to 23).
    public let hour: Int
    /// The minute (0 to 59).
    public let minute: Int
    /// The second (0 to 59).
    public let second: Int
    /// The nanosecond (0 to 999,999,999).
    public let nanosecond: Int

    /// A validated time of day.
    ///
    /// - Throws: ``InvalidArgumentError`` if a part is out of range.
    public init(hour: Int, minute: Int = 0, second: Int = 0, nanosecond: Int = 0) throws {
        guard (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second),
            (0..<1_000_000_000).contains(nanosecond)
        else {
            throw InvalidArgumentError("\(hour):\(minute):\(second) is not a valid time of day")
        }
        self.init(unchecked: hour, minute, second, nanosecond)
    }

    init(unchecked hour: Int, _ minute: Int, _ second: Int, _ nanosecond: Int) {
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nanosecond = nanosecond
    }

    /// `HH:MM:SS`, with a fraction when there is one.
    public var description: String {
        "\(Civil.pad(hour, 2)):\(Civil.pad(minute, 2)):\(Civil.pad(second, 2))"
            + Civil.fraction(nanosecond)
    }

    /// Order by time of day.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.hour, lhs.minute, lhs.second, lhs.nanosecond)
            < (rhs.hour, rhs.minute, rhs.second, rhs.nanosecond)
    }
}

/// A wall-clock date and time in the user's (or an activity's) time zone.
///
/// Garmin reports `*Local` fields without saying which zone they are in, so this type
/// keeps the wall-clock reading instead of guessing an instant. Use
/// ``date(in:)`` to turn it into a `Date` when you know the zone. If Garmin did send an
/// explicit offset, it is kept in ``utcOffset``.
public struct LocalDateTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The calendar date.
    public let date: GarminDate
    /// The time of day.
    public let time: GarminTime
    /// Seconds east of UTC, only if Garmin sent an explicit offset.
    public let utcOffset: Int?

    /// A wall-clock reading, optionally with a known offset from UTC.
    public init(date: GarminDate, time: GarminTime, utcOffset: Int? = nil) {
        self.date = date
        self.time = time
        self.utcOffset = utcOffset
    }

    /// The instant this wall-clock reading denotes in `timeZone` (or at ``utcOffset``,
    /// when Garmin sent one).
    public func date(in timeZone: TimeZone) -> Date {
        let seconds = Double(Civil.seconds(date, time)) + Double(time.nanosecond) / 1e9
        if let utcOffset {
            return Date(timeIntervalSince1970: seconds - Double(utcOffset))
        }
        let guess = Date(timeIntervalSince1970: seconds)
        let offset = timeZone.secondsFromGMT(for: guess)
        let adjusted = Date(timeIntervalSince1970: seconds - Double(offset))
        return Date(
            timeIntervalSince1970: seconds - Double(timeZone.secondsFromGMT(for: adjusted))
        )
    }

    /// `YYYY-MM-DDTHH:MM:SS`, with a fraction and an offset when there are some.
    public var description: String {
        "\(date)T\(time)" + (utcOffset.map(Civil.offset) ?? "")
    }

    /// Order by wall-clock reading.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.date, lhs.time) < (rhs.date, rhs.time)
    }
}

// MARK: - Lenient decoding

extension GarminDate: Codable {
    /// Decode `YYYY-MM-DD`, an ISO date-time, epoch milliseconds or a `{"localDate"}` object.
    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let date = Self(lenient: value) else {
            throw Lenient.mismatch(decoder, "a date")
        }
        self = date
    }

    /// Encode as `YYYY-MM-DD`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    init?(lenient raw: JSONValue) {
        let value = Lenient.unwrap(raw, "localDate", "date")
        if let milliseconds = Lenient.milliseconds(value) {
            self.init(daysSinceEpoch: Civil.floorDivide(milliseconds, 86_400_000))
            return
        }
        guard case .string(let text) = value else { return nil }
        let bytes = Array(text.utf8)
        if bytes.count > 10, bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " ") {
            self.init(iso: String(decoding: bytes[..<10], as: UTF8.self))
        } else {
            self.init(iso: text)
        }
    }
}

extension GarminTime: Codable {
    /// Decode `HH:MM[:SS]` or a `{hour, minute, second, nano}` object.
    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let time = Self(lenient: value) else {
            throw Lenient.mismatch(decoder, "a time of day")
        }
        self = time
    }

    /// Encode as `HH:MM:SS[.fraction]`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    init?(lenient value: JSONValue) {
        switch value {
        case .object(let parts):
            func part(_ key: String) -> Int {
                if case .integer(let number) = parts[key] { number } else { 0 }
            }
            guard
                let time = try? Self(
                    hour: part("hour"), minute: part("minute"), second: part("second"),
                    nanosecond: part("nano")
                )
            else { return nil }
            self = time
        case .string(let text):
            let bytes = Array(text.utf8)
            guard let (time, end) = ISOParser.time(bytes, at: 0), end == bytes.count else {
                return nil
            }
            self = time
        default:
            return nil
        }
    }
}

extension LocalDateTime: Codable {
    /// Decode an ISO date-time (offset optional) or epoch milliseconds.
    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let dateTime = Self(lenient: value) else {
            throw Lenient.mismatch(decoder, "a date-time")
        }
        self = dateTime
    }

    /// Encode as `YYYY-MM-DDTHH:MM:SS[.fraction][offset]`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    init?(lenient raw: JSONValue) {
        let value = Lenient.unwrap(raw, "date", "localDate")
        // Garmin's "local" epoch values are wall-clock times shifted into UTC, so the
        // same arithmetic yields UTC wall time for GMT fields and local wall time for
        // local fields.
        if let milliseconds = Lenient.milliseconds(value) {
            self = Civil.wallClock(milliseconds: milliseconds)
            return
        }
        guard case .string(let text) = value, let parsed = ISOParser.timestamp(text) else {
            return nil
        }
        self = parsed
    }
}

/// A UTC instant as a model field: ISO date-times (with or without an offset, the latter
/// meaning UTC) and epoch milliseconds decode to a `Date`; it encodes as ISO 8601 in UTC.
struct UTCTimestamp: Codable, Hashable, Sendable {
    let date: Date

    init(_ date: Date) {
        self.date = date
    }

    init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let date = Self.lenient(value) else {
            throw Lenient.mismatch(decoder, "a timestamp")
        }
        self.date = date
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.iso(date))
    }

    static func lenient(_ raw: JSONValue) -> Date? {
        let value = Lenient.unwrap(raw, "date", "localDate")
        if let milliseconds = Lenient.milliseconds(value) {
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
        if case .number(let milliseconds) = value {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        guard case .string(let text) = value, let parsed = ISOParser.timestamp(text) else {
            return nil
        }
        // A timestamp without an offset is UTC.
        let seconds =
            Double(Civil.seconds(parsed.date, parsed.time) - (parsed.utcOffset ?? 0))
            + Double(parsed.time.nanosecond) / 1e9
        return Date(timeIntervalSince1970: seconds)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.mmm]Z`.
    static func iso(_ date: Date) -> String {
        let milliseconds = Int((date.timeIntervalSince1970 * 1000).rounded())
        let wall = Civil.wallClock(milliseconds: milliseconds)
        return "\(wall)Z"
    }
}

// MARK: - Helpers

/// Unwrapping and error reporting for lenient decoding.
enum Lenient {
    static func unwrap(_ value: JSONValue, _ keys: String...) -> JSONValue {
        guard case .object(let members) = value else { return value }
        for key in keys {
            if let member = members[key], member != .null {
                return member
            }
        }
        return value
    }

    /// Whole epoch milliseconds (an integer, or a number without a fractional part).
    static func milliseconds(_ value: JSONValue) -> Int? {
        switch value {
        case .integer(let milliseconds): milliseconds
        case .number(let milliseconds) where milliseconds.rounded() == milliseconds:
            Int(exactly: milliseconds)
        default: nil
        }
    }

    static func mismatch(_ decoder: any Decoder, _ expected: String) -> DecodingError {
        .dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Expected \(expected).")
        )
    }
}

/// Exact proleptic Gregorian calendar arithmetic (after Howard Hinnant's algorithms).
enum Civil {
    static func floorDivide(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    static func days(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = floorDivide(shifted, 400)
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func date(daysSinceEpoch: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = daysSinceEpoch + 719_468
        let era = floorDivide(shifted, 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1 else {
            return false
        }
        let leap =
            year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= lengths[month - 1]
    }

    /// Seconds since the epoch of a wall-clock reading taken as UTC.
    static func seconds(_ date: GarminDate, _ time: GarminTime) -> Int {
        date.daysSinceEpoch * 86_400 + time.hour * 3600 + time.minute * 60 + time.second
    }

    static func wallClock(milliseconds: Int) -> LocalDateTime {
        let days = floorDivide(milliseconds, 86_400_000)
        let rest = milliseconds - days * 86_400_000
        let time = GarminTime(
            unchecked: rest / 3_600_000, rest / 60_000 % 60, rest / 1000 % 60,
            rest % 1000 * 1_000_000
        )
        return LocalDateTime(date: GarminDate(daysSinceEpoch: days), time: time)
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// `.fraction` without trailing zeros, or nothing for whole seconds.
    static func fraction(_ nanosecond: Int) -> String {
        guard nanosecond > 0 else { return "" }
        var digits = pad(nanosecond, 9)
        while digits.hasSuffix("0") {
            digits.removeLast()
        }
        return "." + digits
    }

    static func offset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return "\(sign)\(pad(minutes / 60, 2)):\(pad(minutes % 60, 2))"
    }
}

/// Byte-level parsing of ISO 8601 dates, times and timestamps.
enum ISOParser {
    static func number(_ bytes: [UInt8], at start: Int, digits: Int) -> Int? {
        guard start + digits <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[start..<start + digits] {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    static func date(_ bytes: [UInt8], at start: Int) -> (Int, Int, Int)? {
        guard bytes.count >= start + 10, bytes[start + 4] == UInt8(ascii: "-"),
            bytes[start + 7] == UInt8(ascii: "-"),
            let year = number(bytes, at: start, digits: 4),
            let month = number(bytes, at: start + 5, digits: 2),
            let day = number(bytes, at: start + 8, digits: 2)
        else { return nil }
        return (year, month, day)
    }

    /// `HH:MM[:SS[.fraction]]` starting at `start`; returns the time and the end index.
    static func time(_ bytes: [UInt8], at start: Int) -> (GarminTime, Int)? {
        guard bytes.count >= start + 5, bytes[start + 2] == UInt8(ascii: ":"),
            let hour = number(bytes, at: start, digits: 2),
            let minute = number(bytes, at: start + 3, digits: 2)
        else { return nil }
        var index = start + 5
        var second = 0
        var nanosecond = 0
        if index < bytes.count, bytes[index] == UInt8(ascii: ":") {
            guard let value = number(bytes, at: index + 1, digits: 2) else { return nil }
            second = value
            index += 3
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                var scale = 100_000_000
                let first = index
                while index < bytes.count, let digit = number(bytes, at: index, digits: 1) {
                    nanosecond += digit * scale
                    scale /= 10
                    index += 1
                }
                guard index > first else { return nil }
            }
        }
        guard
            let time = try? GarminTime(
                hour: hour, minute: minute, second: second, nanosecond: nanosecond)
        else { return nil }
        return (time, index)
    }

    /// What follows a time: nothing, a UTC offset, or something unparseable.
    enum Offset {
        case absent
        case seconds(Int)
        case invalid
    }

    /// `Z`, `±HH`, `±HHMM` or `±HH:MM` at the end of `bytes`.
    static func offset(_ bytes: [UInt8], at start: Int) -> Offset {
        guard start < bytes.count else { return .absent }
        let sign = bytes[start]
        if sign == UInt8(ascii: "Z") || sign == UInt8(ascii: "z") {
            return start + 1 == bytes.count ? .seconds(0) : .invalid
        }
        guard sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-"),
            let hours = number(bytes, at: start + 1, digits: 2)
        else { return .invalid }
        var minutes: Int?
        switch bytes.count - start {
        case 3: minutes = 0
        case 5: minutes = number(bytes, at: start + 3, digits: 2)
        case 6 where bytes[start + 3] == UInt8(ascii: ":"):
            minutes = number(bytes, at: start + 4, digits: 2)
        default: minutes = nil
        }
        guard let minutes, hours < 24, minutes < 60 else { return .invalid }
        let seconds = hours * 3600 + minutes * 60
        return .seconds(sign == UInt8(ascii: "-") ? -seconds : seconds)
    }

    /// `YYYY-MM-DD[(T| )HH:MM[:SS[.fraction]]][offset]`.
    static func timestamp(_ text: String) -> LocalDateTime? {
        let bytes = Array(text.utf8)
        guard let (year, month, day) = date(bytes, at: 0),
            Civil.isValid(year: year, month: month, day: day)
        else { return nil }
        let calendarDate = GarminDate(unchecked: year, month, day)
        guard bytes.count > 10 else {
            return LocalDateTime(date: calendarDate, time: GarminTime(unchecked: 0, 0, 0, 0))
        }
        guard bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " "),
            let (time, end) = time(bytes, at: 11)
        else { return nil }
        switch offset(bytes, at: end) {
        case .absent: return LocalDateTime(date: calendarDate, time: time)
        case .seconds(let seconds):
            return LocalDateTime(date: calendarDate, time: time, utcOffset: seconds)
        case .invalid: return nil
        }
    }
}
