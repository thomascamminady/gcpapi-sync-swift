/// A calendar date argument: a ``GarminDate`` or a `YYYY-MM-DD` string.
///
/// Strings are validated when the method is called, before any request is made.
public protocol DateLike: Sendable {
    /// The date this value denotes.
    ///
    /// - Parameter argument: The parameter name, for error messages.
    /// - Throws: ``InvalidArgumentError`` if the value is not a valid date.
    /// - Returns: The date.
    func garminDate(argument: String) throws -> GarminDate
}

extension GarminDate: DateLike {
    /// The date itself.
    public func garminDate(argument _: String) -> GarminDate { self }
}

extension String: DateLike {
    /// The date in this `YYYY-MM-DD` string.
    public func garminDate(argument: String) throws -> GarminDate {
        guard let date = GarminDate(iso: self) else {
            throw InvalidArgumentError(
                "\(argument) must be a YYYY-MM-DD date, got \(GarminDate.quoted(self))"
            )
        }
        return date
    }
}

/// Date argument handling and range splitting.
enum DateRange {
    /// Convert and validate an inclusive date range.
    ///
    /// - Throws: ``InvalidArgumentError`` if a date is malformed or `start` is after `end`.
    static func resolve(
        _ start: some DateLike, _ end: some DateLike
    ) throws -> (
        GarminDate, GarminDate
    ) {
        let first = try start.garminDate(argument: "start")
        let last = try end.garminDate(argument: "end")
        guard first <= last else {
            throw InvalidArgumentError("start (\(first)) must not be after end (\(last))")
        }
        return (first, last)
    }

    /// Split the inclusive range `start...end` into consecutive windows of at most
    /// `maxDays` days.
    static func windows(
        _ start: GarminDate, _ end: GarminDate, maxDays: Int
    ) throws
        -> [(GarminDate, GarminDate)]
    {
        guard maxDays >= 1 else {
            throw InvalidArgumentError("maxDays must be at least 1")
        }
        var result: [(GarminDate, GarminDate)] = []
        var current = start
        while current <= end {
            let last = min(current.adding(days: maxDays - 1), end)
            result.append((current, last))
            current = last.adding(days: 1)
        }
        return result
    }
}
