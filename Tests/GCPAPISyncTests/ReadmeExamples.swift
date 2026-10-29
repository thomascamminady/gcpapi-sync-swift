import Foundation
import GCPAPISync

// The Swift examples of README.md, compiled with the tests. PackageTests checks that every
// region between "README example" markers matches a README block (minus imports), so the
// README cannot drift from code that compiles.

func readmeExample1() async throws {
    // README example
    let garmin = try GarminClient()

    let runs = try await garmin.searchActivities(
        limit: 5, filters: ActivityFilters(activityType: "running"))
    for run in runs {
        let kilometers = (run.distance ?? 0) / 1000
        print(run.startTimeLocal?.date ?? "-", run.activityName ?? "", kilometers)
    }

    let sleep = try await garmin.getDailySleep("2026-10-21")
    if let score = sleep.sleepScores?.overall?.value {
        print("sleep score", score)
    }

    // 11 requests, returned as one list:
    let steps = try await garmin.getDailySteps(start: "2026-01-01", end: "2026-10-21")
    print(steps.count)
    // README end
}

func readmeExample2(_ garmin: GarminClient) async throws {
    // README example
    async let sleep = garmin.getDailySleepSummaries(start: "2026-01-01", end: "2026-10-21")
    async let hrv = garmin.getDailyHRVSummaries(start: "2026-01-01", end: "2026-10-21")
    async let steps = garmin.getDailySteps(start: "2026-01-01", end: "2026-10-21")
    let (sleepRecords, hrvRecords, stepRecords) = try await (sleep, hrv, steps)
    print(sleepRecords.count, hrvRecords.count, stepRecords.count)

    let october = ActivityFilters(startDate: "2026-10-01")
    for try await activity in try garmin.iterActivities(filters: october) {
        print(activity.activityId, activity.activityName ?? "")
    }
    // README end
}

func readmeExample3(_ garmin: GarminClient) async throws {
    // README example
    let longRuns = try await garmin.searchActivities(
        limit: 100,
        filters: ActivityFilters(
            startDate: "2026-01-01", activityType: "running", sortBy: "distance",
            minDistance: 21_000,
            boundingBox: BoundingBox(north: 50.8, east: 7.2, south: 50.6, west: 7.0)
        )
    )
    print(longRuns.count)

    let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("garmin/fit")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let rides = ActivityFilters(activityType: "cycling")
    for try await activity in try garmin.iterActivities(filters: rides) {
        try await garmin.downloadActivity(activity.activityId).save(to: folder)
    }
    // README end
}

func readmeExample4(_ garmin: GarminClient) async throws {
    // README example
    let heartRate = try await garmin.getDailyHeartRate("2026-10-21")
    for sample in heartRate.heartRateSamples() {
        print(sample.timestamp, sample.heartRate ?? 0)
    }

    let report = try await garmin.getDailyBodyBattery(start: "2026-10-21", end: "2026-10-21").first
    let levels = report?.bodyBatterySamples() ?? []
    let spo2 = try await garmin.getDailySpO2("2026-10-21").spo2HourlySamples()
    print(levels.count, spo2.count)
    // README end
}

func readmeExample5(_ garmin: GarminClient) async throws {
    // README example
    do {
        _ = try await garmin.getActivity(42)
    } catch let error as NotFoundError {
        print("no such activity", error.errorID ?? "")
    } catch let error as RateLimitError {
        print("retry after", error.retryAfter ?? 0)
    } catch let error as any APIStatusError {
        print("HTTP", error.statusCode)
    }
    // README end
}

func readmeExample6() throws {
    // README example
    let configured = try GarminClient(
        keyFile: "~/secrets/garmin.key",
        tokenCache: FileTokenCache(),  // reuse tokens across processes
        timeout: 60,
        retry: try RetryConfig(maxRetries: 5, maxDelay: 30)
    )
    print(configured)
    // README end
}
