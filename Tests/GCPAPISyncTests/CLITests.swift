import Foundation
import Testing

@testable import GCPAPICLI
@testable import GCPAPISync

/// A scripted console: captured output, canned input.
actor TestConsole: Console {
    private(set) var out: [String] = []
    private(set) var err: [String] = []
    private var input: [String]
    private var secrets: [String]
    private(set) var prompts: [String] = []
    nonisolated let isTerminal: Bool

    init(input: [String] = [], secrets: [String] = [], isTerminal: Bool = false) {
        self.input = input
        self.secrets = secrets
        self.isTerminal = isTerminal
    }

    func write(_ line: String) { out.append(line) }
    func note(_ line: String) { err.append(line) }

    func readLine() -> String? {
        input.isEmpty ? nil : input.removeFirst()
    }

    func readSecret(prompt: String) -> String? {
        prompts.append(prompt)
        return secrets.isEmpty ? nil : secrets.removeFirst()
    }

    var stdout: String { out.joined(separator: "\n") }
    var stderr: String { err.joined(separator: "\n") }
}

/// Runs `gcpapi` against a fake Garmin in an isolated home directory.
struct CLIHarness {
    let fake = FakeGarmin()
    let scratch: Scratch
    let console: TestConsole
    var now = utc(2026, 10, 21, 12)

    init(console: TestConsole = TestConsole()) throws {
        scratch = try Scratch()
        self.console = console
    }

    var environment: ProcessEnvironment {
        scratch.environment(["GARMIN_PERSONAL_API_KEY": testAPIKey])
    }

    var home: URL { environment.homeDirectory }

    func run(_ arguments: String..., environment custom: ProcessEnvironment? = nil) async -> Int32 {
        let context = CLIContext(
            environment: custom ?? environment, console: console,
            transport: FakeTransport(fake: fake), retry: noWait, now: { [now] in now },
            timeZone: .gmt)
        return await CLIContext.$current.withValue(context) {
            await GCPAPI.main(Array(arguments) + ["--base-url", baseURL])
        }
    }

    func json() async throws -> JSONValue {
        try decode(JSONValue.self, json: await console.stdout)
    }
}

private let todayPath = "/usersummary-service/usersummary/daily"
private let sleepPath = "/sleep-service/sleep/dailySleep"

@Suite struct CLIJSONCommandTests {
    static let commands: [(arguments: [String], path: String)] = [
        (["get-activity", "\(activityID)"], "/activity-service/activity/\(activityID)"),
        (
            ["get-activity-workouts", "\(activityID)"],
            "/activity-service/activity/\(activityID)/workouts"
        ),
        (["search-activities", "--limit", "3", "--activity_type", "running"], searchPath),
        (["get-daily-summary", day], todayPath),
        (["get_daily_summaries", rangeStart, rangeEnd], "/usersummary-service/v2/dailysummaries"),
        (
            ["get-wellness-activity-summaries", rangeStart, rangeEnd],
            "/wellnessactivity-service/activity/summary/range/\(rangeStart)/\(rangeEnd)"
        ),
        (["get-daily-sleep", day], sleepPath),
        (
            ["get-daily-sleep-summaries", rangeStart, rangeEnd],
            "/sleep-service/sleep/dailySleepSummariesByDate"
        ),
        (["get-daily-heart-rate", day], "/wellness-service/wellness/dailyHeartRate"),
        (
            ["get-heart-rate-zones", "--no-generate-defaults"],
            "/biometric-service/heartRateZones/v2"
        ),
        (["get-daily-hrv", day], "/hrv-service/hrv/\(day)"),
        (
            ["get-daily-hrv-summaries", rangeStart, rangeEnd],
            "/hrv-service/hrv/daily/\(rangeStart)/\(rangeEnd)"
        ),
        (
            ["get-daily-stress", rangeStart, rangeEnd],
            "/usersummary-service/stats/stress/daily/\(rangeStart)/\(rangeEnd)"
        ),
        (
            ["get-daily-steps", rangeStart, rangeEnd],
            "/usersummary-service/stats/steps/daily/\(rangeStart)/\(rangeEnd)"
        ),
        (
            ["get-daily-hydration", rangeStart, rangeEnd],
            "/usersummary-service/stats/hydration/daily/\(rangeStart)/\(rangeEnd)"
        ),
        (
            ["get-daily-body-battery", rangeStart, rangeEnd, "--chunks", "4"],
            "/wellness-service/wellness/bodyBattery/reports/daily"
        ),
        (["get-daily-spo2", day], "/wellness-service/wellness/daily/spo2acclimation/\(day)"),
        (
            ["get-fitness-age", day, "--no-full-history-scan"],
            "/fitnessage-service/fitnessage/v2/\(day)"
        ),
        (
            ["get-weight-range", rangeStart, rangeEnd, "--include-all"],
            "/weight-service/weight/range/\(rangeStart)/\(rangeEnd)"
        ),
        (
            ["get-weight-entries", rangeStart, rangeEnd],
            "/weight-service/weight/all/\(rangeStart)/\(rangeEnd)"
        ),
        (
            ["get-effective-weight-goals", rangeStart, rangeEnd],
            "/goal-service/goal/user/effective/weightgoal/\(rangeStart)/\(rangeEnd)"
        ),
        (
            ["get-daily-food-logs", day, "--no-include-media", "--meal-id", "3"],
            "/nutrition-service/food/logs/\(day)"
        ),
        (
            ["get-menstrual-cycle-summary", day],
            "/periodichealth-service/menstrualcycle/summary/\(day)"
        ),
        (
            ["get-menstrual-cycle-day-view", day, "--today", day, "--include-analysis"],
            "/periodichealth-service/menstrualcycle/dayview/\(day)"
        ),
        (["get-user-profile-settings"], settingsPath),
        (["get-json", settingsPath, "--param", "a=1"], settingsPath),
    ]

    @Test(arguments: commands)
    func jsonCommandForEveryClientMethod(arguments: [String], path: String) async throws {
        let cli = try CLIHarness()
        await cli.fake.respond("/") { request in
            let lists = [
                "/workouts", "/search/activities", "/summary/range", "dailySleepSummariesByDate",
                "heartRateZones", "/stress/daily", "/steps/daily", "/hydration/daily",
                "bodyBattery",
                "/weight/all",
            ]
            if lists.contains(where: request.path.contains) { return .json([]) }
            if request.path.hasPrefix("/activity-service/") { return .json(["activityId": 1]) }
            return .json([:])
        }
        let status = await CLIContext.$current.withValue(
            CLIContext(
                environment: cli.environment, console: cli.console,
                transport: FakeTransport(fake: cli.fake), retry: noWait)
        ) { await GCPAPI.main(arguments + ["--base-url", baseURL, "--no-cache"]) }
        let errors = await cli.console.stderr
        #expect(status == 0, "\(errors)")
        #expect(await cli.fake.dataRequests.map(\.path) == [path])
        _ = try await cli.json()
    }

    @Test func everyClientMethodHasACommand() {
        #expect(
            Set(Self.commands.map { $0.arguments[0].replacingOccurrences(of: "_", with: "-") })
                .count == 26)
    }
}

@Suite struct CLIAccountTests {
    @Test func tokenNeverPrintsTheToken() async throws {
        let cli = try CLIHarness()
        #expect(await cli.run("token") == 0)
        let issued = try #require(await cli.fake.issued.first)
        #expect(!(await cli.console.stdout).contains(issued))
        #expect(try await cli.json()["expiresAt"]?.stringValue?.hasSuffix("Z") == true)
    }

    @Test func tokenCacheIsUsedByDefault() async throws {
        let cli = try CLIHarness()
        #expect(await cli.run("token") == 0)
        #expect(await cli.run("token") == 0)
        #expect(await cli.fake.tokenRequests.count == 1)
        let cache = cli.home.appendingPathComponent(
            ".config/garmin/connect-personal-api-bearer-token.json")
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(await cli.run("token", "--no-cache") == 0)
        #expect(await cli.fake.tokenRequests.count == 2)
    }

    @Test func errorsExitWithStatus1() async throws {
        let cli = try CLIHarness()
        await cli.fake.reply(settingsPath, Reply(status: 404))
        #expect(await cli.run("get-user-profile-settings") == 1)
        #expect(await cli.console.stderr.hasPrefix("error: GET \(settingsPath) returned HTTP 404"))
        #expect(await cli.run("get-daily-sleep", "yesterday") == 1)
        #expect(await cli.console.stderr.contains("day must be a YYYY-MM-DD date"))
    }

    @Test func usageErrorsAndHelp() async throws {
        let cli = try CLIHarness()
        #expect(await cli.run("search-activities", "--sort-order", "up") != 0)
        #expect(await cli.console.stderr.contains("--sort-order must be asc or desc"))
        #expect(await cli.run("activities", "--bounding-box", "1,2") != 0)
        #expect(await cli.run("get-json", "/x", "--param", "novalue") != 0)
        #expect(await cli.run("--help") == 0)
        #expect(await cli.console.stdout.contains("get-daily-sleep"))
        #expect(await cli.run("--version") == 0)
        #expect(await cli.console.stdout.contains(packageVersion))
    }

    @Test func setupVerifiesAndStoresTheKey() async throws {
        let cli = try CLIHarness(console: TestConsole(input: ["  \(testAPIKey)  "]))
        #expect(await cli.run("setup", environment: cli.scratch.environment()) == 0)
        let key = cli.home.appendingPathComponent(".config/garmin/connect-personal-api-key")
        #expect(try String(contentsOf: key, encoding: .utf8) == "\(testAPIKey)\n")
        #expect(await cli.console.stdout.contains("Key verified and saved to \(key.path)"))
        #expect(await cli.run("setup", environment: cli.scratch.environment()) == 1)
        #expect(await cli.console.stderr.contains("pass --overwrite"))
    }

    @Test func setupReadsFromAHiddenPromptOnTerminals() async throws {
        let console = TestConsole(secrets: [testAPIKey], isTerminal: true)
        let cli = try CLIHarness(console: console)
        #expect(await cli.run("setup", environment: cli.scratch.environment()) == 0)
        #expect(await console.prompts == ["Garmin Personal API key (input hidden): "])
    }

    @Test func setupRejectsInvalidKeys() async throws {
        let cli = try CLIHarness(console: TestConsole(input: ["wrong"]))
        #expect(await cli.run("setup", environment: cli.scratch.environment()) == 1)
        #expect(await cli.console.stderr.contains("rejected the API key"))
        #expect(
            !FileManager.default.fileExists(
                atPath: cli.home.appendingPathComponent(".config/garmin/connect-personal-api-key")
                    .path))
        let empty = try CLIHarness()
        #expect(await empty.run("setup", environment: empty.scratch.environment()) == 1)
        #expect(await empty.console.stderr.contains("No API key was entered"))
    }

    @Test func status() async throws {
        let cli = try CLIHarness()
        #expect(await cli.run("status") == 0)
        let output = await cli.console.stdout
        #expect(output.contains("API host      \(baseURL)"))
        #expect(output.contains("API key       environment variable GARMIN_PERSONAL_API_KEY"))
        #expect(output.contains("Access token  valid until"))
        #expect(output.contains("h "))
        #expect(await cli.run("status", "--no-cache") == 0)
        #expect(await cli.console.stdout.contains("Token cache   disabled"))
    }

    @Test func statusWarnsAboutSharedKeyFiles() async throws {
        let cli = try CLIHarness()
        let key = cli.home.appendingPathComponent(".config/garmin/connect-personal-api-key")
        try GCPAPISync.saveAPIKey(testAPIKey, to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
        #expect(await cli.run("status", environment: cli.scratch.environment()) == 0)
        #expect(await cli.console.stdout.contains("(WARNING: readable by others)"))
    }

    @Test func logout() async throws {
        let cli = try CLIHarness()
        #expect(await cli.run("token") == 0)
        let key = try GCPAPISync.saveAPIKey(testAPIKey, environment: cli.environment)
        #expect(await cli.run("logout") == 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: cli.home.appendingPathComponent(
                    ".config/garmin/connect-personal-api-bearer-token.json"
                ).path))
        #expect(FileManager.default.fileExists(atPath: key.path))
        #expect(await cli.run("logout", "--forget-key") == 0)
        #expect(!FileManager.default.fileExists(atPath: key.path))
        #expect(await cli.console.stdout.contains("Removed API key"))
    }
}

@Suite struct CLIOverviewTests {
    private func serveToday(_ fake: FakeGarmin, activities: Reply? = nil) async throws {
        await fake.reply(todayPath, try .fixture("daily_summary"))
        await fake.reply(sleepPath, try .fixture("daily_sleep"))
        await fake.reply("/hrv-service/hrv/\(day)", try .fixture("daily_hrv"))
        await fake.reply(searchPath, try activities ?? .fixture("search_activities"))
    }

    @Test func today() async throws {
        let cli = try CLIHarness()
        try await serveToday(cli.fake)
        #expect(await cli.run("today", day) == 0)
        let output = await cli.console.stdout
        #expect(output.hasPrefix("Wednesday, 2026-10-21"))
        for label in [
            "Steps", "Distance", "Resting HR", "Stress", "Body Battery", "Sleep", "HRV",
            "Activities",
        ] {
            #expect(output.contains("  \(label)"), "\(label) missing")
        }
        let search = try #require(await cli.fake.dataRequests.first { $0.path == searchPath })
        #expect(search.param("startDate") == day)
        #expect(search.param("endDate") == day)
    }

    @Test func todayWithoutData() async throws {
        let cli = try CLIHarness()
        await cli.fake.reply(todayPath, Reply())
        await cli.fake.reply(sleepPath, Reply())
        await cli.fake.reply("/hrv-service/hrv/\(day)", Reply(status: 204))
        await cli.fake.reply(searchPath, .json([]))
        #expect(await cli.run("today", day) == 0)
        let output = await cli.console.stdout
        #expect(output.contains("Steps         - of -"))
        #expect(output.contains("Activities    none"))
        #expect(!output.contains("HRV"))
    }

    @Test func todayAsJSON() async throws {
        let cli = try CLIHarness()
        try await serveToday(cli.fake)
        #expect(await cli.run("today", day, "--as-json") == 0)
        let report = try await cli.json()
        #expect(report["day"] == .string(day))
        #expect(report["summary"]?.objectValue != nil)
        #expect(report["activities"]?.arrayValue?.isEmpty == false)
    }

    @Test func todayDefaultsToTheCurrentDate() async throws {
        let cli = try CLIHarness()
        try await serveToday(cli.fake)
        #expect(await cli.run("today") == 0)
        let request = try #require(await cli.fake.dataRequests.first { $0.path == todayPath })
        #expect(request.param("calendarDate") == day)
    }

    @Test func activitiesTable() async throws {
        let cli = try CLIHarness()
        await cli.fake.reply(searchPath, try .fixture("search_activities"))
        #expect(await cli.run("activities", "--limit", "5", "--activity-type", "running") == 0)
        let lines = await cli.console.out
        #expect(lines.first?.hasPrefix("Start") == true)
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { !$0.hasSuffix(" ") })
        #expect(await cli.fake.dataRequests.first?.param("activityType") == "running")
    }

    @Test func formatting() throws {
        #expect(Format.duration(nil) == "-")
        #expect(Format.duration(59.6) == "1:00")
        #expect(Format.duration(3723) == "1:02:03")
        #expect(Format.number(1_234_567.5) == "1,234,568")
        #expect(Format.number(-1234) == "-1,234")
        #expect(Format.number(nil as Double?) == "-")
        #expect(Format.kilometers(0) == "-")
        #expect(Format.kilometers(12_345) == "12.35 km")
        #expect(Format.weekday(try GarminDate("1970-01-01")) == "Thursday")
        #expect(Format.weekday(try GarminDate("1969-12-28")) == "Sunday")
        #expect(Format.iso(utc(2026, 10, 21, 7, 5, 9)) == "2026-10-21T07:05:09Z")
        #expect(Format.utcMinute(utc(2026, 10, 21, 7, 5, 9)) == "2026-10-21 07:05")
    }
}

@Suite struct CLIBulkTests {
    private func serveActivities(_ fake: FakeGarmin, ids: [Int]) async {
        await fake.respond(searchPath) { request in
            let start = Int(request.param("start") ?? "") ?? 0
            let limit = Int(request.param("limit") ?? "") ?? 0
            let page = ids.dropFirst(start).prefix(limit)
            return .json(.array(page.map { ["activityId": .integer($0)] }))
        }
        await fake.respond("/download-service/files/activity/3") { _ in Reply(status: 404) }
        await fake.respond("/download-service/files/activity/") { request in
            let id = request.path.split(separator: "/").last.map(String.init) ?? "0"
            return Reply(body: zipArchive([("\(id)_ACTIVITY.fit", Data("fit-\(id)".utf8))]))
        }
    }

    @Test func syncDownloadsNewActivitiesOnly() async throws {
        let cli = try CLIHarness()
        await serveActivities(cli.fake, ids: [1, 2, 3, 4])
        let output = cli.scratch.url.appendingPathComponent("fit")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: output.appendingPathComponent("2_ACTIVITY.fit"))

        #expect(await cli.run("sync", output.path, "--metadata", "--since", "2026-10-01") == 0)

        let report = try await cli.json()
        #expect(report["downloaded"] == ["1_ACTIVITY.fit", "4_ACTIVITY.fit"])
        #expect(report["skipped"] == 1)
        #expect(report["unavailable"] == [3])
        #expect(
            try Data(contentsOf: output.appendingPathComponent("1_ACTIVITY.fit"))
                == Data("fit-1".utf8))
        #expect(
            FileManager.default.fileExists(atPath: output.appendingPathComponent("1.json").path))
        #expect(await cli.console.stderr.contains("downloaded 1_ACTIVITY.fit"))
        #expect(await cli.fake.dataRequests.first?.param("startDate") == "2026-10-01")
    }

    @Test func syncRespectsLimit() async throws {
        let cli = try CLIHarness()
        await serveActivities(cli.fake, ids: [1, 2, 4, 5])
        let output = cli.scratch.url.appendingPathComponent("fit")
        #expect(await cli.run("sync", output.path, "--limit", "2", "--until", "2026-10-21") == 0)
        #expect(try await cli.json()["downloaded"]?.arrayValue?.count == 2)
    }

    @Test func syncSkipsFilesThatExistUnderAnotherName() async throws {
        let cli = try CLIHarness()
        await cli.fake.respond(searchPath) { _ in .json([["activityId": 7]]) }
        await cli.fake.respond("/download-service/files/activity/") { _ in
            Reply(body: zipArchive([("other.fit", Data("x".utf8))]))
        }
        let output = cli.scratch.url.appendingPathComponent("fit")
        try FileManager.default.createDirectory(
            at: output.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: output.appendingPathComponent("other.fit"))
        #expect(await cli.run("sync", output.path) == 0)
        #expect(try await cli.json()["skipped"] == 1)
    }

    @Test func activitiesWithoutIDsAreRejected() async throws {
        let cli = try CLIHarness()
        await cli.fake.reply(searchPath, .json([["activityName": "no id"]]))
        #expect(await cli.run("sync", cli.scratch.url.path) == 1)
        #expect(await cli.console.stderr.contains("activityId"))
    }

    @Test func export() async throws {
        let cli = try CLIHarness()
        await cli.fake.respond("/") { request in
            if request.path.contains("dailysummaries") {
                return .json(["data": [["calendarDate": "2026-10-21"]]])
            }
            if request.path.hasPrefix("/hrv-service") { return .json(["hrvSummaries": []]) }
            return .json([["calendarDate": "2026-10-21"]])
        }
        let output = cli.scratch.url.appendingPathComponent("health")
        #expect(await cli.run("export", "2026-10-20", "2026-10-21", output.path) == 0)
        let summary = try await cli.json()
        #expect(summary["records"]?["daily_summaries"] == 1)
        #expect(summary["records"]?["hrv"] == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(
            files == [
                "body_battery.json", "daily_summaries.json", "hrv.json", "hydration.json",
                "sleep.json",
                "steps.json", "stress.json", "wellness_activities.json",
            ])
        #expect(await cli.console.stderr.contains("steps: 1 records"))
    }

    @Test func downloadCommands() async throws {
        let cli = try CLIHarness()
        await serveActivities(cli.fake, ids: [])
        let directory = cli.scratch.url
        #expect(await cli.run("download-activity", "5", directory.path) == 0)
        #expect(
            try await cli.json()["path"]
                == .string(directory.appendingPathComponent("5_ACTIVITY.fit").path))
        #expect(await cli.run("download-activity", "5", directory.path) == 1)
        #expect(await cli.console.stderr.contains("pass --overwrite"))
        #expect(await cli.run("download-activity", "5", directory.path, "--overwrite") == 0)

        let zip = try CLIHarness()
        await serveActivities(zip.fake, ids: [])
        #expect(await zip.run("download-activity-zip", "6", zip.scratch.url.path) == 0)
        let archive = zip.scratch.url.appendingPathComponent("6.zip")
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(await zip.run("download_activity_zip", "6", archive.path) == 1)
        #expect(await zip.run("download-activity-zip", "6", archive.path, "--overwrite") == 0)
    }

    @Test func iterActivitiesPrintsJSONLines() async throws {
        let cli = try CLIHarness()
        await serveActivities(cli.fake, ids: [1, 2, 3])
        #expect(await cli.run("iter-activities", "--page-size", "2") == 0)
        let lines = await cli.console.out
        #expect(lines == [#"{"activityId":1}"#, #"{"activityId":2}"#, #"{"activityId":3}"#])
    }

    @Test func indentation() async throws {
        let cli = try CLIHarness()
        await cli.fake.reply(settingsPath, .json(["a": ["b": 1]]))
        #expect(await cli.run("get-user-profile-settings", "--indent", "4") == 0)
        #expect(await cli.console.stdout.contains("\n        \"b\""))
    }
}

@Suite struct TodayReportTests {
    @Test func everyLine() throws {
        let report = TodayReport(
            day: try GarminDate("2026-10-21"),
            summary: UserDailySummary(totalSteps: 12_345, dailyStepGoal: 10_000),
            sleep: try decode(
                DailySleep.self,
                [
                    "sleepTimeSeconds": 27_000,
                    "sleepScores": ["overall": ["value": 88, "qualifierKey": "GOOD"]],
                ]),
            hrv: try decode(
                HrvChart.self,
                ["hrvSummary": ["lastNightAvg": 55, "weeklyAvg": 60, "status": "BALANCED"]]),
            activities: [
                try decode(
                    SummarizedActivity.self,
                    [
                        "activityId": 1, "startTimeLocal": "2026-10-21T07:05:00",
                        "distance": 10_000,
                        "duration": 3000, "activityType": ["typeKey": "trail_running"],
                    ]),
                SummarizedActivity(activityId: 2),
            ]
        )
        let lines = report.lines
        #expect(lines.contains("  Steps         12,345 of 10,000"))
        #expect(lines.contains("  Sleep         7:30:00 h, score 88 GOOD"))
        #expect(lines.contains("  HRV           55 ms last night, weekly 60 ms (BALANCED)"))
        #expect(lines.contains("  Activities    07:05  trail running  10.00 km  50:00"))
        #expect(lines.contains("                activity  -  -"))
    }
}
