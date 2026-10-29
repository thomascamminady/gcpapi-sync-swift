import ArgumentParser
import Foundation
import GCPAPISync

/// Everything `gcpapi today` shows, for `--as-json`.
struct TodayReport: Encodable {
    let day: GarminDate
    let summary: UserDailySummary
    let sleep: DailySleep
    let hrv: HrvChart?
    let activities: [SummarizedActivity]

    var lines: [String] {
        var lines = ["\(Format.weekday(day)), \(day)"]
        func add(_ label: String, _ value: String) {
            lines.append(
                "  " + label.padding(toLength: 13, withPad: " ", startingAt: 0) + " \(value)")
        }
        add(
            "Steps",
            "\(Format.number(summary.totalSteps)) of \(Format.number(summary.dailyStepGoal))")
        add("Distance", Format.kilometers(summary.totalDistanceMeters.map(Double.init)))
        add(
            "Resting HR",
            "\(Format.number(summary.restingHeartRate, " bpm")) "
                + "(7-day \(Format.number(summary.lastSevenDaysAvgRestingHeartRate)))")
        add(
            "Stress",
            "avg \(Format.number(summary.averageStressLevel)), "
                + "max \(Format.number(summary.maxStressLevel))")
        add(
            "Body Battery",
            "\(Format.number(summary.bodyBatteryLowestValue)) to "
                + "\(Format.number(summary.bodyBatteryHighestValue)), "
                + "now \(Format.number(summary.bodyBatteryMostRecentValue))")
        var score = ""
        if let overall = sleep.sleepScores?.overall {
            score = ", score \(Format.number(overall.value)) \(overall.qualifierKey ?? "")"
            while score.hasSuffix(" ") {
                score.removeLast()
            }
        }
        add("Sleep", "\(Format.duration(sleep.sleepTimeSeconds.map(Double.init))) h\(score)")
        if let summary = hrv?.hrvSummary {
            add(
                "HRV",
                "\(Format.number(summary.lastNightAvg, " ms")) last night, weekly "
                    + "\(Format.number(summary.weeklyAvg, " ms")) (\(summary.status ?? "-"))")
        }
        var label = "Activities"
        for activity in activities {
            let clock = activity.startTimeLocal.map {
                "\(Format.pad($0.time.hour)):\(Format.pad($0.time.minute))  "
            }
            add(
                label,
                (clock ?? "") + "\(Format.activityType(activity))  "
                    + "\(Format.kilometers(activity.distance))  "
                    + Format.duration(activity.duration)
            )
            label = ""
        }
        if activities.isEmpty {
            add(label, "none")
        }
        return lines
    }
}

struct Today: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "today",
        abstract:
            "Summarize a day: steps, heart rate, stress, Body Battery, sleep, HRV, activities."
    )

    @Argument(help: "The day to show (YYYY-MM-DD); defaults to today.")
    var day: String?

    @Flag(name: long("as-json"), help: "Print the underlying data as JSON instead.")
    var asJSON = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let context = CLIContext.current
        let when =
            try day?.garminDate(argument: "day")
            ?? GarminDate(context.now(), in: context.timeZone)
        let client = try global.client()
        let report = TodayReport(
            day: when, summary: try await client.getDailySummary(when),
            sleep: try await client.getDailySleep(when), hrv: try await client.getDailyHRV(when),
            activities: try await client.searchActivities(
                limit: 20, filters: ActivityFilters(startDate: when, endDate: when))
        )
        if asJSON {
            try await global.printJSON(report)
            return
        }
        for line in report.lines {
            await context.console.write(line)
        }
    }
}

struct Activities: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activities", abstract: "List recent activities as a table.")

    @Option(help: "How many activities to show.")
    var limit = 10

    @OptionGroup var filters: FilterOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        var rows = [["Start", "Type", "Name", "Distance", "Duration", "Avg HR", "ID"]]
        for activity in try await global.client().searchActivities(
            limit: limit, filters: filters.filters())
        {
            rows.append([
                activity.startTimeLocal.map(Format.minute) ?? "-",
                Format.activityType(activity),
                String((activity.activityName ?? "").prefix(32)),
                Format.kilometers(activity.distance),
                Format.duration(activity.duration),
                Format.number(activity.averageHR),
                "\(activity.activityId)",
            ])
        }
        let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
        for row in rows {
            var line = zip(row, widths).map {
                $0.padding(toLength: $1, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            while line.hasSuffix(" ") {
                line.removeLast()
            }
            await CLIContext.current.console.write(line)
        }
    }
}
