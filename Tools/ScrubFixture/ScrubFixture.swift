import ArgumentParser
import Foundation
import ToolSupport

/// Turn a real API response into an anonymous test fixture.
///
/// The structure (keys, nesting, types, nulls) is kept exactly; every value that could
/// identify a person is replaced deterministically:
///
/// * numbers get new values of the same type and magnitude (single-digit integers, such as
///   Garmin's negative "no data" sentinels, and column indexes are kept); epoch-millisecond
///   timestamps become increasing synthetic timestamps,
/// * dates, times and timestamps become fixed synthetic values in the same format,
/// * strings are replaced unless they are enum-like constants (`EXCELLENT`) or the value of
///   an allow-listed key such as `typeKey`,
/// * lists are truncated.
///
///     swift run scrub-fixture response.json Tests/GCPAPISyncTests/Fixtures/sleep.json
///
/// Always review the output before committing it.
@main
struct ScrubFixture: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scrub-fixture",
        abstract: "Anonymize a real API response for use as a fixture.")

    @Argument(help: "A raw API response.")
    var source: String
    @Argument(help: "Where to write the fixture.")
    var target: String
    @Option(help: "Keep at most this many elements of every list.")
    var maxItems = 3

    func run() throws {
        var scrubber = Scrubber(maxItems: maxItems)
        let cleaned = scrubber.value(
            try JSONParser.parse(String(contentsOfFile: source, encoding: .utf8)), key: "",
            path: "$")
        try (JSONWriter.write(cleaned) + "\n").write(
            toFile: target, atomically: true, encoding: .utf8)
        let kept = strings(cleaned).subtracting(["redacted", "https://example.invalid/redacted"])
        print("wrote \(target); strings kept verbatim (review them): \(kept.sorted())")
    }

    private func strings(_ value: JSON) -> Set<String> {
        switch value {
        case .object(let members): members.reduce(into: []) { $0.formUnion(strings($1.value)) }
        case .array(let elements): elements.reduce(into: []) { $0.formUnion(strings($1)) }
        case .string(let text) where !Scrubber.looksSynthetic(text): [text]
        default: []
        }
    }
}

struct Scrubber {
    static let syntheticEpochMilliseconds = 1_768_464_000_000  // 2026-01-15T08:00:00Z
    /// Keys whose string values are vocabulary, not personal data.
    static let safeKeys: Set<String> = [
        "typeKey", "key", "sourceType", "qualifierKey", "status", "bodyBatteryValueDescriptorKey",
        "spo2ValueDescKey", "spo2ValueDescriptorKey", "monEnvValueDescKey", "sport",
        "trainingMethod", "measurementSystem", "unitKey", "privacy", "typeKeyName",
        "lactateThresholdHeartRateSource",
    ]

    let maxItems: Int
    var timestampCounter = 0

    init(maxItems: Int) {
        self.maxItems = maxItems
    }

    static func looksSynthetic(_ text: String) -> Bool {
        text.firstMatch(of: #/^\d{4}-\d{2}-\d{2}|^\d{2}:\d{2}|^0{8}-/#) != nil
    }

    mutating func value(_ value: JSON, key: String, path: String) -> JSON {
        switch value {
        case .object(let members):
            return .object(
                members.map {
                    JSON.Member(
                        key: $0.key,
                        value: self.value($0.value, key: $0.key, path: "\(path).\($0.key)"))
                })
        case .array(let elements):
            return .array(
                elements.prefix(maxItems).map { self.value($0, key: key, path: "\(path)[]") })
        case .number(let text):
            if let integer = Int(text) {
                // Column indexes are structure, not data.
                return key.lowercased().hasSuffix("index")
                    ? value : .number("\(self.integer(integer, path))")
            }
            return .number(Self.number(Double(text) ?? 0, path))
        case .string(let text):
            return .string(Self.string(text, key: key))
        case .bool, .null:
            return value
        }
    }

    mutating func integer(_ value: Int, _ path: String) -> Int {
        if (-9...9).contains(value) {
            return value
        }
        if value > 1_000_000_000_000 {
            timestampCounter += 1
            return Self.syntheticEpochMilliseconds + timestampCounter * 60_000
        }
        let digits = String(abs(value)).count
        let low = Int(pow(10, Double(digits - 1)))
        let high = Int(pow(10, Double(digits)))
        return low + Int(Self.hash(path, "\(value)") % UInt64(high - low))
    }

    static func number(_ value: Double, _ path: String) -> String {
        guard value != 0 else { return "0.0" }
        let scale = max(abs(value), 1)
        let fraction = Double(hash(path, "\(value)") % 1000) / 1000
        let scrubbed = ((0.5 + fraction) * scale * (value > 0 ? 1 : -1) * 10).rounded() / 10
        return "\(scrubbed)"
    }

    static func string(_ value: String, key: String) -> String {
        let dateTime =
            #/^\d{4}-\d{2}-\d{2}([T ])\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/#
        if let match = value.firstMatch(of: dateTime) {
            return "2026-01-15\(match.1)08:00:00\(match.3 ?? "")\(match.4 ?? "")"
        }
        if value.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil {
            return "2026-01-15"
        }
        if value.wholeMatch(of: #/\d{2}:\d{2}(:\d{2})?/#) != nil {
            return String("08:00:00".prefix(value.count))
        }
        if value.wholeMatch(
            of: #/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/#)
            != nil
        {
            return "00000000-0000-4000-8000-000000000000"
        }
        if value.wholeMatch(of: #/[A-Z][A-Z0-9_]*/#) != nil || safeKeys.contains(key) {
            return value
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return "https://example.invalid/redacted"
        }
        return "redacted"
    }

    /// A deterministic 64-bit FNV-1a hash.
    static func hash(_ path: String, _ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(path)=\(value)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01b3
        }
        return hash
    }
}
