import ArgumentParser
import Foundation
import GCPAPISync

/// Commands that call one client method and print its result as JSON.
let jsonCommands: [any ParsableCommand.Type] = [
    GetActivity.self, GetActivityWorkouts.self, SearchActivities.self,
    DayCommand<DailySummaryCall>.self, RangeCommand<DailySummariesCall>.self,
    RangeCommand<WellnessActivitySummariesCall>.self, DayCommand<DailySleepCall>.self,
    RangeCommand<DailySleepSummariesCall>.self, DayCommand<DailyHeartRateCall>.self,
    GetHeartRateZones.self, DayCommand<DailyHRVCall>.self, RangeCommand<DailyHRVSummariesCall>.self,
    RangeCommand<DailyStressCall>.self, RangeCommand<DailyStepsCall>.self,
    RangeCommand<DailyHydrationCall>.self, GetDailyBodyBattery.self, DayCommand<DailySpO2Call>.self,
    GetFitnessAge.self, GetWeightRange.self, RangeCommand<WeightEntriesCall>.self,
    RangeCommand<EffectiveWeightGoalsCall>.self, GetDailyFoodLogs.self,
    DayCommand<MenstrualCycleSummaryCall>.self, GetMenstrualCycleDayView.self,
    GetUserProfileSettings.self, GetJSON.self,
]

/// A client method taking one day.
protocol DayCall {
    associatedtype Result: Encodable
    static var name: String { get }
    static var abstract: String { get }
    static func call(_ client: GarminClient, _ day: String) async throws -> Result
}

/// A client method taking a date range.
protocol RangeCall {
    associatedtype Result: Encodable
    static var name: String { get }
    static var abstract: String { get }
    static func call(_ client: GarminClient, _ start: String, _ end: String) async throws -> Result
}

struct DayCommand<Call: DayCall>: AsyncParsableCommand {
    static var configuration: CommandConfiguration { makeConfiguration(Call.name, Call.abstract) }

    @Argument(help: "The day (YYYY-MM-DD).")
    var day: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(try await Call.call(try global.client(), day))
    }
}

struct RangeCommand<Call: RangeCall>: AsyncParsableCommand {
    static var configuration: CommandConfiguration { makeConfiguration(Call.name, Call.abstract) }

    @Argument(help: "First day (YYYY-MM-DD).")
    var start: String
    @Argument(help: "Last day (YYYY-MM-DD), inclusive.")
    var end: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(try await Call.call(try global.client(), start, end))
    }
}

enum DailySummaryCall: DayCall {
    static let name = "get-daily-summary"
    static let abstract = "The day's wellness summary."
    static func call(_ client: GarminClient, _ day: String) async throws -> UserDailySummary {
        try await client.getDailySummary(day)
    }
}

enum DailySleepCall: DayCall {
    static let name = "get-daily-sleep"
    static let abstract = "The sleep record for a calendar day."
    static func call(_ client: GarminClient, _ day: String) async throws -> DailySleep {
        try await client.getDailySleep(day)
    }
}

enum DailyHeartRateCall: DayCall {
    static let name = "get-daily-heart-rate"
    static let abstract = "The day's heart rate time series."
    static func call(_ client: GarminClient, _ day: String) async throws -> DailyHeartRate {
        try await client.getDailyHeartRate(day)
    }
}

enum DailyHRVCall: DayCall {
    static let name = "get-daily-hrv"
    static let abstract = "The night's HRV summary and readings."
    static func call(_ client: GarminClient, _ day: String) async throws -> HrvChart? {
        try await client.getDailyHRV(day)
    }
}

enum DailySpO2Call: DayCall {
    static let name = "get-daily-spo2"
    static let abstract = "The day's pulse-ox readings and altitude acclimation."
    static func call(_ client: GarminClient, _ day: String) async throws -> DailySpO2AndAcclimation
    {
        try await client.getDailySpO2(day)
    }
}

enum MenstrualCycleSummaryCall: DayCall {
    static let name = "get-menstrual-cycle-summary"
    static let abstract = "The menstrual cycle summary for a day."
    static func call(_ client: GarminClient, _ day: String) async throws -> MenstrualCycleSummary? {
        try await client.getMenstrualCycleSummary(day)
    }
}

enum DailySummariesCall: RangeCall {
    static let name = "get-daily-summaries"
    static let abstract = "Detailed daily summaries for a date range."
    static func call(
        _ client: GarminClient, _ start: String, _ end: String
    ) async throws
        -> [UserDailySummaryV2]
    {
        try await client.getDailySummaries(start: start, end: end)
    }
}

enum WellnessActivitySummariesCall: RangeCall {
    static let name = "get-wellness-activity-summaries"
    static let abstract = "Wellness activities (such as breathing sessions) in a date range."
    static func call(
        _ client: GarminClient, _ start: String, _ end: String
    ) async throws
        -> [WellnessActivitySummary]
    {
        try await client.getWellnessActivitySummaries(start: start, end: end)
    }
}

enum DailySleepSummariesCall: RangeCall {
    static let name = "get-daily-sleep-summaries"
    static let abstract = "Sleep records for a date range."
    static func call(
        _ client: GarminClient, _ start: String, _ end: String
    ) async throws
        -> [DailySleep]
    {
        try await client.getDailySleepSummaries(start: start, end: end)
    }
}

enum DailyHRVSummariesCall: RangeCall {
    static let name = "get-daily-hrv-summaries"
    static let abstract = "Daily HRV summaries for a date range."
    static func call(
        _ client: GarminClient, _ start: String, _ end: String
    ) async throws
        -> [HrvSummary]
    {
        try await client.getDailyHRVSummaries(start: start, end: end)
    }
}

enum DailyStressCall: RangeCall {
    static let name = "get-daily-stress"
    static let abstract = "Daily stress levels and durations for a date range."
    static func call(
        _ client: GarminClient, _ start: String, _ end: String
    ) async throws
        -> [MultiValueWellnessChartItem]
    {
        try await client.getDailyStress(start: start, end: end)
    }
}

enum DailyStepsCall: RangeCall {
    static let name = "get-daily-steps"
    static let abstract = "Daily steps, distance and goal for a date range."
    static func call(
        _ client: GarminClient, _ start: String, _ end: String
    ) async throws
        -> [StepsDailyStat]
    {
        try await client.getDailySteps(start: start, end: end)
    }
}

enum DailyHydrationCall: RangeCall {
    static let name = "get-daily-hydration"
    static let abstract = "Daily hydration intake and goals for a date range."
    static func call(
        _ client: GarminClient, _ start: String, _ end: String
    ) async throws
        -> [UserDailyHydration]
    {
        try await client.getDailyHydration(start: start, end: end)
    }
}

enum WeightEntriesCall: RangeCall {
    static let name = "get-weight-entries"
    static let abstract = "All weight measurements in a date range (broken server-side)."
    static func call(
        _ client: GarminClient, _ start: String, _ end: String
    ) async throws
        -> [DateWeight]
    {
        try await client.getWeightEntries(start: start, end: end)
    }
}

enum EffectiveWeightGoalsCall: RangeCall {
    static let name = "get-effective-weight-goals"
    static let abstract = "The weight goals in effect during a date range."
    static func call(
        _ client: GarminClient, _ start: String, _ end: String
    ) async throws
        -> UserGoalsRange
    {
        try await client.getEffectiveWeightGoals(start: start, end: end)
    }
}

struct GetActivity: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "get-activity", "An activity's summary, metadata, measurements and splits.")

    @Argument(help: "The activity ID.")
    var activityID: Int

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(try await global.client().getActivity(activityID))
    }
}

struct GetActivityWorkouts: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "get-activity-workouts", "The structured workouts performed during an activity.")

    @Argument(help: "The activity ID.")
    var activityID: Int

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(try await global.client().getActivityWorkouts(activityID))
    }
}

struct SearchActivities: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "search-activities", "Activities matching the filters, newest first by default.")

    @Option(help: "Zero-based offset of the first activity.")
    var start = 0
    @Option(help: "Maximum number of activities.")
    var limit = 20

    @OptionGroup var filters: FilterOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(
            try await global.client().searchActivities(
                start: start, limit: limit, filters: filters.filters()))
    }
}

struct GetHeartRateZones: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "get-heart-rate-zones", "The heart rate zone configuration per sport.")

    @Flag(inversion: .prefixedNo, help: "Return default zones when none are configured.")
    var generateDefaults = true

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(
            try await global.client().getHeartRateZones(generateDefaults: generateDefaults))
    }
}

struct GetDailyBodyBattery: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "get-daily-body-battery", "Daily Body Battery reports for a date range.")

    @Argument(help: "First day (YYYY-MM-DD).")
    var start: String
    @Argument(help: "Last day (YYYY-MM-DD), inclusive.")
    var end: String
    @Option(help: "Split each day into this many intervals.")
    var chunks: Int?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(
            try await global.client().getDailyBodyBattery(start: start, end: end, chunks: chunks))
    }
}

struct GetFitnessAge: AsyncParsableCommand {
    static let configuration = makeConfiguration("get-fitness-age", "The latest Fitness Age.")

    @Argument(help: "Reference date (YYYY-MM-DD).")
    var day: String
    @Flag(inversion: .prefixedNo, help: "Search the full history, not just 28 days.")
    var fullHistoryScan = true

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(
            try await global.client().getFitnessAge(day, fullHistoryScan: fullHistoryScan))
    }
}

struct GetWeightRange: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "get-weight-range", "Weight summaries for a date range (weights in grams).")

    @Argument(help: "First day (YYYY-MM-DD).")
    var start: String
    @Argument(help: "Last day (YYYY-MM-DD), inclusive.")
    var end: String
    @Flag(name: long("include-all"), help: "Include every measurement of each day.")
    var includeAll = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(
            try await global.client().getWeightRange(start: start, end: end, includeAll: includeAll)
        )
    }
}

struct GetDailyFoodLogs: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "get-daily-food-logs", "The day's nutrition log, goals and per-meal breakdown.")

    @Argument(help: "The day (YYYY-MM-DD).")
    var day: String
    @Flag(inversion: .prefixedNo, help: "Include nutrition goals.")
    var includeGoals = true
    @Flag(inversion: .prefixedNo, help: "Include nutrient totals.")
    var includeNutrition = true
    @Flag(inversion: .prefixedNo, help: "Include food images.")
    var includeMedia = true
    @Option(name: long("meal-id"), help: "Only this meal.")
    var mealID: Int?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(
            try await global.client().getDailyFoodLogs(
                day, includeGoals: includeGoals, includeNutrition: includeNutrition,
                includeMedia: includeMedia, mealID: mealID))
    }
}

struct GetMenstrualCycleDayView: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "get-menstrual-cycle-day-view", "The detailed menstrual cycle view for a day.")

    @Argument(help: "The day (YYYY-MM-DD).")
    var day: String
    @Option(help: "Reference \"today\" for predictions.")
    var today: String?
    @Flag(name: long("reduced-response"), help: "Request a lighter payload.")
    var reducedResponse = false
    @Flag(name: long("skip-baby-movement"), help: "Omit kick-count data.")
    var skipBabyMovement = false
    @Flag(name: long("include-analysis"), help: "Include cycle analysis.")
    var includeAnalysis = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(
            try await global.client().getMenstrualCycleDayView(
                day, today: today, reducedResponse: reducedResponse,
                skipBabyMovement: skipBabyMovement, includeAnalysis: includeAnalysis))
    }
}

struct GetUserProfileSettings: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "get-user-profile-settings", "The user's profile settings.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.printJSON(try await global.client().getUserProfileSettings())
    }
}

struct GetJSON: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "get-json", "GET any path on the API host and print the JSON.")

    @Argument(help: "Absolute path, such as /sleep-service/sleep/dailySleep.")
    var path: String
    @Option(help: "A query parameter as name=value (repeatable).")
    var param: [String] = []

    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if param.contains(where: { !$0.contains("=") }) {
            throw ValidationError("--param must be written as name=value")
        }
    }

    func run() async throws {
        let query = param.map { item in
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            return QueryItem(parts[0], parts.count > 1 ? parts[1] : "")
        }
        try await global.printJSON(try await global.client().getJSON(path, query: query))
    }
}
