import Foundation
import Testing

@testable import GCPAPISync

private func response(_ body: Data, status: Int = 200) -> HTTPResponse {
    HTTPResponse(
        statusCode: status, body: body,
        request: HTTPRequest(method: "GET", url: URL(fileURLWithPath: "/x"), headers: [:]))
}

@Suite struct EndpointTests {
    @Test func everyActivityFilterIsTranslated() throws {
        let filters = ActivityFilters(
            startDate: try GarminDate(year: 2026, month: 1, day: 1), endDate: "2026-01-31",
            activityType: "running", activitySubtype: "trail_running",
            excludedActivitySubtypes: ["treadmill_running", "track_running"], eventType: "race",
            search: "marathon", favorite: true, sortBy: "distance", sortOrder: .asc,
            excludeChildren: false, minDistance: 1000, maxDistance: 42_195, minDuration: 60,
            maxDuration: 7200, minElapsedDuration: 61, maxElapsedDuration: 7201, minElevation: 10,
            maxElevation: 2000, minAvgPower: 200,
            boundingBox: BoundingBox(north: 51.0, east: 7.5, south: 50.5, west: 6.5),
            lowerMaxDepth: 100, upperMaxDepth: 3000, decoDive: true, minBottomTime: 30,
            maxBottomTime: 3600, requiredFields: ["avgPower"]
        )
        let items = try filters.queryItems()
        #expect(
            items.map { "\($0.name)=\($0.value)" } == [
                "startDate=2026-01-01", "endDate=2026-01-31", "favorite=1", "upperLatitude=51.0",
                "rightLongitude=7.5", "lowerLatitude=50.5", "leftLongitude=6.5",
                "excludeChildren=false", "decoDive=true",
                "excludedActivitySubType=treadmill_running",
                "excludedActivitySubType=track_running",
                "requiredField=avgPower", "activityType=running", "activitySubType=trail_running",
                "eventType=race", "search=marathon", "sortBy=distance", "sortOrder=asc",
                "minDistance=1000", "maxDistance=42195", "minDuration=60", "maxDuration=7200",
                "minElapsedDuration=61", "maxElapsedDuration=7201", "minElevation=10",
                "maxElevation=2000", "minAvgPower=200", "lowerMaxDepth=100", "upperMaxDepth=3000",
                "minBottomTime=30", "maxBottomTime=3600",
            ])
        #expect(try ActivityFilters().queryItems().isEmpty)
    }

    @Test func favoriteFalse() throws {
        #expect(try ActivityFilters(favorite: false).queryItems() == [QueryItem("favorite", "0")])
    }

    @Test func malformedDateFiltersAreRejected() {
        let error = #expect(throws: InvalidArgumentError.self) {
            try ActivityFilters(endDate: "yesterday").queryItems()
        }
        #expect(error?.message.contains("endDate must be a YYYY-MM-DD date") == true)
    }

    @Test(arguments: [0, -5])
    func activityIDsMustBePositive(value: Int) {
        let error = #expect(throws: InvalidArgumentError.self) { try Endpoints.activity(value) }
        #expect(error?.message.contains("positive") == true)
    }

    @Test(arguments: ["sleep", "//evil.example/x", "https://evil.example/x", "/x?u=https://e"])
    func getJSONOnlyAllowsPathsOnTheAPIHost(path: String) {
        let error = #expect(throws: InvalidArgumentError.self) {
            try Endpoints.json(path, query: [])
        }
        #expect(error?.message.contains("absolute path") == true)
    }

    @Test func bodyBatteryChunksMustBePositive() throws {
        let error = #expect(throws: InvalidArgumentError.self) {
            try Endpoints.dailyBodyBattery(
                try GarminDate("2026-01-01"), try GarminDate("2026-01-02"), chunks: 0)
        }
        #expect(error?.message.contains("chunks") == true)
    }

    @Test func menstrualDayViewWithoutToday() throws {
        let endpoint = try Endpoints.menstrualCycleDayView(
            "2026-10-21", today: nil, reducedResponse: true, skipBabyMovement: true,
            includeAnalysis: false)
        #expect(
            endpoint.query == [
                QueryItem("reducedResponse", "true"), QueryItem("skipbm", "true"),
                QueryItem("includeAnalysis", "false"),
            ])
    }

    @Test func foodLogsWithoutMeal() throws {
        let endpoint = try Endpoints.dailyFoodLogs(
            "2026-10-21", includeGoals: false, includeNutrition: false, includeMedia: false,
            mealID: nil)
        #expect(!endpoint.query.contains { $0.name == "mealId" })
        #expect(endpoint.query.first == QueryItem("includeGoals", "false"))
    }

    @Test func downloadParsers() throws {
        let archive = zipArchive([("5_ACTIVITY.fit", Data("fit".utf8))])
        #expect(try Endpoints.downloadActivityZip(5).parse(response(archive)) == archive)
        #expect(
            try Endpoints.downloadActivity(5).parse(response(archive)).content == Data("fit".utf8))
        let empty = #expect(throws: ResponseValidationError.self) {
            try Endpoints.downloadActivityZip(5).parse(response(Data()))
        }
        #expect(empty?.message.contains("empty") == true)
        let notZip = #expect(throws: ResponseValidationError.self) {
            try Endpoints.downloadActivity(5).parse(response(Data("<html/>".utf8)))
        }
        #expect(notZip?.message.contains("not a zip") == true)
    }

    @Test func getJSONParser() throws {
        let parse = try Endpoints.json("/x", query: []).parse
        #expect(try parse(response(Data(#"{"a": [1, null]}"#.utf8))) == ["a": [1, nil]])
        #expect(try parse(response(Data(), status: 204)) == nil)
        #expect(throws: ResponseValidationError.self) { try parse(response(Data("not json".utf8))) }
    }

    @Test func decodingErrorsNameTheField() throws {
        let typeMismatch = #expect(throws: ResponseValidationError.self) {
            try Parse.validate(
                [StepsDailyStat].self, response(Data(#"[{"totalSteps": "many"}]"#.utf8)))
        }
        #expect(typeMismatch?.validationError?.hasPrefix("0.totalSteps: expected") == true)
        let missing = #expect(throws: ResponseValidationError.self) {
            try Parse.validate(SummarizedActivity.self, response(Data("{}".utf8)))
        }
        #expect(missing?.validationError == "<root>: missing required field activityId")
        let null = #expect(throws: ResponseValidationError.self) {
            try Parse.validate(
                SummarizedActivity.self, response(Data(#"{"activityId": null}"#.utf8)))
        }
        #expect(null?.validationError?.hasPrefix("activityId: missing") == true)
        let corrupt = #expect(throws: ResponseValidationError.self) {
            try Parse.validate(DailySleep.self, response(Data(#"{"calendarDate": "soon"}"#.utf8)))
        }
        #expect(corrupt?.validationError == "calendarDate: Expected a date.")
    }
}

@Suite struct EmptyResponseTests {
    @Test func emptyBodiesYieldEmptyModels() async throws {
        let fake = FakeGarmin()
        await fake.respond("/") { _ in Reply() }
        let client = try makeClient(fake)
        #expect(try await client.getFitnessAge(day) == FitnessAge())
        #expect(try await client.getEffectiveWeightGoals(start: day, end: day) == UserGoalsRange())
        #expect(try await client.getDailyFoodLogs(day) == DailyNutritionSummary())
        #expect(try await client.getDailySummaries(start: day, end: day).isEmpty)
        #expect(try await client.getWeightRange(start: day, end: day) == WeightRange())
        #expect(try await client.getDailySpO2(day) == DailySpO2AndAcclimation())
        #expect(try await client.getDailyHeartRate(day) == DailyHeartRate())
        #expect(try await client.getDailySummary(day) == UserDailySummary())
        #expect(try await client.getDailySleep(day) == DailySleep())
        #expect(try await client.getActivityWorkouts(activityID).isEmpty)
        #expect(try await client.getJSON("/x") == nil)
    }

    @Test func errorBodySummaries() {
        #expect(ErrorBody(["message": "Bad", "errorId": "e1"])?.summary == "Bad (errorId e1)")
        #expect(ErrorBody(["error": "Oops"])?.summary == "Oops")
        #expect(ErrorBody(["errorId": "e2"])?.summary == nil)
        #expect(ErrorBody(.string("text")) == nil)
    }
}
