public import Foundation

// Garmin ships intraday data as rows of numbers ([[1792533600000, 42], ...]) plus a
// separate list describing what each column means. The accessors below turn those rows
// into small value types, locating columns through the descriptors rather than assuming
// their order.

/// One heart rate reading.
public struct HeartRateSample: Hashable, Sendable {
    /// When the reading was taken.
    public let timestamp: Date
    /// Beats per minute; `nil` when the device recorded no value.
    public let heartRate: Int?
}

/// One Body Battery reading.
public struct BodyBatterySample: Hashable, Sendable {
    /// When the reading was taken.
    public let timestamp: Date
    /// Body Battery level (0-100).
    public let level: Int?
}

/// One pulse-ox reading.
public struct SpO2Sample: Hashable, Sendable {
    /// When the reading was taken.
    public let timestamp: Date
    /// Blood oxygen saturation in percent.
    public let spo2: Double?
    /// Monitoring environment level (altitude-related), if reported.
    public let monitoringEnvironmentLevel: Double?
}

/// One monitoring-environment (altitude acclimation) reading.
public struct MonitoringEnvironmentSample: Hashable, Sendable {
    /// When the reading was taken.
    public let timestamp: Date
    /// Monitoring environment level.
    public let level: Double?
}

/// Column positions by descriptor key.
private struct Columns {
    let byKey: [(key: String, index: Int)]

    init(_ descriptors: [(String?, Int?)]) {
        byKey = descriptors.compactMap { key, index in
            guard let key, let index else { return nil }
            return (key, index)
        }
    }

    func find(exact: String, default fallback: Int?) -> Int? {
        byKey.first { $0.key == exact }?.index ?? fallback
    }

    func find(containing fragment: String, default fallback: Int?) -> Int? {
        byKey.first { $0.key.lowercased().contains(fragment) }?.index ?? fallback
    }
}

private func cell(_ row: SeriesRow, _ index: Int?) -> Double? {
    guard let index, index >= 0, index < row.count else { return nil }
    return row[index]
}

private func timestamp(_ row: SeriesRow, _ index: Int?) -> Date? {
    cell(row, index).map { Date(timeIntervalSince1970: $0 / 1000) }
}

private func rounded(_ value: Double?) -> Int? {
    value.flatMap { Int(exactly: $0.rounded(.toNearestOrEven)) }
}

private func heartRateSamples(
    _ rows: [SeriesRow]?, _ descriptors: [HeartRateValueDescriptor]?
)
    -> [HeartRateSample]
{
    let columns = Columns((descriptors ?? []).map { ($0.key, $0.index) })
    let time = columns.find(exact: "timestamp", default: 0)
    let value = columns.find(exact: "heartrate", default: 1)
    return (rows ?? []).compactMap { row in
        timestamp(row, time).map {
            HeartRateSample(timestamp: $0, heartRate: rounded(cell(row, value)))
        }
    }
}

private func spo2Samples(_ rows: [SeriesRow]?, _ columns: Columns) -> [SpO2Sample] {
    let time = columns.find(exact: "timestamp", default: 0)
    let spo2 = columns.find(containing: "spo2", default: 1)
    let environment = columns.find(containing: "monitoringenvironment", default: nil)
    return (rows ?? []).compactMap { row in
        timestamp(row, time).map {
            SpO2Sample(
                timestamp: $0, spo2: cell(row, spo2),
                monitoringEnvironmentLevel: cell(row, environment)
            )
        }
    }
}

extension DailyHeartRate {
    /// The day's heart rate readings in chronological order.
    public func heartRateSamples() -> [HeartRateSample] {
        GCPAPISync.heartRateSamples(heartRateValues, heartRateValueDescriptors)
    }

    /// Readings flagged as abnormally high or low.
    public func abnormalHeartRateSamples() -> [HeartRateSample] {
        GCPAPISync.heartRateSamples(abnormalHRValuesArray, heartRateValueDescriptors)
    }
}

extension BodyBatteryDailyReport {
    /// The day's Body Battery readings in chronological order.
    public func bodyBatterySamples() -> [BodyBatterySample] {
        let columns = Columns(
            (bodyBatteryValueDescriptorList ?? []).map {
                ($0.bodyBatteryValueDescriptorKey, $0.bodyBatteryValueDescriptorIndex)
            }
        )
        let time = columns.find(exact: "timestamp", default: 0)
        let level = columns.find(exact: "bodyBatteryLevel", default: 1)
        return (bodyBatteryValuesArray ?? []).compactMap { row in
            timestamp(row, time).map {
                BodyBatterySample(timestamp: $0, level: rounded(cell(row, level)))
            }
        }
    }
}

extension DailySpO2AndAcclimation {
    /// Hourly-averaged SpO2 readings in chronological order.
    public func spo2HourlySamples() -> [SpO2Sample] {
        spo2Samples(
            spO2HourlyAverages,
            Columns(
                (spO2HourlyAveragesDescriptorList ?? []).map {
                    ($0.spo2ValueDescKey, $0.spo2ValueDescIndex)
                }
            )
        )
    }

    /// Individual (spot-check) SpO2 readings in chronological order.
    public func spo2SingleSamples() -> [SpO2Sample] {
        spo2Samples(
            spO2SingleValues,
            Columns(
                (spO2SingleValuesDescriptorList ?? []).map {
                    ($0.spo2ValueDescriptorKey, $0.spo2ValueDescriptorIndex)
                }
            )
        )
    }

    /// Monitoring-environment (acclimation) readings in chronological order.
    public func monitoringEnvironmentSamples() -> [MonitoringEnvironmentSample] {
        let columns = Columns(
            (monitoringEnvironmentValuesDescriptorList ?? []).map {
                ($0.monEnvValueDescKey, $0.monEnvValueDescIndex)
            }
        )
        let time = columns.find(exact: "timestamp", default: 0)
        let level = columns.find(containing: "monitoringenvironment", default: 1)
        return (monitoringEnvironmentValues ?? []).compactMap { row in
            timestamp(row, time).map {
                MonitoringEnvironmentSample(timestamp: $0, level: cell(row, level))
            }
        }
    }
}
