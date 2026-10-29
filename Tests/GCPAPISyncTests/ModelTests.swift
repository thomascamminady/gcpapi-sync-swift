import Foundation
import Testing

@testable import GCPAPISync

private func utcValue(_ raw: JSONValue) throws -> Date {
    try decode(UTCTimestamp.self, raw).date
}

@Suite struct LenientScalarTests {
    @Test(arguments: [
        ("2026-10-21T07:15:54.0", 0), ("2026-10-21 07:15:54", 0), ("2026-10-21T09:15:54+02:00", 0),
        ("2026-10-21T07:15:54Z", 0), ("2026-10-21T08:15:54+0100", 0), ("2026-10-21T04:15:54-03", 0),
    ])
    func utcStrings(raw: String, _: Int) throws {
        #expect(try utcValue(.string(raw)) == utc(2026, 10, 21, 7, 15, 54))
    }

    @Test func utcNumbersAndObjects() throws {
        #expect(try utcValue(1_792_559_461_000) == utc(2026, 10, 21, 5, 11, 1))
        let fractional = try utcValue(1_792_559_461_123.0)
        #expect(abs(fractional.timeIntervalSince(utc(2026, 10, 21, 5, 11, 1)) - 0.123) < 1e-6)
        #expect(try utcValue(.number(1_792_559_461_123.5)) > utc(2026, 10, 21, 5, 11, 1))
        #expect(
            try utcValue(["date": "2026-10-21T07:15:54.0", "localDate": "2026-10-21"])
                == utc(2026, 10, 21, 7, 15, 54))
        #expect(try utcValue("2026-10-21") == utc(2026, 10, 21))
    }

    @Test func utcEncodesISO() throws {
        let encoded = try JSONEncoder().encode([
            UTCTimestamp(utc(2026, 1, 15, 8).addingTimeInterval(0.25))
        ])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["2026-01-15T08:00:00.25Z"]"#)
    }

    @Test(arguments: [
        ("2026-10-21T09:15:54.0", 1_792_566_954_000), ("2026-10-21T07:11:01", 1_792_566_661_000),
    ])
    func localDateTimeIsWallTime(raw: String, milliseconds: Int) throws {
        let parsed = try decode(LocalDateTime.self, .string(raw))
        #expect(parsed.utcOffset == nil)
        #expect(parsed.description == raw.replacingOccurrences(of: ".0", with: ""))
        let fromNumber = try decode(LocalDateTime.self, .integer(milliseconds))
        #expect(fromNumber.date.description == "2026-10-21")
    }

    @Test func localDateTimeKeepsExplicitOffsets() throws {
        let parsed = try decode(LocalDateTime.self, "2026-10-21T09:15:54+02:00")
        #expect(parsed.utcOffset == 7200)
        #expect(
            parsed.date(in: .gmt) == utc(2026, 10, 21, 7, 15, 54)
        )
        #expect(
            try decode(LocalDateTime.self, "2026-10-21T09:15:54.5Z").time.nanosecond == 500_000_000)
    }

    @Test(
        arguments: [
            "2026-10-21", "2026-10-21T00:00:00.0", "2026-10-21 13:00:00",
        ] as [JSONValue] + [
            1_792_540_800_000, 1_792_540_800_000.0,
            ["localDate": "2026-10-21", "date": "2026-10-20T22:00:00.0"],
            ["date": "2026-10-21"],
        ])
    func garminDate(raw: JSONValue) throws {
        #expect(try decode(GarminDate.self, raw) == (try GarminDate("2026-10-21")))
    }

    @Test(arguments: [
        ("07:00:00", "07:00:00"), ("18:59", "18:59:00"), ("18:59:01.5", "18:59:01.5"),
    ])
    func garminTimeStrings(raw: String, expected: String) throws {
        #expect(try decode(GarminTime.self, .string(raw)).description == expected)
    }

    @Test func garminTimeObjects() throws {
        let full = try decode(
            GarminTime.self, ["hour": 18, "minute": 59, "second": 1, "nano": 5_000_000])
        #expect(full == (try GarminTime(hour: 18, minute: 59, second: 1, nanosecond: 5_000_000)))
        #expect(full.description == "18:59:01.005")
        #expect(
            try decode(GarminTime.self, ["hour": 6, "minute": nil, "second": true])
                == (try GarminTime(hour: 6)))
    }

    @Test(
        arguments: [
            true, "soon", ["date": nil, "localDate": nil], "2026-10-21T25:00:00", "2026-10-21Tnoon",
            "2026-10-21T07:15:54+2", "2026-10-21T07:15:54Zulu", "2026-10-21T07:15:54+25:00",
            "2026-10-21T07:15:54.", "2026-10-21T07:15:5", "2026-10-21X07:15:54",
        ] as [JSONValue])
    func utcRejectsGarbage(raw: JSONValue) {
        #expect(throws: DecodingError.self) { try utcValue(raw) }
    }

    @Test(arguments: [false, "today", 1.5, "2026-13-01"] as [JSONValue])
    func dateRejectsGarbage(raw: JSONValue) {
        #expect(throws: DecodingError.self) { try decode(GarminDate.self, raw) }
    }

    @Test(arguments: ["7:00", "07:00:00Z", 7, ["hour": 25]] as [JSONValue])
    func timeRejectsGarbage(raw: JSONValue) {
        #expect(throws: DecodingError.self) { try decode(GarminTime.self, raw) }
    }

    @Test func localRejectsGarbage() {
        #expect(throws: DecodingError.self) { try decode(LocalDateTime.self, "later") }
    }

    @Test func scalarsRoundTrip() throws {
        let values: [JSONValue] = ["2026-10-21", "08:00:00", "2026-10-21T08:00:00+02:00"]
        #expect(try decode(GarminDate.self, values[0]).description == "2026-10-21")
        let encoded = try JSONEncoder().encode([
            try decode(LocalDateTime.self, values[2])
        ])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["2026-10-21T08:00:00+02:00"]"#)
        let time = try JSONEncoder().encode([try decode(GarminTime.self, values[1])])
        #expect(String(decoding: time, as: UTF8.self) == #"["08:00:00"]"#)
    }
}

@Suite struct JSONValueTests {
    @Test func decodesEveryKind() throws {
        let value = try decode(
            JSONValue.self, json: #"{"a": [1, 1.5, "s", true, null, {"b": {}}]}"#)
        #expect(value == ["a": [1, 1.5, "s", true, nil, ["b": [:]]]])
        #expect(value["a"]?.arrayValue?.count == 6)
        #expect(value["a"]?.arrayValue?[2].stringValue == "s")
        #expect(value["a"]?.arrayValue?[0].doubleValue == 1)
        #expect(value["a"]?.arrayValue?[1].doubleValue == 1.5)
        #expect(value["a"]?.arrayValue?[3].doubleValue == nil)
        #expect(value.objectValue?.keys.sorted() == ["a"])
        #expect(JSONValue.string("x").objectValue == nil)
        #expect(JSONValue.string("x").arrayValue == nil)
        #expect(JSONValue.integer(1).stringValue == nil)
        #expect(JSONValue.integer(1)["key"] == nil)
        let reencoded = try decode(
            JSONValue.self, json: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
        #expect(reencoded == value)
        #expect(JSONValue(dictionaryLiteral: ("k", 1), ("k", 2)) == ["k": 2])
    }
}

private var fixtureTypes: [(String, any Decodable.Type)] {
    [
        ("activity", ActivitySummary.self),
        ("daily_body_battery", [BodyBatteryDailyReport].self),
        ("daily_food_logs", DailyNutritionSummary.self),
        ("daily_heart_rate", DailyHeartRate.self),
        ("daily_hrv", HrvChart.self),
        ("daily_hrv_summaries", HrvDailySummary.self),
        ("daily_sleep", DailySleep.self),
        ("daily_sleep_summaries", [DailySleep].self),
        ("daily_spo2", DailySpO2AndAcclimation.self),
        ("daily_steps", [StepsDailyStat].self),
        ("daily_stress", [MultiValueWellnessChartItem].self),
        ("daily_summaries", UserDailySummaryV2List.self),
        ("daily_summary", UserDailySummary.self),
        ("effective_weight_goals", UserGoalsRange.self),
        ("fitness_age", FitnessAge.self),
        ("heart_rate_zones", [HeartRateZones].self),
        ("search_activities", [SummarizedActivity].self),
        ("user_profile_settings", UserSettings.self),
        ("weight_range", WeightRange.self),
        ("wellness_activity_summaries", [WellnessActivitySummary].self),
    ]
}

private func roundTrip<T: Codable>(_ type: T.Type, _ data: Data) throws -> (T, Data, Data) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let parsed = try JSONDecoder().decode(type, from: data)
    let dumped = try encoder.encode(parsed)
    let again = try encoder.encode(try JSONDecoder().decode(type, from: dumped))
    return (parsed, dumped, again)
}

private func undocumented(_ value: Any) -> Set<String> {
    UndocumentedFields.collect(value, path: String(describing: type(of: value)))
}

@Suite struct FixtureTests {
    @Test(arguments: fixtureTypes.map(\.0))
    func fixtureParsesAndRoundTrips(name: String) throws {
        let type = try #require(fixtureTypes.first { $0.0 == name }?.1)
        func check<T: Decodable>(_: T.Type) throws {
            let codable = try #require(T.self as? any Codable.Type)
            try open(codable)
        }
        func open<T: Codable>(_: T.Type) throws {
            let (parsed, dumped, again) = try roundTrip(T.self, try fixture(name))
            #expect(dumped == again)
            #expect(undocumented(parsed).isEmpty, "fixture contains fields the models do not know")
        }
        try check(type)
    }

    @Test func convertedFieldsInFixtures() throws {
        let activity = try JSONDecoder().decode(ActivitySummary.self, from: try fixture("activity"))
        let summary = try #require(activity.summary)
        #expect(summary.startTimeGMT != nil)
        #expect(summary.startTimeLocal?.utcOffset == nil)

        let sleep = try JSONDecoder().decode(DailySleep.self, from: try fixture("daily_sleep"))
        #expect(sleep.calendarDate != nil)
        #expect(sleep.sleepStartTimestampGMT != nil)
        #expect(sleep.sleepScores?.overall != nil)

        let stress = try JSONDecoder().decode(
            [MultiValueWellnessChartItem].self, from: try fixture("daily_stress"))
        #expect(stress.first?.values?.overallStressLevel != nil)

        let nutrition = try JSONDecoder().decode(
            DailyNutritionSummary.self, from: try fixture("daily_food_logs"))
        #expect(nutrition.dayStartTime != nil)

        let age = try JSONDecoder().decode(FitnessAge.self, from: try fixture("fitness_age"))
        #expect(age.components?.rhr != nil)
        #expect(age.lastUpdated != nil)
    }
}

@Suite struct GeneratedModelTests {
    @Test func everyModelIsListedOnce() {
        let names = allModelTypes.map { String(describing: $0) }
        #expect(names.count == 109)
        #expect(Set(names).count == names.count)
        #expect(names == names.sorted())
        #expect(modelSamples.map { String(describing: $0.type) } == names)
    }

    @Test(arguments: modelSamples.indices)
    func everyFieldAcceptsItsDocumentedType(index: Int) throws {
        let sample = modelSamples[index]
        func check<T: GarminModel>(_: T.Type) throws {
            let instance = try decode(T.self, sample.full)
            let mirror = Mirror(reflecting: instance)
            for child in mirror.children where child.label != "extraFields" {
                let value = Mirror(reflecting: child.value)
                #expect(
                    value.displayStyle != .optional || !value.children.isEmpty,
                    "\(T.self).\(child.label ?? "?") is nil")
            }
            #expect(instance.extraFields.isEmpty)
            let copy = try #require(sample.rebuild(instance) as? T)
            #expect(copy == instance)
            #expect(sample.rebuild(Placeholder()) == nil)
            #expect(
                try decode(
                    T.self,
                    try decode(
                        JSONValue.self,
                        json: String(decoding: try JSONEncoder().encode(instance), as: UTF8.self)))
                    == instance)

            let minimal = try decode(T.self, sample.minimal)
            let filled = Mirror(reflecting: minimal).children.filter { child in
                let value = Mirror(reflecting: child.value)
                return value.displayStyle == .optional && !value.children.isEmpty
            }
            #expect(filled.isEmpty, "only identifiers may be required")
        }
        try check(sample.type)
    }

    @Test func onlyActivityIdentifiersAreRequired() {
        for sample in modelSamples where sample.minimal.objectValue?.isEmpty == false {
            #expect(sample.minimal == ["activityId": 7])
            #expect(
                ["ActivitySummary", "SummarizedActivity"].contains(String(describing: sample.type)))
        }
    }

    @Test func propertyNamesMapToGarminsKeys() throws {
        let summary = try decode(
            SummarizedActivity.self,
            ["activityId": 1, "fastestSplit_1000": 200.5, "hrTimeInZone_1": 30.0])
        #expect(summary.fastestSplit1000 == 200.5)
        #expect(summary.hrTimeInZone1 == 30)
        let encoded = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        #expect(encoded.contains("fastestSplit_1000"))
        let activity = try decode(
            ActivitySummary.self, ["activityId": 1, "summaryDTO": ["distance": 5.0]])
        #expect(activity.summary?.distance == 5)
    }

    @Test func unknownFieldsAreKept() throws {
        let parsed = try decode(StepsDailyStat.self, ["totalSteps": 5, "brandNewField": [1, 2]])
        #expect(parsed.extraFields == ["brandNewField": [1, 2]])
        #expect(parsed.undocumentedFields == ["StepsDailyStat.brandNewField"])
        let encoded = try decode(
            JSONValue.self, json: String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self))
        #expect(encoded == ["totalSteps": 5, "brandNewField": [1, 2]])
        let empty = try decode(ApplicationFormat.self, ["anything": true])
        #expect(empty.extraFields == ["anything": true])
        #expect(
            try decode(
                JSONValue.self,
                json: String(decoding: try JSONEncoder().encode(empty), as: UTF8.self)) == [
                    "anything": true
                ])
    }

    @Test func undocumentedFieldsAreFoundInNestedModels() throws {
        let sleep = try decode(
            DailySleep.self,
            ["sleepScores": ["overall": ["value": 80, "secret": 1]], "retro": nil])
        #expect(sleep.undocumentedFields == ["DailySleep.sleepScores.overall.secret"])
        let list = try decode(
            HrvDailySummary.self, ["hrvSummaries": [["calendarDate": "2026-10-21", "x": 1]]])
        #expect(list.undocumentedFields == ["HrvDailySummary.hrvSummaries.x"])
    }

    @Test func modelsAreValueTypesWithMemberwiseInitializers() {
        var stat = StepsDailyStat(totalSteps: 5)
        stat.stepGoal = 10
        #expect(stat == StepsDailyStat(totalSteps: 5, stepGoal: 10))
        #expect(SummarizedActivity(activityId: 3).activityId == 3)
    }
}

@Suite struct SeriesTests {
    @Test func heartRateSamples() throws {
        let heartRate = try decode(
            DailyHeartRate.self,
            [
                "heartRateValueDescriptors": [
                    ["key": "heartrate", "index": 0], ["key": "timestamp", "index": 1],
                ],
                "heartRateValues": [
                    [42, 1_792_533_600_000], [nil, 1_792_533_720_000], [50, nil], [61],
                ],
                "abnormalHRValuesArray": [[150, 1_792_533_600_000]],
            ])
        #expect(
            heartRate.heartRateSamples() == [
                HeartRateSample(timestamp: utc(2026, 10, 20, 22), heartRate: 42),
                HeartRateSample(timestamp: utc(2026, 10, 20, 22, 2), heartRate: nil),
            ])
        #expect(heartRate.abnormalHeartRateSamples().first?.heartRate == 150)
    }

    @Test func seriesDefaultToTimestampThenValue() throws {
        let heartRate = try decode(
            DailyHeartRate.self, ["heartRateValues": [[1_792_533_600_000, 42.4]]])
        #expect(heartRate.heartRateSamples().first?.heartRate == 42)
        #expect(DailyHeartRate().heartRateSamples().isEmpty)
    }

    @Test func bodyBatterySamplesFromFixture() throws {
        let reports = try JSONDecoder().decode(
            [BodyBatteryDailyReport].self, from: try fixture("daily_body_battery"))
        let samples = try #require(reports.first).bodyBatterySamples()
        #expect(!samples.isEmpty)
        #expect(samples.contains { $0.level != nil })
    }

    @Test func spo2Samples() throws {
        let spo2 = try decode(
            DailySpO2AndAcclimation.self,
            [
                "spO2HourlyAveragesDescriptorList": [
                    ["spo2ValueDescIndex": 0, "spo2ValueDescKey": "timestamp"],
                    ["spo2ValueDescIndex": 1, "spo2ValueDescKey": "spo2Level"],
                    ["spo2ValueDescIndex": 2, "spo2ValueDescKey": "monitoringEnvironmentLevel"],
                ],
                "spO2HourlyAverages": [[1_792_533_600_000, 95, 61.6]],
                "spO2SingleValuesDescriptorList": [
                    ["spo2ValueDescriptorIndex": 1, "spo2ValueDescriptorKey": "spo2Reading"],
                    ["spo2ValueDescriptorIndex": 0, "spo2ValueDescriptorKey": "timestamp"],
                ],
                "spO2SingleValues": [[1_792_533_600_000, 97]],
                "monitoringEnvironmentValuesDescriptorList": [
                    ["monEnvValueDescIndex": 0, "monEnvValueDescKey": "timestamp"],
                    [
                        "monEnvValueDescIndex": 1,
                        "monEnvValueDescKey": "monitoringEnvironmentLevel",
                    ],
                ],
                "monitoringEnvironmentValues": [[1_792_533_600_000, 62]],
            ])
        let when = utc(2026, 10, 20, 22)
        #expect(
            spo2.spo2HourlySamples() == [
                SpO2Sample(timestamp: when, spo2: 95, monitoringEnvironmentLevel: 61.6)
            ])
        #expect(
            spo2.spo2SingleSamples() == [
                SpO2Sample(timestamp: when, spo2: 97, monitoringEnvironmentLevel: nil)
            ])
        #expect(
            spo2.monitoringEnvironmentSamples() == [
                MonitoringEnvironmentSample(timestamp: when, level: 62)
            ])
    }
}

/// A model of no generated type, to exercise the type checks.
private struct Placeholder: GarminModel {
    var extraFields: [String: JSONValue] = [:]
}

/// A model using the helpers for lists of UTC timestamps, which Garmin's spec does not
/// need today but the generator supports.
private struct TimestampList: Codable, Equatable {
    var stamps: [Date]?

    enum CodingKeys: String, CodingKey {
        case stamps
    }

    init(stamps: [Date]?) {
        self.stamps = stamps
    }

    init(from decoder: any Decoder) throws {
        stamps = try decoder.container(keyedBy: CodingKeys.self).decodeUTCList(.stamps)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeUTCList(stamps, forKey: .stamps)
    }
}

@Suite struct CodingHelperTests {
    @Test func utcLists() throws {
        let parsed = try decode(
            TimestampList.self, ["stamps": [1_792_533_600_000, "2026-10-20T22:00:00Z"]])
        #expect(parsed.stamps == [utc(2026, 10, 20, 22), utc(2026, 10, 20, 22)])
        let encoded = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
        #expect(encoded == #"{"stamps":["2026-10-20T22:00:00Z","2026-10-20T22:00:00Z"]}"#)
        #expect(try decode(TimestampList.self, [:]).stamps == nil)
    }

    @Test func codingKeysAreNamesOnly() {
        #expect(AnyCodingKey(intValue: 1) == nil)
        #expect(AnyCodingKey(stringValue: "x")?.intValue == nil)
    }

    @Test func wholeMillisecondsFromFloatingPoint() {
        #expect(Lenient.milliseconds(.number(5)) == 5)
        #expect(Lenient.milliseconds(.number(5.5)) == nil)
        #expect(Lenient.milliseconds(.string("5")) == nil)
    }

    @Test(arguments: [
        "2026-10-21T07:15:54+020", "2026-10-21T07:15:54+0", "2026-10-21T07:15:54+02:60",
    ])
    func malformedOffsets(text: String) {
        #expect(ISOParser.timestamp(text) == nil)
    }

    @Test func seriesWithoutData() throws {
        #expect(DailySpO2AndAcclimation().spo2HourlySamples().isEmpty)
        #expect(DailySpO2AndAcclimation().spo2SingleSamples().isEmpty)
        #expect(DailySpO2AndAcclimation().monitoringEnvironmentSamples().isEmpty)
        #expect(BodyBatteryDailyReport().bodyBatterySamples().isEmpty)
        #expect(DailyHeartRate().abnormalHeartRateSamples().isEmpty)
        let partial = try decode(
            DailyHeartRate.self,
            [
                "heartRateValueDescriptors": [["key": nil, "index": 0]],
                "heartRateValues": [[1_792_533_600_000, 60]],
            ])
        #expect(partial.heartRateSamples().first?.heartRate == 60)
    }
}
