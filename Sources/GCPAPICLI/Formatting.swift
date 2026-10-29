import Foundation
import GCPAPISync

/// Text formatting shared by the human-readable commands.
enum Format {
    /// `H:MM:SS`, or `M:SS` under an hour; `-` if unknown.
    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "-" }
        let total = Int(seconds.rounded(.toNearestOrEven))
        let (hours, rest) = total.quotientAndRemainder(dividingBy: 3600)
        let (minutes, secs) = rest.quotientAndRemainder(dividingBy: 60)
        return hours > 0
            ? "\(hours):\(pad(minutes)):\(pad(secs))" : "\(minutes):\(pad(secs))"
    }

    /// `12.35 km`; `-` if unknown or zero.
    static func kilometers(_ meters: Double?) -> String {
        guard let meters, meters != 0 else { return "-" }
        return String(format: "%.2f km", meters / 1000)
    }

    /// A rounded number with thousands separators, such as `12,345`; `-` if unknown.
    static func number(_ value: Double?, _ unit: String = "") -> String {
        guard let value else { return "-" }
        let rounded = Int(value.rounded(.toNearestOrEven))
        var digits = String(abs(rounded))
        var groups: [Substring] = []
        while digits.count > 3 {
            groups.insert(digits.suffix(3), at: 0)
            digits.removeLast(3)
        }
        groups.insert(Substring(digits), at: 0)
        return (rounded < 0 ? "-" : "") + groups.joined(separator: ",") + unit
    }

    static func number(_ value: Int?, _ unit: String = "") -> String {
        number(value.map(Double.init), unit)
    }

    static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// `YYYY-MM-DD HH:MM` of a wall-clock reading.
    static func minute(_ value: LocalDateTime) -> String {
        "\(value.date) \(pad(value.time.hour)):\(pad(value.time.minute))"
    }

    /// `YYYY-MM-DD HH:MM` in UTC.
    static func utcMinute(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let day = GarminDate(date, in: .gmt)
        let inDay = ((seconds % 86_400) + 86_400) % 86_400
        return "\(day) \(pad(inDay / 3600)):\(pad(inDay / 60 % 60))"
    }

    /// `YYYY-MM-DDTHH:MM:SSZ`.
    static func iso(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let inDay = ((seconds % 86_400) + 86_400) % 86_400
        let day = GarminDate(date, in: .gmt)
        return "\(day)T\(pad(inDay / 3600)):\(pad(inDay / 60 % 60)):\(pad(inDay % 60))Z"
    }

    /// The weekday's English name.
    static func weekday(_ day: GarminDate) -> String {
        let names = ["Thursday", "Friday", "Saturday", "Sunday", "Monday", "Tuesday", "Wednesday"]
        let offset = try? GarminDate(year: 1970, month: 1, day: 1).days(to: day)
        return names[((offset ?? 0) % 7 + 7) % 7]
    }

    static func activityType(_ activity: SummarizedActivity) -> String {
        (activity.activityType?.typeKey ?? "activity").replacingOccurrences(of: "_", with: " ")
    }
}
