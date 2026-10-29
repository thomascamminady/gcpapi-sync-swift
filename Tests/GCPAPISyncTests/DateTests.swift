import Foundation
import Testing

@testable import GCPAPISync

@Suite struct DateArgumentTests {
    @Test func acceptsDatesAndISOStrings() throws {
        let expected = try GarminDate(year: 2026, month: 10, day: 21)
        #expect(expected.garminDate(argument: "day") == expected)
        #expect(try "2026-10-21".garminDate(argument: "day") == expected)
        #expect(try GarminDate("2026-10-21") == expected)
    }

    @Test(arguments: [
        "2026/10/21", "21.10.2026", "", "yesterday", "2026-02-30", "2026-10-21T00:00",
    ])
    func rejectsMalformedStrings(value: String) {
        let error = #expect(throws: InvalidArgumentError.self) {
            try value.garminDate(argument: "day")
        }
        #expect(error?.message.hasPrefix("day must be a YYYY-MM-DD date") == true)
        #expect(throws: InvalidArgumentError.self) { try GarminDate(value) }
    }

    @Test(arguments: [(2026, 13, 1), (2026, 0, 1), (2026, 2, 29), (0, 1, 1), (2026, 4, 31)])
    func rejectsInvalidParts(year: Int, month: Int, day: Int) {
        #expect(throws: InvalidArgumentError.self) {
            try GarminDate(year: year, month: month, day: day)
        }
    }

    @Test func leapYears() throws {
        _ = try GarminDate(year: 2024, month: 2, day: 29)
        _ = try GarminDate(year: 2000, month: 2, day: 29)
        #expect(throws: InvalidArgumentError.self) { try GarminDate(year: 1900, month: 2, day: 29) }
    }

    @Test func resolve() throws {
        let (first, last) = try DateRange.resolve("2026-10-01", try GarminDate("2026-10-01"))
        #expect(first == last)
        let error = #expect(throws: InvalidArgumentError.self) {
            try DateRange.resolve("2026-10-02", "2026-10-01")
        }
        #expect(error?.message.contains("must not be after") == true)
    }

    @Test func windowsExamples() throws {
        let start = try GarminDate("2026-01-01")
        #expect(
            try DateRange.windows(start, start, maxDays: 28).map { "\($0.0)/\($0.1)" } == [
                "2026-01-01/2026-01-01"
            ])
        #expect(
            try DateRange.windows(start, start.adding(days: 2), maxDays: 2).map {
                "\($0.0)/\($0.1)"
            } == [
                "2026-01-01/2026-01-02", "2026-01-03/2026-01-03",
            ])
        #expect(throws: InvalidArgumentError.self) {
            try DateRange.windows(start, start, maxDays: 0)
        }
    }

    @Test(arguments: [1, 7, 28, 31, 365], [1, 2, 27, 28, 29, 31, 32, 365, 366, 1000])
    func windowsPartitionTheRange(maxDays: Int, length: Int) throws {
        let start = try GarminDate("2024-02-20")
        let end = start.adding(days: length - 1)
        let spans = try DateRange.windows(start, end, maxDays: maxDays)
        #expect(spans.first?.0 == start)
        #expect(spans.last?.1 == end)
        for (previous, next) in zip(spans, spans.dropFirst()) {
            #expect(next.0 == previous.1.adding(days: 1))
        }
        #expect(spans.allSatisfy { (1...maxDays).contains($0.0.days(to: $0.1) + 1) })
        #expect(spans.count == (length + maxDays - 1) / maxDays)
    }
}

@Suite struct CalendarTests {
    @Test func civilRoundTrip() {
        for days in stride(from: -800_000, through: 2_900_000, by: 997) {
            let (year, month, day) = Civil.date(daysSinceEpoch: days)
            #expect(Civil.days(year: year, month: month, day: day) == days)
        }
        #expect(Civil.days(year: 1970, month: 1, day: 1) == 0)
        #expect(Civil.days(year: 2000, month: 3, day: 1) == 11_017)
        #expect(Civil.floorDivide(-1, 86_400) == -1)
    }

    @Test func garminDateArithmeticAndConversions() throws {
        let date = try GarminDate("2026-10-21")
        #expect(date.adding(days: 11) == (try GarminDate("2026-11-01")))
        #expect(date.days(to: try GarminDate("2026-10-01")) == -20)
        #expect(date < date.adding(days: 1))
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        #expect(date.startOfDay(in: berlin) == utc(2026, 10, 20, 22))
        #expect(GarminDate(utc(2026, 10, 20, 22, 30), in: berlin) == date)
        #expect(
            GarminDate(utc(2026, 10, 20, 22, 30), in: .gmt)
                == date.adding(days: -1))
        #expect(GarminDate.today(in: berlin) == GarminDate(Date(), in: berlin))
        #expect("\(try GarminDate(year: 33, month: 1, day: 5))" == "0033-01-05")
    }

    @Test func localDateTimeInTimeZones() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let summer = LocalDateTime(
            date: try GarminDate("2026-07-01"), time: try GarminTime(hour: 12))
        #expect(summer.date(in: berlin) == utc(2026, 7, 1, 10))
        let winter = LocalDateTime(
            date: try GarminDate("2026-01-01"), time: try GarminTime(hour: 12))
        #expect(winter.date(in: berlin) == utc(2026, 1, 1, 11))
        let offset = LocalDateTime(
            date: try GarminDate("2026-01-01"), time: try GarminTime(hour: 12), utcOffset: -3600)
        #expect(offset.date(in: berlin) == utc(2026, 1, 1, 13))
        #expect("\(offset)" == "2026-01-01T12:00:00-01:00")
        #expect(summer < winter.date.adding(days: 365).midnight)
        #expect(throws: InvalidArgumentError.self) { try GarminTime(hour: 24) }
        #expect(try GarminTime(hour: 7) < GarminTime(hour: 7, minute: 0, second: 0, nanosecond: 1))
    }
}

extension GarminDate {
    var midnight: LocalDateTime {
        LocalDateTime(date: self, time: GarminTime(unchecked: 0, 0, 0, 0))
    }
}
