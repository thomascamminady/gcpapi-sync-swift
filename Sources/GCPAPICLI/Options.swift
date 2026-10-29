public import ArgumentParser
import Foundation
import GCPAPISync

/// A long option name, plus its snake_case spelling (`--start-date`, `--start_date`) so
/// commands written for the Python version of this tool keep working.
func long(_ name: String) -> NameSpecification {
    let snake = name.replacingOccurrences(of: "-", with: "_")
    return snake == name ? [.customLong(name)] : [.customLong(name), .customLong(snake)]
}

/// Options every command accepts.
public struct GlobalOptions: ParsableArguments {
    /// Personal API key. Prefer `gcpapi setup`, a key file or the environment variable:
    /// command lines are visible to other users.
    @Option(name: long("api-key"), help: "Personal API key (prefer `gcpapi setup`).")
    var apiKey: String?

    @Option(name: long("key-file"), help: "File containing the API key.")
    var keyFile: String?

    @Option(name: long("base-url"), help: "Alternative API host.")
    var baseURL: String?

    @Flag(name: long("no-cache"), help: "Neither read nor write the on-disk token cache.")
    var noCache = false

    @Option(help: "JSON indentation for JSON output; 0 prints a single line.")
    var indent = 2

    /// The default options.
    public init() {}

    var tokenCache: any TokenCache {
        noCache
            ? MemoryTokenCache()
            : FileTokenCache(
                environment: CLIContext.current.environment, logger: CLIContext.current.logger)
    }

    func client(apiKey override: String? = nil) throws -> GarminClient {
        let context = CLIContext.current
        return try GarminClient(
            apiKey: override ?? apiKey, keyFile: override == nil ? keyFile : nil,
            tokenCache: tokenCache, baseURL: baseURL, retry: context.retry,
            transport: context.transport, environment: context.environment, logger: context.logger
        )
    }

    /// Print `value` as JSON (Garmin's names, `nil` fields omitted, keys sorted).
    func printJSON(_ value: some Encodable) async throws {
        await CLIContext.current.console.write(try JSONText.encode(value, indent: indent))
    }
}

/// JSON rendering for command output.
enum JSONText {
    static func encode(_ value: some Encodable, indent: Int) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if indent > 0 {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        let text = String(decoding: try encoder.encode(value), as: UTF8.self)
        guard indent > 0, indent != 2 else { return text }
        // Foundation indents by two spaces; scale to the requested width.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { (line: Substring) -> String in
            let spaces = line.prefix { $0 == " " }.count
            return String(repeating: " ", count: spaces / 2 * indent) + line.dropFirst(spaces)
        }.joined(separator: "\n")
    }
}

/// Activity search filters as options.
struct FilterOptions: ParsableArguments {
    @Option(name: long("start-date"), help: "Earliest local start date (YYYY-MM-DD).")
    var startDate: String?
    @Option(name: long("end-date"), help: "Latest local start date (YYYY-MM-DD).")
    var endDate: String?
    @Option(name: long("activity-type"), help: "Parent activity type key, such as running.")
    var activityType: String?
    @Option(name: long("activity-subtype"), help: "Activity subtype key, such as trail_running.")
    var activitySubtype: String?
    @Option(name: long("excluded-activity-subtype"), help: "Subtype key to exclude (repeatable).")
    var excludedActivitySubtypes: [String] = []
    @Option(name: long("event-type"), help: "Event type key, such as race.")
    var eventType: String?
    @Option(help: "Text to search for in names and descriptions.")
    var search: String?
    @Option(help: "Only favorites (true) or only non-favorites (false).")
    var favorite: Bool?
    @Option(name: long("sort-by"), help: "Field to sort by, such as distance.")
    var sortBy: String?
    @Option(name: long("sort-order"), help: "asc or desc.")
    var sortOrder: String?
    @Option(name: long("exclude-children"), help: "Exclude child activities (true/false).")
    var excludeChildren: Bool?
    @Option(name: long("min-distance"), help: "Minimum distance in meters.")
    var minDistance: Int?
    @Option(name: long("max-distance"), help: "Maximum distance in meters.")
    var maxDistance: Int?
    @Option(name: long("min-duration"), help: "Minimum timer duration in seconds.")
    var minDuration: Int?
    @Option(name: long("max-duration"), help: "Maximum timer duration in seconds.")
    var maxDuration: Int?
    @Option(name: long("min-elapsed-duration"), help: "Minimum elapsed duration in seconds.")
    var minElapsedDuration: Int?
    @Option(name: long("max-elapsed-duration"), help: "Maximum elapsed duration in seconds.")
    var maxElapsedDuration: Int?
    @Option(name: long("min-elevation"), help: "Minimum elevation gain in meters.")
    var minElevation: Int?
    @Option(name: long("max-elevation"), help: "Maximum elevation gain in meters.")
    var maxElevation: Int?
    @Option(name: long("min-avg-power"), help: "Minimum average power in watts.")
    var minAvgPower: Int?
    @Option(name: long("bounding-box"), help: "north,east,south,west in decimal degrees.")
    var boundingBox: String?
    @Option(name: long("lower-max-depth"), help: "Dives: minimum maximum depth in cm.")
    var lowerMaxDepth: Int?
    @Option(name: long("upper-max-depth"), help: "Dives: maximum maximum depth in cm.")
    var upperMaxDepth: Int?
    @Option(name: long("deco-dive"), help: "Dives: only decompression dives (true/false).")
    var decoDive: Bool?
    @Option(name: long("min-bottom-time"), help: "Dives: minimum bottom time in seconds.")
    var minBottomTime: Int?
    @Option(name: long("max-bottom-time"), help: "Dives: maximum bottom time in seconds.")
    var maxBottomTime: Int?
    @Option(name: long("required-field"), help: "Field that must be non-null (repeatable).")
    var requiredFields: [String] = []

    func validate() throws {
        if let sortOrder, SortOrder(rawValue: sortOrder) == nil {
            throw ValidationError("--sort-order must be asc or desc")
        }
        if boundingBox != nil, box == nil {
            throw ValidationError("--bounding-box must be four numbers: north,east,south,west")
        }
    }

    private var box: BoundingBox? {
        let parts = (boundingBox ?? "").split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 4 else { return nil }
        return BoundingBox(north: parts[0], east: parts[1], south: parts[2], west: parts[3])
    }

    func filters(since: String? = nil, until: String? = nil) -> ActivityFilters {
        ActivityFilters(
            startDate: since ?? startDate, endDate: until ?? endDate, activityType: activityType,
            activitySubtype: activitySubtype,
            excludedActivitySubtypes: excludedActivitySubtypes.isEmpty
                ? nil : excludedActivitySubtypes,
            eventType: eventType, search: search, favorite: favorite, sortBy: sortBy,
            sortOrder: sortOrder.flatMap(SortOrder.init(rawValue:)),
            excludeChildren: excludeChildren,
            minDistance: minDistance, maxDistance: maxDistance, minDuration: minDuration,
            maxDuration: maxDuration, minElapsedDuration: minElapsedDuration,
            maxElapsedDuration: maxElapsedDuration, minElevation: minElevation,
            maxElevation: maxElevation, minAvgPower: minAvgPower, boundingBox: box,
            lowerMaxDepth: lowerMaxDepth, upperMaxDepth: upperMaxDepth, decoDive: decoDive,
            minBottomTime: minBottomTime, maxBottomTime: maxBottomTime,
            requiredFields: requiredFields.isEmpty ? nil : requiredFields
        )
    }
}
