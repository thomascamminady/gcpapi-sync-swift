import Foundation

@testable import GCPAPISync

// One case per client method: how it is called and what it must send and return.

let day = "2026-10-21"
let rangeStart = "2026-10-15"
let rangeEnd = "2026-10-21"
let activityID = 24_799_472_038
let fitBytes = Data([0x0e, 0x10]) + Data(".FIT-data".utf8)
let activityZip = zipArchive([("\(activityID)_ACTIVITY.fit", fitBytes)])

/// A client method call, the request it must make and how many items it must return.
struct Case: Sendable, CustomStringConvertible {
    let method: String
    let path: String
    let reply: Reply
    var params: [[String]] = []
    var accept = "application/json"
    /// Calls the method; returns the number of items (1 for a single value, `nil` for none).
    let call: @Sendable (GarminClient) async throws -> Int?

    var description: String { method }
}

private func count<T>(_ items: [T]) -> Int? { items.count }
private func one<T>(_ value: T?) -> Int? { value == nil ? nil : 1 }

let zipReply = Reply(body: activityZip, headers: ["Content-Type": "application/x-zip-compressed"])

let cases: [Case] = [
    Case(
        method: "getActivity", path: "/activity-service/activity/\(activityID)",
        reply: .bundled("activity")
    ) { one(try await $0.getActivity(activityID)) },
    Case(
        method: "getActivityWorkouts", path: "/activity-service/activity/\(activityID)/workouts",
        reply: .json([["workoutId": 1, "workoutName": "Intervals"]])
    ) { count(try await $0.getActivityWorkouts(activityID)) },
    Case(
        method: "searchActivities", path: "/activitylist-service/activities/search/activities",
        reply: .bundled("search_activities"),
        params: [
            ["start", "0"], ["limit", "3"], ["startDate", rangeStart], ["activityType", "running"],
        ]
    ) {
        count(
            try await $0.searchActivities(
                limit: 3,
                filters: ActivityFilters(startDate: rangeStart, activityType: "running")))
    },
    Case(
        method: "downloadActivity", path: "/download-service/files/activity/\(activityID)",
        reply: zipReply, accept: "application/x-zip-compressed"
    ) { one(try await $0.downloadActivity(activityID)) },
    Case(
        method: "downloadActivityZip", path: "/download-service/files/activity/\(activityID)",
        reply: zipReply, accept: "application/x-zip-compressed"
    ) { one(try await $0.downloadActivityZip(activityID)) },
    Case(
        method: "getHeartRateZones", path: "/biometric-service/heartRateZones/v2",
        reply: .bundled("heart_rate_zones"), params: [["generateDefaults", "false"]]
    ) { count(try await $0.getHeartRateZones(generateDefaults: false)) },
    Case(
        method: "getFitnessAge", path: "/fitnessage-service/fitnessage/v2/\(day)",
        reply: .bundled("fitness_age"), params: [["fullHistoryScan", "true"]]
    ) { one(try await $0.getFitnessAge(day)) },
    Case(
        method: "getEffectiveWeightGoals",
        path: "/goal-service/goal/user/effective/weightgoal/\(rangeStart)/\(rangeEnd)",
        reply: .bundled("effective_weight_goals")
    ) { one(try await $0.getEffectiveWeightGoals(start: rangeStart, end: rangeEnd)) },
    Case(
        method: "getDailyHRV", path: "/hrv-service/hrv/\(day)",
        reply: .bundled("daily_hrv")
    ) { one(try await $0.getDailyHRV(day)) },
    Case(
        method: "getDailyHRVSummaries", path: "/hrv-service/hrv/daily/\(rangeStart)/\(rangeEnd)",
        reply: .bundled("daily_hrv_summaries")
    ) { count(try await $0.getDailyHRVSummaries(start: rangeStart, end: rangeEnd)) },
    Case(
        method: "getDailyFoodLogs", path: "/nutrition-service/food/logs/\(day)",
        reply: .bundled("daily_food_logs"),
        params: [
            ["includeGoals", "true"], ["includeNutrition", "true"], ["includeMedia", "false"],
            ["mealId", "3"],
        ]
    ) { one(try await $0.getDailyFoodLogs(day, includeMedia: false, mealID: 3)) },
    Case(
        method: "getMenstrualCycleSummary",
        path: "/periodichealth-service/menstrualcycle/summary/\(day)",
        reply: Reply(status: 204)
    ) { one(try await $0.getMenstrualCycleSummary(day)) },
    Case(
        method: "getMenstrualCycleDayView",
        path: "/periodichealth-service/menstrualcycle/dayview/\(day)",
        reply: .json(["calendarDate": .string(day)]),
        params: [
            ["todayDate", day], ["reducedResponse", "false"], ["skipbm", "false"],
            ["includeAnalysis", "true"],
        ]
    ) { one(try await $0.getMenstrualCycleDayView(day, today: day, includeAnalysis: true)) },
    Case(
        method: "getDailySleep", path: "/sleep-service/sleep/dailySleep",
        reply: .bundled("daily_sleep"), params: [["date", day]]
    ) { one(try await $0.getDailySleep(day)) },
    Case(
        method: "getDailySleepSummaries", path: "/sleep-service/sleep/dailySleepSummariesByDate",
        reply: .bundled("daily_sleep_summaries"),
        params: [["startDate", rangeStart], ["endDate", rangeEnd]]
    ) { count(try await $0.getDailySleepSummaries(start: rangeStart, end: rangeEnd)) },
    Case(
        method: "getUserProfileSettings", path: "/userprofile-service/userprofile/settings",
        reply: .bundled("user_profile_settings")
    ) { one(try await $0.getUserProfileSettings()) },
    Case(
        method: "getDailyHydration",
        path: "/usersummary-service/stats/hydration/daily/\(rangeStart)/\(rangeEnd)",
        reply: .json([["calendarDate": .string(rangeEnd), "valueInML": 1500.0, "goalInML": 2500.0]])
    ) { count(try await $0.getDailyHydration(start: rangeStart, end: rangeEnd)) },
    Case(
        method: "getDailySteps",
        path: "/usersummary-service/stats/steps/daily/\(rangeStart)/\(rangeEnd)",
        reply: .bundled("daily_steps")
    ) { count(try await $0.getDailySteps(start: rangeStart, end: rangeEnd)) },
    Case(
        method: "getDailyStress",
        path: "/usersummary-service/stats/stress/daily/\(rangeStart)/\(rangeEnd)",
        reply: .bundled("daily_stress")
    ) { count(try await $0.getDailyStress(start: rangeStart, end: rangeEnd)) },
    Case(
        method: "getDailySummary", path: "/usersummary-service/usersummary/daily",
        reply: .bundled("daily_summary"), params: [["calendarDate", day]]
    ) { one(try await $0.getDailySummary(day)) },
    Case(
        method: "getDailySummaries", path: "/usersummary-service/v2/dailysummaries",
        reply: .bundled("daily_summaries"),
        params: [["startDate", rangeStart], ["endDate", rangeEnd]]
    ) { count(try await $0.getDailySummaries(start: rangeStart, end: rangeEnd)) },
    Case(
        method: "getWeightEntries", path: "/weight-service/weight/all/\(rangeStart)/\(rangeEnd)",
        reply: .json([
            ["calendarDate": .string(rangeEnd), "weight": 70_000.0, "date": 1_792_621_739_000]
        ])
    ) { count(try await $0.getWeightEntries(start: rangeStart, end: rangeEnd)) },
    Case(
        method: "getWeightRange", path: "/weight-service/weight/range/\(rangeStart)/\(rangeEnd)",
        reply: .bundled("weight_range"), params: [["includeAll", "true"]]
    ) {
        one(try await $0.getWeightRange(start: rangeStart, end: rangeEnd, includeAll: true))
    },
    Case(
        method: "getDailyBodyBattery", path: "/wellness-service/wellness/bodyBattery/reports/daily",
        reply: .bundled("daily_body_battery"),
        params: [["startDate", rangeStart], ["endDate", rangeEnd], ["chunks", "4"]]
    ) {
        count(try await $0.getDailyBodyBattery(start: rangeStart, end: rangeEnd, chunks: 4))
    },
    Case(
        method: "getDailySpO2", path: "/wellness-service/wellness/daily/spo2acclimation/\(day)",
        reply: .bundled("daily_spo2")
    ) { one(try await $0.getDailySpO2(day)) },
    Case(
        method: "getDailyHeartRate", path: "/wellness-service/wellness/dailyHeartRate",
        reply: .bundled("daily_heart_rate"), params: [["date", day]]
    ) { one(try await $0.getDailyHeartRate(day)) },
    Case(
        method: "getWellnessActivitySummaries",
        path: "/wellnessactivity-service/activity/summary/range/\(rangeStart)/\(rangeEnd)",
        reply: .bundled("wellness_activity_summaries")
    ) { count(try await $0.getWellnessActivitySummaries(start: rangeStart, end: rangeEnd)) },
    Case(
        method: "getJSON", path: "/userprofile-service/userprofile/settings",
        reply: .bundled("user_profile_settings"), params: [["a", "1"]]
    ) {
        let value = try await $0.getJSON(
            "/userprofile-service/userprofile/settings", query: [QueryItem("a", "1")])
        return value?.objectValue == nil ? nil : 1
    },
]
