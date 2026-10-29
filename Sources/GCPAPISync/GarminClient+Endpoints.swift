public import Foundation

/// One method per Personal API endpoint.
extension GarminClient {
    // MARK: - Escape hatch

    /// GET any path on the API host and return the decoded JSON.
    ///
    /// For endpoints this package does not wrap yet. Authentication, retries and error
    /// handling work as for the typed methods.
    ///
    /// - Parameters:
    ///   - path: Absolute path, such as `"/sleep-service/sleep/dailySleep"`.
    ///   - query: Query parameters; repeat a name to send it several times.
    /// - Returns: The decoded JSON, or `nil` for an empty response.
    /// - Throws: ``InvalidArgumentError`` for invalid arguments, or an ``APIError`` if the request
    ///   fails.
    public func getJSON(_ path: String, query: [QueryItem] = []) async throws -> JSONValue? {
        try await request(Endpoints.json(path, query: query))
    }

    // MARK: - Activities

    /// An activity's summary, metadata, measurements and splits.
    public func getActivity(_ activityID: Int) async throws -> ActivitySummary {
        try await request(Endpoints.activity(activityID))
    }

    /// The structured workouts performed during an activity.
    public func getActivityWorkouts(_ activityID: Int) async throws -> [ActivityWorkout] {
        try await request(Endpoints.activityWorkouts(activityID))
    }

    /// Up to `limit` activities matching `filters`, newest first by default.
    ///
    /// Large limits are fetched in several pages (the server fails on big pages).
    ///
    /// - Parameters:
    ///   - start: Zero-based offset of the first activity.
    ///   - limit: Maximum number of activities to return.
    ///   - filters: See ``ActivityFilters``.
    /// - Returns: The activities, in the server's order.
    /// - Throws: ``InvalidArgumentError`` for invalid arguments, or an ``APIError`` if the request
    ///   fails.
    public func searchActivities(
        start: Int = 0, limit: Int = 20, filters: ActivityFilters = ActivityFilters()
    ) async throws -> [SummarizedActivity] {
        guard start >= 0, limit >= 0 else {
            throw InvalidArgumentError("start and limit must be >= 0")
        }
        let query = try filters.queryItems()
        var activities: [SummarizedActivity] = []
        while activities.count < limit {
            let size = min(limit - activities.count, Constants.defaultActivityPageSize)
            let page = try await request(
                Endpoints.searchActivities(
                    start: start + activities.count, limit: size, filters: query))
            activities += page
            if page.count < size {
                break
            }
        }
        return activities
    }

    /// All activities matching `filters`, fetched lazily page by page.
    ///
    /// ```swift
    /// let runs = ActivityFilters(activityType: "running")
    /// for try await activity in try garmin.iterActivities(filters: runs) {
    ///     print(activity.activityId)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - start: Zero-based offset of the first activity.
    ///   - pageSize: Activities per request (1 to 45).
    ///   - filters: See ``ActivityFilters``.
    /// - Throws: ``InvalidArgumentError`` for an out-of-range page size or offset, or a
    ///   malformed date filter.
    /// - Returns: An `AsyncSequence` of activities.
    public func iterActivities(
        start: Int = 0, pageSize: Int = 20, filters: ActivityFilters = ActivityFilters()
    ) throws -> ActivitySequence {
        guard (1...Constants.maxActivityPageSize).contains(pageSize) else {
            throw InvalidArgumentError(
                "pageSize must be between 1 and \(Constants.maxActivityPageSize)")
        }
        guard start >= 0 else { throw InvalidArgumentError("start must be >= 0") }
        return ActivitySequence(
            client: self, start: start, pageSize: pageSize, query: try filters.queryItems())
    }

    /// Download an activity in its original format (usually FIT).
    public func downloadActivity(_ activityID: Int) async throws -> ActivityFile {
        try await request(Endpoints.downloadActivity(activityID))
    }

    /// Download an activity as the zip archive Garmin serves.
    public func downloadActivityZip(_ activityID: Int) async throws -> Data {
        try await request(Endpoints.downloadActivityZip(activityID))
    }

    // MARK: - Daily summaries

    /// The day's wellness summary: steps, calories, stress, Body Battery, ...
    public func getDailySummary(_ day: some DateLike) async throws -> UserDailySummary {
        try await request(Endpoints.dailySummary(day))
    }

    /// Detailed daily summaries for each day from `start` to `end` (inclusive).
    public func getDailySummaries(
        start: some DateLike, end: some DateLike
    ) async throws
        -> [UserDailySummaryV2]
    {
        try await collect(start, end, maxDays: Constants.maxDaysDailySummaries) {
            Endpoints.dailySummaries($0, $1)
        }
    }

    /// Wellness activities (such as breathing sessions) in a date range.
    public func getWellnessActivitySummaries(
        start: some DateLike, end: some DateLike
    )
        async throws -> [WellnessActivitySummary]
    {
        let (first, last) = try DateRange.resolve(start, end)
        return try await request(Endpoints.wellnessActivitySummaries(first, last))
    }

    // MARK: - Sleep

    /// The sleep record for a calendar day (the night ending that morning).
    public func getDailySleep(_ day: some DateLike) async throws -> DailySleep {
        try await request(Endpoints.dailySleep(day))
    }

    /// Sleep records for each day from `start` to `end` (inclusive).
    public func getDailySleepSummaries(
        start: some DateLike, end: some DateLike
    ) async throws
        -> [DailySleep]
    {
        try await collect(start, end, maxDays: Constants.maxDaysSleep) {
            Endpoints.dailySleepSummaries($0, $1)
        }
    }

    // MARK: - Heart

    /// The day's heart rate time series and resting/min/max values.
    public func getDailyHeartRate(_ day: some DateLike) async throws -> DailyHeartRate {
        try await request(Endpoints.dailyHeartRate(day))
    }

    /// The user's heart rate zone configuration per sport.
    ///
    /// - Parameter generateDefaults: Return default zones when none are configured.
    /// - Returns: The zones of each sport.
    /// - Throws: ``InvalidArgumentError`` for invalid arguments, or an ``APIError`` if the request
    ///   fails.
    public func getHeartRateZones(generateDefaults: Bool = true) async throws -> [HeartRateZones] {
        try await request(Endpoints.heartRateZones(generateDefaults: generateDefaults))
    }

    /// The night's HRV summary and readings, or `nil` without data.
    public func getDailyHRV(_ day: some DateLike) async throws -> HrvChart? {
        try await request(Endpoints.dailyHRV(day))
    }

    /// Daily HRV summaries from `start` to `end` (inclusive).
    public func getDailyHRVSummaries(
        start: some DateLike, end: some DateLike
    ) async throws
        -> [HrvSummary]
    {
        try await collect(start, end, maxDays: Constants.maxDaysHRV) {
            Endpoints.dailyHRVSummaries($0, $1)
        }
    }

    // MARK: - Wellness

    /// Daily stress levels and durations from `start` to `end` (inclusive).
    public func getDailyStress(
        start: some DateLike, end: some DateLike
    ) async throws
        -> [MultiValueWellnessChartItem]
    {
        try await collect(start, end, maxDays: Constants.maxDaysStress) {
            Endpoints.dailyStress($0, $1)
        }
    }

    /// Daily steps, distance and goal from `start` to `end` (inclusive).
    public func getDailySteps(
        start: some DateLike, end: some DateLike
    ) async throws
        -> [StepsDailyStat]
    {
        try await collect(start, end, maxDays: Constants.maxDaysSteps) {
            Endpoints.dailySteps($0, $1)
        }
    }

    /// Daily hydration intake and goals from `start` to `end` (inclusive).
    public func getDailyHydration(
        start: some DateLike, end: some DateLike
    ) async throws
        -> [UserDailyHydration]
    {
        try await collect(start, end, maxDays: Constants.maxDaysHydration) {
            Endpoints.dailyHydration($0, $1)
        }
    }

    /// Daily Body Battery reports from `start` to `end` (inclusive).
    ///
    /// - Parameters:
    ///   - start: First day.
    ///   - end: Last day.
    ///   - chunks: Split each day into this many intervals and report the lowest and
    ///     highest reading of each.
    /// - Returns: One report per day.
    /// - Throws: ``InvalidArgumentError`` for invalid arguments, or an ``APIError`` if the request
    ///   fails.
    public func getDailyBodyBattery(
        start: some DateLike, end: some DateLike, chunks: Int? = nil
    )
        async throws -> [BodyBatteryDailyReport]
    {
        try await collect(start, end, maxDays: Constants.maxDaysBodyBattery) {
            try Endpoints.dailyBodyBattery($0, $1, chunks: chunks)
        }
    }

    /// The day's pulse-ox (SpO2) readings and altitude acclimation.
    public func getDailySpO2(_ day: some DateLike) async throws -> DailySpO2AndAcclimation {
        try await request(Endpoints.dailySpO2(day))
    }

    /// The latest Fitness Age as of `day`.
    ///
    /// - Parameters:
    ///   - day: Reference date.
    ///   - fullHistoryScan: Search the full history; `false` only looks at the 28 days
    ///     before `day`.
    /// - Returns: The Fitness Age record.
    /// - Throws: ``InvalidArgumentError`` for invalid arguments, or an ``APIError`` if the request
    ///   fails.
    public func getFitnessAge(
        _ day: some DateLike, fullHistoryScan: Bool = true
    ) async throws
        -> FitnessAge
    {
        try await request(Endpoints.fitnessAge(day, fullHistoryScan: fullHistoryScan))
    }

    // MARK: - Body composition

    /// Weight summaries for a date range: per-day values and the range average.
    ///
    /// Weights are in grams. Garmin computes the average over the whole range, so the range
    /// is sent as one request; ranges beyond about a year may fail server-side.
    ///
    /// - Parameters:
    ///   - start: First day.
    ///   - end: Last day.
    ///   - includeAll: Include every measurement of each day, not just the latest.
    /// - Returns: The per-day weights and the range average.
    /// - Throws: ``InvalidArgumentError`` for invalid arguments, or an ``APIError`` if the request
    ///   fails.
    public func getWeightRange(
        start: some DateLike, end: some DateLike, includeAll: Bool = false
    )
        async throws -> WeightRange
    {
        let (first, last) = try DateRange.resolve(start, end)
        return try await request(Endpoints.weightRange(first, last, includeAll: includeAll))
    }

    /// All weight measurements in a date range.
    ///
    /// As of October 2026 Garmin answers this documented endpoint with HTTP 400 for every
    /// input. Use ``getWeightRange(start:end:includeAll:)`` with `includeAll: true` instead.
    public func getWeightEntries(
        start: some DateLike, end: some DateLike
    ) async throws
        -> [DateWeight]
    {
        let (first, last) = try DateRange.resolve(start, end)
        return try await request(Endpoints.weightEntries(first, last))
    }

    /// The weight goals in effect during a date range.
    public func getEffectiveWeightGoals(
        start: some DateLike, end: some DateLike
    ) async throws
        -> UserGoalsRange
    {
        let (first, last) = try DateRange.resolve(start, end)
        return try await request(Endpoints.effectiveWeightGoals(first, last))
    }

    // MARK: - Nutrition

    /// The day's nutrition log, goals and per-meal breakdown.
    ///
    /// - Parameters:
    ///   - day: Calendar day.
    ///   - includeGoals: Include nutrition goals.
    ///   - includeNutrition: Include nutrient totals.
    ///   - includeMedia: Include food images.
    ///   - mealID: Only this meal.
    /// - Returns: The nutrition summary.
    /// - Throws: ``InvalidArgumentError`` for invalid arguments, or an ``APIError`` if the request
    ///   fails.
    public func getDailyFoodLogs(
        _ day: some DateLike, includeGoals: Bool = true, includeNutrition: Bool = true,
        includeMedia: Bool = true, mealID: Int? = nil
    ) async throws -> DailyNutritionSummary {
        try await request(
            Endpoints.dailyFoodLogs(
                day, includeGoals: includeGoals, includeNutrition: includeNutrition,
                includeMedia: includeMedia, mealID: mealID
            )
        )
    }

    // MARK: - Women's health

    /// The menstrual cycle summary for `day`, or `nil` if not tracked.
    public func getMenstrualCycleSummary(
        _ day: some DateLike
    ) async throws
        -> MenstrualCycleSummary?
    {
        try await request(Endpoints.menstrualCycleSummary(day))
    }

    /// The detailed menstrual cycle view for `day`, or `nil` if not tracked.
    ///
    /// - Parameters:
    ///   - day: Calendar day.
    ///   - today: Reference "today" for predictions.
    ///   - reducedResponse: Request a lighter payload.
    ///   - skipBabyMovement: Omit kick-count data.
    ///   - includeAnalysis: Include cycle analysis.
    /// - Returns: The day view, or `nil` if not tracked.
    /// - Throws: ``InvalidArgumentError`` for invalid arguments, or an ``APIError`` if the request
    ///   fails.
    public func getMenstrualCycleDayView(
        _ day: some DateLike, today: (any DateLike)? = nil, reducedResponse: Bool = false,
        skipBabyMovement: Bool = false, includeAnalysis: Bool = false
    ) async throws -> DetailedMenstrualCycleDay? {
        try await request(
            Endpoints.menstrualCycleDayView(
                day, today: today, reducedResponse: reducedResponse,
                skipBabyMovement: skipBabyMovement, includeAnalysis: includeAnalysis
            )
        )
    }

    // MARK: - Profile

    /// The user's profile settings (units, measurements, preferences).
    public func getUserProfileSettings() async throws -> UserSettings {
        try await request(Endpoints.userProfileSettings())
    }
}
