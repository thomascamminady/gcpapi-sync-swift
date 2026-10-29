import ArgumentParser
import Foundation
import GCPAPISync

/// Whether `url` is a regular file (not a directory).
private func isFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
}

/// Outcome of `gcpapi sync`.
struct SyncReport: Encodable {
    let directory: String
    var downloaded: [String] = []
    var skipped = 0
    var unavailable: [Int] = []
}

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Download every activity's original file (usually FIT) not yet in OUTPUT.",
        discussion: """
            Files are named like Garmin names them (<activityId>_ACTIVITY.fit); activities whose \
            file already exists are skipped, so running it again only fetches new ones.
            """
    )

    @Argument(help: "Target directory (created if needed).")
    var output = "."
    @Option(help: "Only activities starting on or after this date.")
    var since: String?
    @Option(help: "Only activities starting on or before this date.")
    var until: String?
    @Option(help: "Stop after this many downloads.")
    var limit: Int?
    @Flag(help: "Also save each activity's summary as <activityId>.json.")
    var metadata = false

    @OptionGroup var filters: FilterOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let context = CLIContext.current
        let directory = context.environment.url(for: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let have = Set(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { isFile(directory.appendingPathComponent($0)) }
                .map { String($0.split(separator: "_", maxSplits: 1).first ?? "") })
        var report = SyncReport(directory: directory.path)
        let client = try global.client()
        for try await activity in try client.iterActivities(
            filters: filters.filters(since: since, until: until))
        {
            if let limit, report.downloaded.count >= limit {
                break
            }
            let id = activity.activityId
            if have.contains("\(id)") {
                report.skipped += 1
                continue
            }
            let saved: URL
            do {
                saved = try await client.downloadActivity(id).save(to: directory)
            } catch is NotFoundError {
                report.unavailable.append(id)
                continue
            } catch is FileExistsError {
                report.skipped += 1
                continue
            }
            if metadata {
                try Data((try JSONText.encode(activity, indent: 2) + "\n").utf8)
                    .write(to: directory.appendingPathComponent("\(id).json"))
            }
            report.downloaded.append(saved.lastPathComponent)
            await context.console.note("downloaded \(saved.lastPathComponent)")
        }
        try await global.printJSON(report)
    }
}

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Save daily health data for a date range as JSON files in OUTPUT.",
        discussion: """
            Writes daily_summaries, sleep, hrv, stress, steps, hydration, body_battery and \
            wellness_activities (one .json array each).
            """
    )

    @Argument(help: "First day (YYYY-MM-DD).")
    var start: String
    @Argument(help: "Last day (YYYY-MM-DD).")
    var end: String
    @Argument(help: "Target directory (created if needed).")
    var output = "."

    @OptionGroup var global: GlobalOptions

    private struct Summary: Encodable {
        let directory: String
        let records: [String: Int]
    }

    func run() async throws {
        let context = CLIContext.current
        let directory = context.environment.url(for: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = try global.client()
        var records: [String: Int] = [:]
        func save(_ name: String, _ items: [some Encodable]) async throws {
            try Data((try JSONText.encode(items, indent: 2) + "\n").utf8)
                .write(to: directory.appendingPathComponent("\(name).json"))
            records[name] = items.count
            await context.console.note("\(name): \(items.count) records")
        }
        try await save(
            "daily_summaries", try await client.getDailySummaries(start: start, end: end))
        try await save("sleep", try await client.getDailySleepSummaries(start: start, end: end))
        try await save("hrv", try await client.getDailyHRVSummaries(start: start, end: end))
        try await save("stress", try await client.getDailyStress(start: start, end: end))
        try await save("steps", try await client.getDailySteps(start: start, end: end))
        try await save("hydration", try await client.getDailyHydration(start: start, end: end))
        try await save("body_battery", try await client.getDailyBodyBattery(start: start, end: end))
        try await save(
            "wellness_activities",
            try await client.getWellnessActivitySummaries(start: start, end: end))
        try await global.printJSON(Summary(directory: directory.path, records: records))
    }
}

struct DownloadActivity: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "download-activity", "Save one activity's original file (usually FIT) and print its path.")

    @Argument(help: "The activity ID.")
    var activityID: Int
    @Argument(help: "A directory or file path.")
    var output = "."
    @Flag(help: "Replace an existing file.")
    var overwrite = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let target = CLIContext.current.environment.url(for: output)
        let file = try await global.client().downloadActivity(activityID)
        let saved: URL
        do {
            saved = try file.save(to: target, overwrite: overwrite)
        } catch let error as FileExistsError {
            throw CommandError("\(error.url.path) already exists; pass --overwrite to replace it")
        }
        try await global.printJSON(["path": saved.path])
    }
}

struct DownloadActivityZip: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "download-activity-zip", "Save the zip archive Garmin serves for an activity.")

    @Argument(help: "The activity ID.")
    var activityID: Int
    @Argument(help: "A directory or file path.")
    var output = "."
    @Flag(help: "Replace an existing file.")
    var overwrite = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        var target = CLIContext.current.environment.url(for: output)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            target.appendPathComponent("\(activityID).zip")
        }
        if FileManager.default.fileExists(atPath: target.path), !overwrite {
            throw CommandError("\(target.path) already exists; pass --overwrite to replace it")
        }
        try await global.client().downloadActivityZip(activityID).write(to: target)
        try await global.printJSON(["path": target.path])
    }
}

struct IterActivities: AsyncParsableCommand {
    static let configuration = makeConfiguration(
        "iter-activities", "Print every matching activity as one JSON object per line.")

    @Option(name: long("page-size"), help: "Activities per request (1 to 45).")
    var pageSize = 20

    @OptionGroup var filters: FilterOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        for try await activity in try global.client().iterActivities(
            pageSize: pageSize, filters: filters.filters())
        {
            await CLIContext.current.console.write(try JSONText.encode(activity, indent: 0))
        }
    }
}
