import Foundation
import GCPAPISync
import Testing

// Checks against the real Personal API, run by the weekly drift job:
//
//     GCPAPI_LIVE_TESTS=1 swift test --filter LiveTests
//
// Besides calling every endpoint, these tests fail when Garmin returns fields the models
// do not know, which is how changes to the API that the spec does not announce are
// detected.
//
// These tests run in public CI logs, so they must never print personal data: every check
// goes through `check`, whose failure message is fixed text (field names at most), and
// `#expect` is not used because it would print the values.

private let enabled = ProcessInfo.processInfo.environment["GCPAPI_LIVE_TESTS"] == "1"

/// Fail with `message` only, without showing any values.
private func check(
    _ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    if !condition {
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }
}

private func undocumented(_ value: some GarminModel) -> Set<String> {
    value.undocumentedFields
}

private func undocumented(_ values: [some GarminModel]) -> Set<String> {
    values.reduce(into: []) { $0.formUnion($1.undocumentedFields) }
}

@Suite(.enabled(if: enabled, "set GCPAPI_LIVE_TESTS=1 to run against the real API"), .serialized)
struct LiveTests {
    let garmin: GarminClient
    let today = GarminDate.today(in: .gmt)
    var yesterday: GarminDate { today.adding(days: -1) }
    var weekAgo: GarminDate { today.adding(days: -7) }

    init() throws {
        garmin = try GarminClient(tokenCache: FileTokenCache())
    }

    private func checkModel(_ name: String, _ value: some GarminModel) {
        let unknown = undocumented(value).sorted()
        check(unknown.isEmpty, "\(name) returned fields the models do not know: \(unknown)")
    }

    private func checkModels(_ name: String, _ values: [some GarminModel]) {
        let unknown = undocumented(values).sorted()
        check(unknown.isEmpty, "\(name) returned fields the models do not know: \(unknown)")
    }

    @Test func profileAndZones() async throws {
        checkModel("getUserProfileSettings", try await garmin.getUserProfileSettings())
        checkModels("getHeartRateZones", try await garmin.getHeartRateZones())
        checkModel("getFitnessAge", try await garmin.getFitnessAge(yesterday))
    }

    @Test func dailySummaries() async throws {
        checkModel("getDailySummary", try await garmin.getDailySummary(yesterday))
        checkModels(
            "getDailySummaries",
            try await garmin.getDailySummaries(start: today.adding(days: -40), end: yesterday))
    }

    @Test func sleep() async throws {
        checkModel("getDailySleep", try await garmin.getDailySleep(yesterday))
        checkModels(
            "getDailySleepSummaries",
            try await garmin.getDailySleepSummaries(start: today.adding(days: -40), end: yesterday))
    }

    @Test func heart() async throws {
        checkModel("getDailyHeartRate", try await garmin.getDailyHeartRate(yesterday))
        if let hrv = try await garmin.getDailyHRV(yesterday) {
            checkModel("getDailyHRV", hrv)
        }
        checkModels(
            "getDailyHRVSummaries",
            try await garmin.getDailyHRVSummaries(start: today.adding(days: -400), end: yesterday))
    }

    @Test func wellness() async throws {
        let start = today.adding(days: -40)
        checkModels("getDailyStress", try await garmin.getDailyStress(start: start, end: yesterday))
        checkModels("getDailySteps", try await garmin.getDailySteps(start: start, end: yesterday))
        checkModels(
            "getDailyHydration", try await garmin.getDailyHydration(start: start, end: yesterday))
        checkModels(
            "getDailyBodyBattery",
            try await garmin.getDailyBodyBattery(start: weekAgo, end: yesterday, chunks: 4))
        checkModel("getDailySpO2", try await garmin.getDailySpO2(yesterday))
        checkModels(
            "getWellnessActivitySummaries",
            try await garmin.getWellnessActivitySummaries(
                start: today.adding(days: -365), end: today))
    }

    @Test func bodyAndNutrition() async throws {
        checkModel(
            "getWeightRange",
            try await garmin.getWeightRange(
                start: today.adding(days: -30), end: yesterday, includeAll: true))
        checkModel(
            "getEffectiveWeightGoals",
            try await garmin.getEffectiveWeightGoals(start: weekAgo, end: yesterday))
        checkModel("getDailyFoodLogs", try await garmin.getDailyFoodLogs(yesterday))
        if let summary = try await garmin.getMenstrualCycleSummary(yesterday) {
            checkModel("getMenstrualCycleSummary", summary)
        }
        if let view = try await garmin.getMenstrualCycleDayView(yesterday, today: today) {
            checkModel("getMenstrualCycleDayView", view)
        }
    }

    @Test func activityEndpoints() async throws {
        let recent = try await garmin.searchActivities(
            limit: 50, filters: ActivityFilters(startDate: today.adding(days: -90)))
        checkModels("searchActivities", recent)
        guard let id = recent.first?.activityId else { return }
        let activity = try await garmin.getActivity(id)
        let workouts = try await garmin.getActivityWorkouts(id)
        let download = try await garmin.downloadActivity(id)
        check(activity.activityId == id, "getActivity returned a different activity")
        check(!download.content.isEmpty, "downloadActivity returned an empty file")
        checkModel("getActivity", activity)
        checkModels("getActivityWorkouts", workouts)
    }

    @Test func iteratingActivitiesMatchesSearch() async throws {
        let filters = ActivityFilters(startDate: today.adding(days: -60))
        var iterated: [Int] = []
        for try await activity in try garmin.iterActivities(pageSize: 15, filters: filters) {
            iterated.append(activity.activityId)
        }
        let searched = try await garmin.searchActivities(
            limit: iterated.count + 5, filters: filters)
        check(
            iterated == searched.map(\.activityId), "iterActivities and searchActivities disagree")
    }

    @Test func rangesAreContiguous() async throws {
        let start = today.adding(days: -100)
        let steps = try await garmin.getDailySteps(start: start, end: yesterday)
        let days = steps.compactMap(\.calendarDate)
        check(days.count == steps.count, "some daily steps have no calendar date")
        check(days == days.sorted(), "windows are not returned in order")
        check(Set(days).count == days.count, "windows overlap")
        check(days.first == start, "the first window does not start at the requested date")
    }

    @Test func typedSeries() async throws {
        let samples = try await garmin.getDailyHeartRate(yesterday).heartRateSamples()
        check(
            samples.map(\.timestamp) == samples.map(\.timestamp).sorted(),
            "heart rate samples are not in order")
    }

    @Test func serverStillRejectsOversizedRequests() async throws {
        // If this starts failing, Garmin relaxed a limit and Constants.swift can be updated.
        do {
            _ = try await garmin.getJSON(
                "/usersummary-service/stats/steps/daily/\(today.adding(days: -60))/\(today)")
            check(false, "Garmin accepted a 61-day steps request")
        } catch is BadRequestError {
            return
        }
    }

    @Test func weightEntriesEndpointStatus() async throws {
        // Documented but broken server-side (HTTP 400) as of October 2026.
        do {
            checkModels(
                "getWeightEntries",
                try await garmin.getWeightEntries(start: weekAgo, end: yesterday))
        } catch is BadRequestError {
            return
        }
    }
}
