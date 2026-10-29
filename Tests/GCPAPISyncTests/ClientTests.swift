import Foundation
import Testing

@testable import GCPAPISync

let settingsPath = "/userprofile-service/userprofile/settings"
let searchPath = "/activitylist-service/activities/search/activities"

/// Run `body`, expecting it to throw an `E`; return that error.
func capture<E>(
    _: E.Type, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> some Any
) async -> E? {
    do {
        _ = try await body()
        Issue.record("expected \(E.self) to be thrown", sourceLocation: sourceLocation)
    } catch let error as E {
        return error
    } catch {
        Issue.record("expected \(E.self), got \(error)", sourceLocation: sourceLocation)
    }
    return nil
}

private func activities(_ count: Int, from offset: Int = 0) -> Reply {
    .json(.array((0..<count).map { ["activityId": .integer(offset + $0)] }))
}

@Suite struct EndpointCallTests {
    @Test(arguments: cases)
    func endpoint(_ testCase: Case) async throws {
        let fake = FakeGarmin()
        await fake.reply(testCase.path, testCase.reply)
        let client = try makeClient(fake)

        let count = try await testCase.call(client)

        if testCase.method == "getMenstrualCycleSummary" {
            #expect(count == nil)
        } else {
            #expect((count ?? 0) > 0)
        }
        let requests = await fake.dataRequests
        try #require(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == testCase.path)
        #expect(requests[0].params == testCase.params)
        #expect(requests[0].header("Accept") == testCase.accept)
    }

    @Test func downloadActivityExtractsTheFile() async throws {
        let fake = FakeGarmin()
        await fake.reply("/download-service/files/activity/\(activityID)", zipReply)
        let file = try await makeClient(fake).downloadActivity(activityID)
        #expect(file.filename == "\(activityID)_ACTIVITY.fit")
        #expect(file.fileExtension == "fit")
        #expect(file.content == fitBytes)
    }

    @Test func unwrappedEndpointsReturnEmptyListsWithoutData() async throws {
        let fake = FakeGarmin()
        await fake.reply("/hrv-service/hrv/daily/2026-10-01/2026-10-02", Reply(status: 204))
        await fake.reply("/usersummary-service/v2/dailysummaries", .json(["data": nil]))
        let client = try makeClient(fake)
        #expect(
            try await client.getDailyHRVSummaries(start: "2026-10-01", end: "2026-10-02").isEmpty)
        #expect(try await client.getDailySummaries(start: "2026-10-01", end: "2026-10-02").isEmpty)
    }

    @Test func emptyObjectResponseYieldsEmptyModel() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, Reply())
        #expect(try await makeClient(fake).getUserProfileSettings() == UserSettings())
    }

    @Test func emptyActivityIsAnError() async throws {
        let fake = FakeGarmin()
        await fake.reply("/activity-service/activity/\(activityID)", Reply(status: 204))
        let client = try makeClient(fake)
        let error = await capture(ResponseValidationError.self) {
            try await client.getActivity(activityID)
        }
        #expect(error?.message.contains("empty response") == true)
    }

    @Test func invalidPayloadThrowsResponseValidationError() async throws {
        let fake = FakeGarmin()
        await fake.reply("/sleep-service/sleep/dailySleep", .text(#"{"sleepTimeSeconds": "long"}"#))
        let client = try makeClient(fake)
        let error = await capture(ResponseValidationError.self) {
            try await client.getDailySleep("2026-10-21")
        }
        #expect(error?.message.contains("sleepTimeSeconds") == true)
        #expect(error?.raw == Data(#"{"sleepTimeSeconds": "long"}"#.utf8))
        #expect(error?.validationError != nil)
        #expect(error?.request?.path == "/sleep-service/sleep/dailySleep")
        let invalid = await capture(ResponseValidationError.self) {
            try Parse.validate(
                UserSettings.self,
                HTTPResponse(
                    statusCode: 200, body: Data("not json".utf8),
                    request: try #require(error?.response.request)))
        }
        #expect(invalid?.validationError == "<root>: not valid JSON")
    }
}

@Suite struct DateRangeRequestTests {
    @Test func longRangesAreSplitIntoWindows() async throws {
        let fake = FakeGarmin()
        await fake.respond("/usersummary-service/stats/steps/daily/") { request in
            let parts = request.path.split(separator: "/")
            let first = (try? GarminDate(String(parts[parts.count - 2]))) ?? GarminDate.today()
            let last = (try? GarminDate(String(parts[parts.count - 1]))) ?? GarminDate.today()
            return .json([
                [
                    "calendarDate": .string("\(first)"),
                    "totalSteps": .integer(first.days(to: last) + 1),
                ]
            ])
        }
        let result = try await makeClient(fake).getDailySteps(
            start: "2026-01-01", end: "2026-03-01")

        #expect(
            result.map {
                "\($0.calendarDate.map(String.init(describing:)) ?? "")=\($0.totalSteps ?? 0)"
            } == [
                "2026-01-01=28", "2026-01-29=28", "2026-02-26=4",
            ])
        let paths = await fake.dataRequests.map(\.path).sorted()
        #expect(
            paths == [
                "/usersummary-service/stats/steps/daily/2026-01-01/2026-01-28",
                "/usersummary-service/stats/steps/daily/2026-01-29/2026-02-25",
                "/usersummary-service/stats/steps/daily/2026-02-26/2026-03-01",
            ])
    }

    @Test func queryParameterRangesAreSplit() async throws {
        let fake = FakeGarmin()
        await fake.respond("/sleep-service/sleep/dailySleepSummariesByDate") { request in
            .json([["calendarDate": .string(request.param("startDate") ?? "")]])
        }
        let result = try await makeClient(fake).getDailySleepSummaries(
            start: try GarminDate(year: 2026, month: 1, day: 1),
            end: try GarminDate(year: 2026, month: 2, day: 15))
        #expect(
            result.compactMap(\.calendarDate).map(\.description) == ["2026-01-01", "2026-02-01"])
    }

    struct WindowCase: Sendable, CustomStringConvertible {
        let method: String
        let days: Int
        let requests: Int
        let call: @Sendable (GarminClient, GarminDate, GarminDate) async throws -> Void
        var description: String { "\(method) \(days) days" }
    }

    static let windowCases: [WindowCase] = [
        WindowCase(method: "steps", days: 28, requests: 1) {
            _ = try await $0.getDailySteps(start: $1, end: $2)
        },
        WindowCase(method: "steps", days: 29, requests: 2) {
            _ = try await $0.getDailySteps(start: $1, end: $2)
        },
        WindowCase(method: "stress", days: 56, requests: 2) {
            _ = try await $0.getDailyStress(start: $1, end: $2)
        },
        WindowCase(method: "hydration", days: 31, requests: 1) {
            _ = try await $0.getDailyHydration(start: $1, end: $2)
        },
        WindowCase(method: "hydration", days: 32, requests: 2) {
            _ = try await $0.getDailyHydration(start: $1, end: $2)
        },
        WindowCase(method: "bodyBattery", days: 62, requests: 2) {
            _ = try await $0.getDailyBodyBattery(start: $1, end: $2)
        },
        WindowCase(method: "sleep", days: 93, requests: 3) {
            _ = try await $0.getDailySleepSummaries(start: $1, end: $2)
        },
        WindowCase(method: "dailySummaries", days: 32, requests: 2) {
            _ = try await $0.getDailySummaries(start: $1, end: $2)
        },
        WindowCase(method: "hrv", days: 366, requests: 2) {
            _ = try await $0.getDailyHRVSummaries(start: $1, end: $2)
        },
    ]

    @Test(arguments: windowCases)
    func windowSizes(_ windowCase: WindowCase) async throws {
        let fake = FakeGarmin()
        await fake.respond("/") { request in
            if request.path.contains("dailysummaries") { return .json(["data": []]) }
            if request.path.hasPrefix("/hrv-service") { return .json(["hrvSummaries": []]) }
            return .json([])
        }
        let end = try GarminDate("2026-10-21")
        try await windowCase.call(try makeClient(fake), end.adding(days: 1 - windowCase.days), end)
        #expect(await fake.dataRequests.count == windowCase.requests)
    }

    @Test func windowsAreFetchedWithBoundedConcurrency() async throws {
        let fake = FakeGarmin()
        await fake.respond("/usersummary-service/stats/steps/daily/") { _ in .json([]) }
        let client = try GarminClient(
            apiKey: testAPIKey, baseURL: baseURL, retry: noWait,
            transport: FakeTransport(fake: fake),
            maxConcurrency: 2)
        _ = try await client.getDailySteps(start: "2026-01-01", end: "2026-12-31")
        #expect(await fake.dataRequests.count == 14)
    }

    @Test func aFailingWindowFailsTheRange() async throws {
        let fake = FakeGarmin()
        await fake.respond("/usersummary-service/stats/steps/daily/2026-01-29") { _ in
            Reply(status: 404)
        }
        await fake.respond("/usersummary-service/stats/steps/daily/") { _ in .json([]) }
        let client = try makeClient(fake)
        _ = await capture(NotFoundError.self) {
            try await client.getDailySteps(start: "2026-01-01", end: "2026-03-01")
        }
    }

    @Test func reversedRangeIsRejectedBeforeAnyRequest() async throws {
        let fake = FakeGarmin()
        let client = try makeClient(fake)
        let error = await capture(InvalidArgumentError.self) {
            try await client.getDailySteps(start: "2026-10-21", end: "2026-10-01")
        }
        #expect(error?.message.contains("must not be after") == true)
        #expect(await fake.requests.isEmpty)
    }

    @Test func malformedDatesAreRejected() async throws {
        let client = try makeClient(FakeGarmin())
        let error = await capture(InvalidArgumentError.self) {
            try await client.getDailySleep("21.10.2026")
        }
        #expect(error?.message.contains("YYYY-MM-DD") == true)
    }
}

@Suite struct ActivitySearchTests {
    @Test func searchPagesLargeLimits() async throws {
        let fake = FakeGarmin()
        await fake.respond(searchPath) { request in
            let start = Int(request.param("start") ?? "") ?? 0
            let limit = Int(request.param("limit") ?? "") ?? 0
            return activities(min(limit, max(0, 100 - start)), from: start)
        }
        let result = try await makeClient(fake).searchActivities(
            limit: 45, filters: ActivityFilters(activityType: "running"))

        #expect(result.count == 45)
        let requests = await fake.dataRequests
        #expect(
            requests.map { [$0.param("start"), $0.param("limit")] } == [
                ["0", "20"], ["20", "20"], ["40", "5"],
            ])
        #expect(requests.allSatisfy { $0.param("activityType") == "running" })
    }

    @Test func searchStopsAtTheLastPage() async throws {
        let fake = FakeGarmin()
        await fake.reply(searchPath, activities(20), activities(3, from: 20))
        let result = try await makeClient(fake).searchActivities(start: 0, limit: 100)
        #expect(result.count == 23)
        #expect(await fake.dataRequests.count == 2)
    }

    @Test func searchWithZeroLimitMakesNoRequest() async throws {
        let fake = FakeGarmin()
        #expect(try await makeClient(fake).searchActivities(limit: 0).isEmpty)
        #expect(await fake.requests.isEmpty)
    }

    @Test func searchRejectsNegativeArguments() async throws {
        let client = try makeClient(FakeGarmin())
        let error = await capture(InvalidArgumentError.self) {
            try await client.searchActivities(start: -1)
        }
        #expect(error?.message.contains(">= 0") == true)
    }

    @Test(arguments: [(5, 3), (4, 3), (0, 1)])
    func iterActivitiesFetchesLazilyUntilAShortPage(total: Int, expectedRequests: Int) async throws
    {
        let fake = FakeGarmin()
        await fake.respond(searchPath) { request in
            let start = Int(request.param("start") ?? "") ?? 0
            let limit = Int(request.param("limit") ?? "") ?? 0
            return activities(min(limit, max(0, total - start)), from: start)
        }
        var seen: [Int] = []
        let sequence = try makeClient(fake).iterActivities(
            pageSize: 2, filters: ActivityFilters(startDate: "2026-10-01"))
        for try await activity in sequence {
            seen.append(activity.activityId)
        }
        #expect(seen == Array(0..<total))
        let requests = await fake.dataRequests
        #expect(requests.count == expectedRequests)
        #expect(requests.allSatisfy { $0.param("startDate") == "2026-10-01" })
    }

    @Test(arguments: [(0, 0), (46, 0), (10, -1)])
    func iterActivitiesValidatesArguments(pageSize: Int, start: Int) throws {
        let client = try makeClient(FakeGarmin())
        #expect(throws: InvalidArgumentError.self) {
            try client.iterActivities(start: start, pageSize: pageSize)
        }
    }
}

@Suite struct AuthenticationFlowTests {
    @Test func tokenIsExchangedOnceAndReused() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, .json([:]))
        let client = try makeClient(fake)
        for _ in 0..<3 {
            _ = try await client.getUserProfileSettings()
        }
        let exchanges = await fake.tokenRequests
        try #require(exchanges.count == 1)
        #expect(exchanges[0].method == "POST")
        #expect(exchanges[0].header("Authorization") == "ApiKey test-api-key")
        let token = try #require(await fake.issued.first)
        #expect(
            await fake.dataRequests.allSatisfy { $0.header("Authorization") == "Bearer \(token)" })
        #expect(
            await fake.requests.allSatisfy {
                $0.header("User-Agent")?.hasPrefix("gcpapi-sync-swift/") == true
            })
    }

    @Test func concurrentRequestsShareOneExchange() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, .json([:]))
        let client = try makeClient(fake)
        try await withThrowingTaskGroup(of: UserSettings.self) { group in
            for _ in 0..<8 {
                group.addTask { try await client.getUserProfileSettings() }
            }
            try await group.waitForAll()
        }
        #expect(await fake.tokenRequests.count == 1)
    }

    @Test func rejectedTokenIsRenewedOnce() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, .json([:]))
        let client = try makeClient(fake)
        _ = try await client.getUserProfileSettings()
        await fake.revokeAll()

        _ = try await client.getUserProfileSettings()

        #expect(await fake.tokenRequests.count == 2)
        let issued = await fake.issued
        #expect(
            await fake.dataRequests.map { $0.header("Authorization") } == [
                "Bearer \(issued[0])", "Bearer \(issued[0])", "Bearer \(issued[1])",
            ])
    }

    @Test func persistent401ThrowsAuthenticationError() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, Reply(status: 401))
        let client = try makeClient(fake)
        let error = await capture(AuthenticationError.self) {
            try await client.getUserProfileSettings()
        }
        #expect(error?.message.contains("401") == true)
        #expect(await fake.tokenRequests.count == 2)
    }

    @Test func expiringTokenIsRenewedBeforeUse() async throws {
        let fake = FakeGarmin()
        await fake.setTokenLifetime(120)
        await fake.reply(settingsPath, .json([:]))
        let client = try makeClient(fake)
        _ = try await client.getUserProfileSettings()
        _ = try await client.getUserProfileSettings()
        #expect(await fake.tokenRequests.count == 2)
    }

    @Test func forceRefresh() async throws {
        let fake = FakeGarmin()
        let client = try makeClient(fake)
        let first = try await client.getAccessToken()
        let cached = try await client.getAccessToken()
        let renewed = try await client.getAccessToken(forceRefresh: true)
        #expect(first == cached)
        #expect(renewed != first)
        #expect(await fake.tokenRequests.count == 2)
    }

    @Test func rejectedAPIKey() async throws {
        let fake = FakeGarmin()
        let client = try makeClient(fake, apiKey: "wrong")
        let error = await capture(AuthenticationError.self) {
            try await client.getUserProfileSettings()
        }
        #expect(error?.message.contains("rejected the API key") == true)
        #expect(await fake.dataRequests.isEmpty)
    }

    @Test func accessTokenWithoutKey() async throws {
        let fake = FakeGarmin()
        let token = makeJWT()
        await fake.issue(token)
        await fake.reply(settingsPath, .json([:]))
        let client = try makeClient(fake, apiKey: nil, accessToken: token)
        _ = try await client.getUserProfileSettings()
        #expect(await fake.tokenRequests.isEmpty)
        await fake.revokeAll()
        _ = await capture(AuthenticationError.self) { try await client.getUserProfileSettings() }
        let error = await capture(ConfigurationError.self) {
            try await client.getAccessToken(forceRefresh: true)
        }
        #expect(error?.message.contains("no API key") == true)
    }

    @Test func accessTokenWithKeyRenewsWhenRejected() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, .json([:]))
        _ = try await makeClient(fake, accessToken: makeJWT()).getUserProfileSettings()
        #expect(await fake.tokenRequests.count == 1)
    }

    @Test func fileTokenCacheIsShared() async throws {
        let scratch = try Scratch()
        let fake = FakeGarmin()
        await fake.reply(settingsPath, .json([:]))
        let cache = FileTokenCache(url: scratch.url.appendingPathComponent("token.json"))
        for _ in 0..<2 {
            _ = try await makeClient(fake, tokenCache: cache).getUserProfileSettings()
        }
        #expect(await fake.tokenRequests.count == 1)
    }

    @Test(arguments: [(#""quoted.jwt.token""#, "quoted.jwt.token"), ("  plain  ", "plain")])
    func tokenBodyIsNormalized(body: String, expected: String) async throws {
        let fake = FakeGarmin()
        await fake.queueTokenReplies(.text(body))
        #expect(try await makeClient(fake).getAccessToken().value == expected)
    }

    @Test func emptyTokenBody() async throws {
        let fake = FakeGarmin()
        await fake.queueTokenReplies(.text(""))
        let client = try makeClient(fake)
        let error = await capture(ResponseValidationError.self) {
            try await client.getAccessToken()
        }
        #expect(error?.message.contains("empty body") == true)
    }

    @Test func tokenExchangeIsRetried() async throws {
        let fake = FakeGarmin()
        await fake.queueTokenReplies(Reply(status: 503), .text(makeJWT()))
        _ = try await makeClient(fake).getAccessToken()
        #expect(await fake.tokenRequests.count == 2)
    }

    @Test func tokenExchangeServerError() async throws {
        let fake = FakeGarmin()
        await fake.queueTokenReplies(Reply(status: 500))
        let client = try makeClient(fake)
        _ = await capture(InternalServerError.self) { try await client.getAccessToken() }
    }
}

@Suite struct RetryAndErrorTests {
    @Test func transientStatusIsRetried() async throws {
        let fake = FakeGarmin()
        await fake.reply(
            settingsPath, Reply(status: 503), Reply(status: 429, headers: ["Retry-After": "0"]),
            .json([:]))
        _ = try await makeClient(fake).getUserProfileSettings()
        #expect(await fake.dataRequests.count == 3)
    }

    @Test func retriesAreBounded() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, Reply(status: 500))
        let client = try makeClient(fake)
        _ = await capture(InternalServerError.self) { try await client.getUserProfileSettings() }
        #expect(await fake.dataRequests.count == 3)
    }

    @Test func longRetryAfterIsNotWaitedFor() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, Reply(status: 429, headers: ["Retry-After": "3600"]))
        let client = try makeClient(fake)
        let error = await capture(RateLimitError.self) { try await client.getUserProfileSettings() }
        #expect(error?.retryAfter == 3600)
        #expect(await fake.dataRequests.count == 1)
    }

    @Test func clientErrorsAreNotRetried() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, .text("{}", status: 400))
        let client = try makeClient(fake)
        let error = await capture(BadRequestError.self) {
            try await client.getUserProfileSettings()
        }
        #expect(error?.message.contains("Garmin rejected the parameters") == true)
        #expect(await fake.dataRequests.count == 1)
    }

    @Test(arguments: [403, 404, 418, 502])
    func statusErrors(status: Int) async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, Reply(status: status))
        let client = try makeClient(fake)
        let error = await capture((any APIStatusError).self) {
            try await client.getUserProfileSettings()
        }
        #expect(error?.statusCode == status)
        #expect(error?.request != nil)
        switch status {
        case 403: #expect(error is PermissionDeniedError)
        case 404: #expect(error is NotFoundError)
        case 418: #expect(error is UnexpectedStatusError)
        default: #expect(error is InternalServerError)
        }
    }

    @Test func errorBodyDetails() async throws {
        let fake = FakeGarmin()
        let body: JSONValue = [
            "clientMessage": "Reference Error ID", "errorId": "abc-123",
            "error": "NotAcceptableException",
        ]
        await fake.reply(settingsPath, .json(body, status: 406))
        let client = try makeClient(fake)
        let error = try #require(
            await capture(UnexpectedStatusError.self) { try await client.getUserProfileSettings() })
        #expect(error.errorID == "abc-123")
        #expect(error.errorBody?.error == "NotAcceptableException")
        #expect(error.body == body)
        #expect(error.description.contains("Reference Error ID (errorId abc-123)"))
        #expect(error.errorDescription == error.message)
    }

    @Test func nonJSONErrorBody() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, .text("<html>Bad gateway</html>", status: 502))
        let client = try makeClient(fake)
        let error = try #require(
            await capture(InternalServerError.self) { try await client.getUserProfileSettings() })
        #expect(error.body == .string("<html>Bad gateway</html>"))
        #expect(error.errorBody == nil)
        #expect(error.errorID == nil)
        #expect(error.message.contains("Bad gateway"))
    }

    @Test func transportErrorsAreRetried() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, .failing(), .json([:]))
        _ = try await makeClient(fake).getUserProfileSettings()
        #expect(await fake.dataRequests.count == 2)
    }

    @Test(arguments: [false, true])
    func persistentTransportErrors(timeout: Bool) async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, .failing(timeout: timeout))
        let client = try makeClient(fake)
        let error = await capture(APIConnectionError.self) {
            try await client.getUserProfileSettings()
        }
        #expect(error?.message.contains("simulated failure") == true)
        #expect(error?.isTimeout == timeout)
        #expect(error?.request?.path == settingsPath)
        #expect(await fake.dataRequests.count == 3)
    }

    @Test func retriesCanBeDisabled() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, Reply(status: 503))
        let client = try makeClient(fake, retry: try RetryConfig(maxRetries: 0))
        _ = await capture(InternalServerError.self) { try await client.getUserProfileSettings() }
        #expect(await fake.dataRequests.count == 1)
    }

    @Test func retriesWaitForTheBackoff() async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, Reply(status: 503), .json([:]))
        let client = try makeClient(fake, retry: try RetryConfig(initialDelay: 0.01, jitter: 0))
        let started = ContinuousClock.now
        _ = try await client.getUserProfileSettings()
        #expect(started.duration(to: .now) >= .milliseconds(10))
    }

    @Test func tokenPathConstantMatchesTheClient() {
        #expect(Constants.keyExchangePath == tokenPath)
    }

    @Test(arguments: [
        (#"{"errorId": "only-an-id"}"#, #"{"errorId": "only-an-id"}"#),
        (#"{"error": 123}"#, #"{"error": 123}"#),
        ("[1, 2]", "[1, 2]"),
    ])
    func jsonErrorBodiesWithoutAMessage(body: String, expected: String) async throws {
        let fake = FakeGarmin()
        await fake.reply(settingsPath, .text(body, status: 409))
        let client = try makeClient(fake)
        let error = await capture(UnexpectedStatusError.self) {
            try await client.getUserProfileSettings()
        }
        #expect(error?.message.hasSuffix("returned HTTP 409: \(expected)") == true)
    }
}
