import Foundation

/// One GET request against the API and how to decode its response.
struct Endpoint<Result: Sendable>: Sendable {
    let path: String
    var query: [QueryItem] = []
    var accept = Self.json
    let parse: @Sendable (HTTPResponse) throws -> Result

    static var json: String { "application/json" }
    /// Garmin answers HTTP 406 for `application/octet-stream`.
    static var zip: String { "application/x-zip-compressed" }
}

// MARK: - Response parsers

enum Parse {
    static func isEmpty(_ response: HTTPResponse) -> Bool {
        response.statusCode == 204
            || response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func validate<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch let error as DecodingError {
            let (path, reason) = describe(error)
            throw ResponseValidationError(
                "GET \(response.request.path) returned data that does not match the expected "
                    + "model (first error at \(path): \(reason)). The raw payload is available "
                    + "as .raw; please report this at "
                    + "https://github.com/thomascamminady/gcpapi-sync-swift/issues",
                response: response, validationError: "\(path): \(reason)"
            )
        }
    }

    /// Where a decoding error happened and why, without any values from the payload.
    static func describe(_ error: DecodingError) -> (String, String) {
        let context: DecodingError.Context
        var reason: String
        switch error {
        case .typeMismatch(let type, let errorContext):
            context = errorContext
            reason = "expected \(type)"
        case .valueNotFound(let type, let errorContext):
            context = errorContext
            reason = "missing \(type)"
        case .keyNotFound(let key, let errorContext):
            context = errorContext
            reason = "missing required field \(key.stringValue)"
        case .dataCorrupted(let errorContext):
            context = errorContext
            reason = errorContext.debugDescription
        @unknown default:
            return ("<root>", "invalid data")
        }
        if case .dataCorrupted = error, context.codingPath.isEmpty {
            reason = "not valid JSON"
        }
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            .joined(separator: ".")
        return (path.isEmpty ? "<root>" : path, reason)
    }

    /// The decoded body, or `empty()` for an empty response.
    static func value<T: Decodable & Sendable>(
        _ type: T.Type, empty: @escaping @Sendable () -> T
    )
        -> @Sendable (HTTPResponse) throws -> T
    {
        { response in isEmpty(response) ? empty() : try validate(type, response) }
    }

    /// The decoded body; an empty response is an error.
    static func required<T: Decodable & Sendable>(
        _ type: T.Type
    )
        -> @Sendable (HTTPResponse) throws -> T
    {
        { response in
            guard !isEmpty(response) else {
                throw ResponseValidationError(
                    "GET \(response.request.path) returned an empty response", response: response)
            }
            return try validate(type, response)
        }
    }

    /// The decoded body, or `nil` for an empty response.
    static func optional<T: Decodable & Sendable>(
        _ type: T.Type
    )
        -> @Sendable (HTTPResponse) throws -> T?
    {
        { response in isEmpty(response) ? nil : try validate(type, response) }
    }

    static func list<T: Decodable & Sendable>(
        _: T.Type
    )
        -> @Sendable (HTTPResponse) throws -> [T]
    {
        value([T].self) { [] }
    }

    static func archive(_ response: HTTPResponse) throws -> Data {
        guard !response.body.isEmpty else {
            throw ResponseValidationError("The activity download was empty", response: response)
        }
        return response.body
    }
}

// MARK: - Activity filters

/// Geographic box for filtering activities by start location, in decimal degrees.
public struct BoundingBox: Hashable, Sendable {
    /// Northern latitude boundary.
    public let north: Double
    /// Eastern longitude boundary.
    public let east: Double
    /// Southern latitude boundary.
    public let south: Double
    /// Western longitude boundary.
    public let west: Double

    /// A bounding box.
    public init(north: Double, east: Double, south: Double, west: Double) {
        self.north = north
        self.east = east
        self.south = south
        self.west = west
    }
}

/// Sort direction for activity searches.
public enum SortOrder: String, Sendable {
    /// Ascending.
    case asc
    /// Descending (the server default).
    case desc
}

/// Filters accepted by ``GarminClient/searchActivities(start:limit:filters:)`` and
/// ``GarminClient/iterActivities(start:pageSize:filters:)``.
///
/// All filters are optional and combined with AND. Distances are in meters, durations in
/// seconds.
public struct ActivityFilters: Sendable {
    /// Earliest local start date, inclusive.
    public var startDate: (any DateLike)?
    /// Latest local start date, inclusive.
    public var endDate: (any DateLike)?
    /// Parent activity type key, such as `running` or `cycling` (not a subtype).
    public var activityType: String?
    /// Activity subtype key, such as `trail_running`.
    public var activitySubtype: String?
    /// Subtype keys to exclude.
    public var excludedActivitySubtypes: [String]?
    /// Event type key, such as `race`, `training`, `recreation` or `uncategorized`.
    public var eventType: String?
    /// Text to search for in activity names and descriptions.
    public var search: String?
    /// Only favorites (`true`) or only non-favorites (`false`).
    public var favorite: Bool?
    /// Field to sort by, such as `startLocal` (default), `distance` or `duration`.
    public var sortBy: String?
    /// Sort direction (default ``SortOrder/desc``).
    public var sortOrder: SortOrder?
    /// Exclude child activities, such as legs of a multisport activity (server default
    /// `true`).
    public var excludeChildren: Bool?
    /// Minimum distance in meters.
    public var minDistance: Int?
    /// Maximum distance in meters.
    public var maxDistance: Int?
    /// Minimum timer duration in seconds.
    public var minDuration: Int?
    /// Maximum timer duration in seconds.
    public var maxDuration: Int?
    /// Minimum elapsed duration (including pauses) in seconds.
    public var minElapsedDuration: Int?
    /// Maximum elapsed duration (including pauses) in seconds.
    public var maxElapsedDuration: Int?
    /// Minimum total elevation gain in meters.
    public var minElevation: Int?
    /// Maximum total elevation gain in meters.
    public var maxElevation: Int?
    /// Minimum average power in watts.
    public var minAvgPower: Int?
    /// Only activities that started inside this box.
    public var boundingBox: BoundingBox?
    /// Dives: minimum of the maximum depth, in centimeters.
    public var lowerMaxDepth: Int?
    /// Dives: maximum of the maximum depth, in centimeters.
    public var upperMaxDepth: Int?
    /// Dives: only decompression (`true`) or non-decompression (`false`) dives.
    public var decoDive: Bool?
    /// Dives: minimum bottom time in seconds.
    public var minBottomTime: Int?
    /// Dives: maximum bottom time in seconds.
    public var maxBottomTime: Int?
    /// Activity fields that must be non-null, such as `avgPower`.
    public var requiredFields: [String]?

    /// Filters; every one defaults to "not filtered".
    public init(
        startDate: (any DateLike)? = nil,
        endDate: (any DateLike)? = nil,
        activityType: String? = nil,
        activitySubtype: String? = nil,
        excludedActivitySubtypes: [String]? = nil,
        eventType: String? = nil,
        search: String? = nil,
        favorite: Bool? = nil,
        sortBy: String? = nil,
        sortOrder: SortOrder? = nil,
        excludeChildren: Bool? = nil,
        minDistance: Int? = nil,
        maxDistance: Int? = nil,
        minDuration: Int? = nil,
        maxDuration: Int? = nil,
        minElapsedDuration: Int? = nil,
        maxElapsedDuration: Int? = nil,
        minElevation: Int? = nil,
        maxElevation: Int? = nil,
        minAvgPower: Int? = nil,
        boundingBox: BoundingBox? = nil,
        lowerMaxDepth: Int? = nil,
        upperMaxDepth: Int? = nil,
        decoDive: Bool? = nil,
        minBottomTime: Int? = nil,
        maxBottomTime: Int? = nil,
        requiredFields: [String]? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.activityType = activityType
        self.activitySubtype = activitySubtype
        self.excludedActivitySubtypes = excludedActivitySubtypes
        self.eventType = eventType
        self.search = search
        self.favorite = favorite
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.excludeChildren = excludeChildren
        self.minDistance = minDistance
        self.maxDistance = maxDistance
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.minElapsedDuration = minElapsedDuration
        self.maxElapsedDuration = maxElapsedDuration
        self.minElevation = minElevation
        self.maxElevation = maxElevation
        self.minAvgPower = minAvgPower
        self.boundingBox = boundingBox
        self.lowerMaxDepth = lowerMaxDepth
        self.upperMaxDepth = upperMaxDepth
        self.decoDive = decoDive
        self.minBottomTime = minBottomTime
        self.maxBottomTime = maxBottomTime
        self.requiredFields = requiredFields
    }

    /// The filters as query parameters, in the order the Python client sends them.
    ///
    /// - Throws: ``InvalidArgumentError`` for a malformed date.
    func queryItems() throws -> [QueryItem] {
        var items: [QueryItem] = []
        if let startDate {
            items.append(
                QueryItem("startDate", "\(try startDate.garminDate(argument: "startDate"))"))
        }
        if let endDate {
            items.append(QueryItem("endDate", "\(try endDate.garminDate(argument: "endDate"))"))
        }
        if let favorite {
            items.append(QueryItem("favorite", favorite ? "1" : "0"))
        }
        if let box = boundingBox {
            items += [
                QueryItem("upperLatitude", "\(box.north)"),
                QueryItem("rightLongitude", "\(box.east)"),
                QueryItem("lowerLatitude", "\(box.south)"),
                QueryItem("leftLongitude", "\(box.west)"),
            ]
        }
        for (name, flag) in [("excludeChildren", excludeChildren), ("decoDive", decoDive)] {
            if let flag {
                items.append(QueryItem(name, flag ? "true" : "false"))
            }
        }
        items += (excludedActivitySubtypes ?? []).map { QueryItem("excludedActivitySubType", $0) }
        items += (requiredFields ?? []).map { QueryItem("requiredField", $0) }
        let scalars: [(String, String?)] = [
            ("activityType", activityType),
            ("activitySubType", activitySubtype),
            ("eventType", eventType),
            ("search", search),
            ("sortBy", sortBy),
            ("sortOrder", sortOrder?.rawValue),
            ("minDistance", minDistance.map(String.init)),
            ("maxDistance", maxDistance.map(String.init)),
            ("minDuration", minDuration.map(String.init)),
            ("maxDuration", maxDuration.map(String.init)),
            ("minElapsedDuration", minElapsedDuration.map(String.init)),
            ("maxElapsedDuration", maxElapsedDuration.map(String.init)),
            ("minElevation", minElevation.map(String.init)),
            ("maxElevation", maxElevation.map(String.init)),
            ("minAvgPower", minAvgPower.map(String.init)),
            ("lowerMaxDepth", lowerMaxDepth.map(String.init)),
            ("upperMaxDepth", upperMaxDepth.map(String.init)),
            ("minBottomTime", minBottomTime.map(String.init)),
            ("maxBottomTime", maxBottomTime.map(String.init)),
        ]
        items += scalars.compactMap { name, value in value.map { QueryItem(name, $0) } }
        return items
    }
}

// MARK: - Endpoints

/// Transport-independent descriptions of every Personal API endpoint.
enum Endpoints {
    static func day(_ value: some DateLike, _ name: String = "day") throws -> String {
        "\(try value.garminDate(argument: name))"
    }

    static func flag(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    static func activityID(_ value: Int) throws -> Int {
        guard value > 0 else {
            throw InvalidArgumentError("activityID must be positive, got \(value)")
        }
        return value
    }

    static func rangePath(_ prefix: String, _ start: GarminDate, _ end: GarminDate) -> String {
        "\(prefix)/\(start)/\(end)"
    }

    static func rangeQuery(_ start: GarminDate, _ end: GarminDate) -> [QueryItem] {
        [QueryItem("startDate", "\(start)"), QueryItem("endDate", "\(end)")]
    }

    // Activities

    static func activity(_ id: Int) throws -> Endpoint<ActivitySummary> {
        Endpoint(
            path: "/activity-service/activity/\(try activityID(id))",
            parse: Parse.required(ActivitySummary.self)
        )
    }

    static func activityWorkouts(_ id: Int) throws -> Endpoint<[ActivityWorkout]> {
        Endpoint(
            path: "/activity-service/activity/\(try activityID(id))/workouts",
            parse: Parse.list(ActivityWorkout.self)
        )
    }

    static func searchActivities(
        start: Int, limit: Int, filters: [QueryItem]
    )
        -> Endpoint<[SummarizedActivity]>
    {
        Endpoint(
            path: "/activitylist-service/activities/search/activities",
            query: [QueryItem("start", "\(start)"), QueryItem("limit", "\(limit)")] + filters,
            parse: Parse.list(SummarizedActivity.self)
        )
    }

    static func downloadActivityZip(_ id: Int) throws -> Endpoint<Data> {
        Endpoint(
            path: "/download-service/files/activity/\(try activityID(id))",
            accept: Endpoint<Data>.zip,
            parse: Parse.archive
        )
    }

    static func downloadActivity(_ id: Int) throws -> Endpoint<ActivityFile> {
        let id = try activityID(id)
        return Endpoint(
            path: "/download-service/files/activity/\(id)", accept: Endpoint<Data>.zip
        ) { response in
            do {
                return try ActivityFile.extract(activityID: id, archive: Parse.archive(response))
            } catch let failure as ZipArchive.Failure {
                throw ResponseValidationError(
                    "Cannot read activity \(id) download: \(failure.message)", response: response)
            }
        }
    }

    // Health and wellness

    static func heartRateZones(generateDefaults: Bool) -> Endpoint<[HeartRateZones]> {
        Endpoint(
            path: "/biometric-service/heartRateZones/v2",
            query: [QueryItem("generateDefaults", flag(generateDefaults))],
            parse: Parse.list(HeartRateZones.self)
        )
    }

    /// The spec documents an array; the server returns a single object.
    static func fitnessAge(
        _ day: some DateLike, fullHistoryScan: Bool
    ) throws
        -> Endpoint<FitnessAge>
    {
        Endpoint(
            path: "/fitnessage-service/fitnessage/v2/\(try self.day(day))",
            query: [QueryItem("fullHistoryScan", flag(fullHistoryScan))],
            parse: Parse.value(FitnessAge.self) { FitnessAge() }
        )
    }

    static func effectiveWeightGoals(
        _ start: GarminDate, _ end: GarminDate
    )
        -> Endpoint<UserGoalsRange>
    {
        Endpoint(
            path: rangePath("/goal-service/goal/user/effective/weightgoal", start, end),
            parse: Parse.value(UserGoalsRange.self) { UserGoalsRange() }
        )
    }

    static func dailyHRV(_ day: some DateLike) throws -> Endpoint<HrvChart?> {
        Endpoint(
            path: "/hrv-service/hrv/\(try self.day(day))", parse: Parse.optional(HrvChart.self))
    }

    static func dailyHRVSummaries(_ start: GarminDate, _ end: GarminDate) -> Endpoint<[HrvSummary]>
    {
        let parse = Parse.optional(HrvDailySummary.self)
        return Endpoint(path: rangePath("/hrv-service/hrv/daily", start, end)) { response in
            try parse(response)?.hrvSummaries ?? []
        }
    }

    static func dailyFoodLogs(
        _ day: some DateLike, includeGoals: Bool, includeNutrition: Bool, includeMedia: Bool,
        mealID: Int?
    ) throws -> Endpoint<DailyNutritionSummary> {
        var query = [
            QueryItem("includeGoals", flag(includeGoals)),
            QueryItem("includeNutrition", flag(includeNutrition)),
            QueryItem("includeMedia", flag(includeMedia)),
        ]
        if let mealID {
            query.append(QueryItem("mealId", "\(mealID)"))
        }
        return Endpoint(
            path: "/nutrition-service/food/logs/\(try self.day(day))", query: query,
            parse: Parse.value(DailyNutritionSummary.self) { DailyNutritionSummary() }
        )
    }

    static func menstrualCycleSummary(
        _ day: some DateLike
    ) throws
        -> Endpoint<MenstrualCycleSummary?>
    {
        Endpoint(
            path: "/periodichealth-service/menstrualcycle/summary/\(try self.day(day))",
            parse: Parse.optional(MenstrualCycleSummary.self)
        )
    }

    static func menstrualCycleDayView(
        _ day: some DateLike, today: (any DateLike)?, reducedResponse: Bool,
        skipBabyMovement: Bool, includeAnalysis: Bool
    ) throws -> Endpoint<DetailedMenstrualCycleDay?> {
        var query: [QueryItem] = []
        if let today {
            query.append(QueryItem("todayDate", "\(try today.garminDate(argument: "today"))"))
        }
        query += [
            QueryItem("reducedResponse", flag(reducedResponse)),
            QueryItem("skipbm", flag(skipBabyMovement)),
            QueryItem("includeAnalysis", flag(includeAnalysis)),
        ]
        return Endpoint(
            path: "/periodichealth-service/menstrualcycle/dayview/\(try self.day(day))",
            query: query, parse: Parse.optional(DetailedMenstrualCycleDay.self)
        )
    }

    static func dailySleep(_ day: some DateLike) throws -> Endpoint<DailySleep> {
        Endpoint(
            path: "/sleep-service/sleep/dailySleep", query: [QueryItem("date", try self.day(day))],
            parse: Parse.value(DailySleep.self) { DailySleep() }
        )
    }

    static func dailySleepSummaries(
        _ start: GarminDate, _ end: GarminDate
    )
        -> Endpoint<[DailySleep]>
    {
        Endpoint(
            path: "/sleep-service/sleep/dailySleepSummariesByDate", query: rangeQuery(start, end),
            parse: Parse.list(DailySleep.self)
        )
    }

    static func userProfileSettings() -> Endpoint<UserSettings> {
        Endpoint(
            path: "/userprofile-service/userprofile/settings",
            parse: Parse.value(UserSettings.self) { UserSettings() }
        )
    }

    static func dailyHydration(
        _ start: GarminDate, _ end: GarminDate
    )
        -> Endpoint<[UserDailyHydration]>
    {
        Endpoint(
            path: rangePath("/usersummary-service/stats/hydration/daily", start, end),
            parse: Parse.list(UserDailyHydration.self)
        )
    }

    static func dailySteps(_ start: GarminDate, _ end: GarminDate) -> Endpoint<[StepsDailyStat]> {
        Endpoint(
            path: rangePath("/usersummary-service/stats/steps/daily", start, end),
            parse: Parse.list(StepsDailyStat.self)
        )
    }

    static func dailyStress(
        _ start: GarminDate, _ end: GarminDate
    )
        -> Endpoint<[MultiValueWellnessChartItem]>
    {
        Endpoint(
            path: rangePath("/usersummary-service/stats/stress/daily", start, end),
            parse: Parse.list(MultiValueWellnessChartItem.self)
        )
    }

    static func dailySummary(_ day: some DateLike) throws -> Endpoint<UserDailySummary> {
        Endpoint(
            path: "/usersummary-service/usersummary/daily",
            query: [QueryItem("calendarDate", try self.day(day))],
            parse: Parse.value(UserDailySummary.self) { UserDailySummary() }
        )
    }

    static func dailySummaries(
        _ start: GarminDate, _ end: GarminDate
    )
        -> Endpoint<[UserDailySummaryV2]>
    {
        let parse = Parse.value(UserDailySummaryV2List.self) { UserDailySummaryV2List() }
        return Endpoint(
            path: "/usersummary-service/v2/dailysummaries", query: rangeQuery(start, end)
        ) { response in try parse(response).data ?? [] }
    }

    static func weightEntries(_ start: GarminDate, _ end: GarminDate) -> Endpoint<[DateWeight]> {
        Endpoint(
            path: rangePath("/weight-service/weight/all", start, end),
            parse: Parse.list(DateWeight.self)
        )
    }

    static func weightRange(
        _ start: GarminDate, _ end: GarminDate, includeAll: Bool
    )
        -> Endpoint<WeightRange>
    {
        Endpoint(
            path: rangePath("/weight-service/weight/range", start, end),
            query: [QueryItem("includeAll", flag(includeAll))],
            parse: Parse.value(WeightRange.self) { WeightRange() }
        )
    }

    static func dailyBodyBattery(
        _ start: GarminDate, _ end: GarminDate, chunks: Int?
    ) throws
        -> Endpoint<[BodyBatteryDailyReport]>
    {
        var query = rangeQuery(start, end)
        if let chunks {
            guard chunks >= 1 else { throw InvalidArgumentError("chunks must be at least 1") }
            query.append(QueryItem("chunks", "\(chunks)"))
        }
        return Endpoint(
            path: "/wellness-service/wellness/bodyBattery/reports/daily", query: query,
            parse: Parse.list(BodyBatteryDailyReport.self)
        )
    }

    static func dailySpO2(_ day: some DateLike) throws -> Endpoint<DailySpO2AndAcclimation> {
        Endpoint(
            path: "/wellness-service/wellness/daily/spo2acclimation/\(try self.day(day))",
            parse: Parse.value(DailySpO2AndAcclimation.self) { DailySpO2AndAcclimation() }
        )
    }

    static func dailyHeartRate(_ day: some DateLike) throws -> Endpoint<DailyHeartRate> {
        Endpoint(
            path: "/wellness-service/wellness/dailyHeartRate",
            query: [QueryItem("date", try self.day(day))],
            parse: Parse.value(DailyHeartRate.self) { DailyHeartRate() }
        )
    }

    static func wellnessActivitySummaries(
        _ start: GarminDate, _ end: GarminDate
    )
        -> Endpoint<[WellnessActivitySummary]>
    {
        Endpoint(
            path: rangePath("/wellnessactivity-service/activity/summary/range", start, end),
            parse: Parse.list(WellnessActivitySummary.self)
        )
    }

    /// Any GET endpoint on the API host, returning decoded JSON (or `nil` if empty).
    static func json(_ path: String, query: [QueryItem]) throws -> Endpoint<JSONValue?> {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("://") else {
            throw InvalidArgumentError(
                "path must be an absolute path on the API host, such as '/sleep-service/...'")
        }
        return Endpoint(path: path, query: query, parse: Parse.optional(JSONValue.self))
    }
}
