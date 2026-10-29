import Foundation
import ToolSupport

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

let swaggerPage = "https://developer.garmin.com/gc-developer-program/personal/swagger-docs/"

// MARK: - Corrections. Each one was verified against live API responses (October 2026).
// These tables are identical to the ones in gcpapi-sync-python's generator.

/// Fields the live API returns that the spec does not document.
let extraFields: [(schema: String, fields: JSON)] = [
    (
        "BodyBatteryActivityEventDTO",
        [
            "activityId": [
                "type": "integer", "format": "int64",
                "description": "ID of the activity behind this event, if any.",
            ],
            "activityName": [
                "type": "string", "description": "Name of the activity behind this event, if any.",
            ],
            "activityType": [
                "type": "string", "description": "Activity type key, such as ``running``.",
            ],
            "deviceId": [
                "type": "integer", "format": "int64",
                "description": "ID of the device that recorded the event.",
            ],
            "eventUpdateTimeGmt": [
                "type": "string", "format": "date-time",
                "description": "When the event was last updated, in UTC.",
            ],
        ]
    ),
    (
        "DailySleepDTO",
        [
            "retro": [
                "type": "boolean",
                "description": "Whether the sleep record was entered retroactively.",
            ]
        ]
    ),
    (
        "DateWeightDTO",
        [
            "samplePk": [
                "type": "integer", "format": "int64",
                "description": "Primary key of the weight sample.",
            ],
            "sourceType": [
                "type": "string",
                "description":
                    "Source of the measurement, such as ``INDEX_SCALE`` or ``MANUAL``.",
            ],
        ]
    ),
    (
        "GarminUUID",
        [
            "uuid": [
                "type": "string", "format": "uuid",
                "description": "The UUID in canonical string form.",
            ]
        ]
    ),
    (
        "HydrationV2DTO",
        [
            "consumedInMl": [
                "type": "number", "format": "double",
                "description": "Hydration consumed, in milliliters.",
            ]
        ]
    ),
    (
        "UserInfoDto",
        ["userPro": ["type": "boolean", "description": "Whether the user has a pro account."]]
    ),
]

private func scoreItem(_ description: String) -> JSON {
    ["$ref": "#/components/schemas/SleepScoreItem", "description": .string(description)]
}

private func fitnessComponent(_ description: String) -> JSON {
    ["$ref": "#/components/schemas/FitnessAgeComponent", "description": .string(description)]
}

private func seconds(_ description: String) -> JSON {
    ["type": "number", "format": "double", "description": .string(description)]
}

/// Free-form maps in the spec whose keys are in fact fixed. They become models so that
/// every value is reachable as a typed property (unknown keys still land in
/// `extraFields`). Keys verified against live responses.
let newSchemas: [(name: String, schema: JSON)] = [
    (
        "StressValues",
        [
            "type": "object",
            "description": "Stress metrics for one day. Durations are in seconds.",
            "properties": [
                "overallStressLevel": [
                    "type": "number", "format": "double",
                    "description": "Average stress level (0-100); negative when not enough data.",
                ],
                "restStressDuration": seconds("Time at rest (stress 0-25), in seconds."),
                "lowStressDuration": seconds("Time with low stress (26-50), in seconds."),
                "mediumStressDuration": seconds("Time with medium stress (51-75), in seconds."),
                "highStressDuration": seconds("Time with high stress (76-100), in seconds."),
            ],
        ]
    ),
    (
        "FitnessAgeComponents",
        [
            "type": "object",
            "description": "The inputs that determine Fitness Age.",
            "properties": [
                "vigorousDaysAvg": fitnessComponent("Average vigorous-activity days per week."),
                "vigorousMinutesAvg": fitnessComponent(
                    "Average vigorous intensity minutes per week."),
                "rhr": fitnessComponent("Resting heart rate."),
                "bodyFat": fitnessComponent("Body fat percentage."),
                "bmi": fitnessComponent("Body mass index (used when body fat is unavailable)."),
            ],
        ]
    ),
    (
        "SleepScores",
        [
            "type": "object",
            "description": "The overall sleep score and its contributing factors.",
            "properties": [
                "overall": scoreItem("Overall sleep score."),
                "totalDuration": scoreItem("Total sleep duration."),
                "stress": scoreItem("Average stress during sleep."),
                "awakeCount": scoreItem("Number of awakenings."),
                "restlessness": scoreItem("Restlessness."),
                "remPercentage": scoreItem("Share of REM sleep."),
                "lightPercentage": scoreItem("Share of light sleep."),
                "deepPercentage": scoreItem("Share of deep sleep."),
            ],
        ]
    ),
]

/// The only required fields: identifiers without which a record is meaningless and which
/// every live response contains. Everything else is optional, since Garmin omits and
/// nulls fields freely.
let requiredFields: Set<String> = [
    "SummarizedActivityDTO.activityId", "ActivitySummaryDTO.activityId",
]

/// Property schema replacements: (schema, field) -> new property schema.
let fieldSchemas: [(schema: String, field: String, replacement: JSON)] = [
    ("MultiValueWellnessChartItemDTO", "values", ["$ref": "#/components/schemas/StressValues"]),
    ("FitnessAgeDTO", "components", ["$ref": "#/components/schemas/FitnessAgeComponents"]),
    ("DailySleepDTO", "sleepScores", ["$ref": "#/components/schemas/SleepScores"]),
    ("FitnessAgeDTO", "lastUpdated", ["type": "string", "format": "date-time"]),
]

/// Schemas with hand-written time-series accessors (`Series.swift`).
let seriesSchemas = [
    "DailyHeartRateDTO", "BodyBatteryDailyReportDTO", "DailySpO2AndAcclimationDTO",
]

/// Schemas that the API serializes as scalars, not as the objects the spec describes.
let scalarSchemas: Set<String> = ["ConnectDate", "ConnectTimestamp", "LocalTime"]

/// Type-name overrides for schemas whose stripped names would be awkward or clash.
let classNames: [String: String] = [
    "UUID": "UUIDValue",
    "ApiDocumentListUserDailySummaryV2DTO": "UserDailySummaryV2List",
    // Swift only: `Unit` would shadow Foundation's `Unit` in every file importing both.
    "UnitDTO": "MeasurementUnit",
]

// MARK: - Loading

func httpGet(_ address: String) async throws -> String {
    guard let url = URL(string: address) else { throw GeneratorError("bad URL \(address)") }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.setValue("gcpapi-sync model generator", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw GeneratorError("GET \(address) failed")
    }
    return String(decoding: data, as: UTF8.self)
}

/// Decode a single-quoted JavaScript string literal starting at `start`.
func decodeJavaScriptString(_ source: [UInt8], from start: Int) throws -> String {
    let simple: [UInt8: String] = [
        UInt8(ascii: "n"): "\n", UInt8(ascii: "t"): "\t", UInt8(ascii: "r"): "\r",
        UInt8(ascii: "b"): "\u{08}", UInt8(ascii: "f"): "\u{0C}", UInt8(ascii: "v"): "\u{0B}",
        UInt8(ascii: "0"): "\u{00}",
    ]
    var out = ""
    var raw: [UInt8] = []
    var index = start
    func flush() {
        out += String(decoding: raw, as: UTF8.self)
        raw.removeAll()
    }
    func hex(_ from: Int, _ count: Int) throws -> String {
        guard from + count <= source.count,
            let code = UInt32(
                String(decoding: source[from..<from + count], as: UTF8.self), radix: 16),
            let scalar = Unicode.Scalar(code)
        else { throw GeneratorError("bad escape in the Swagger bundle") }
        return String(Character(scalar))
    }
    while index < source.count {
        let byte = source[index]
        if byte == UInt8(ascii: "'") {
            flush()
            return out
        }
        guard byte == UInt8(ascii: "\\"), index + 1 < source.count else {
            raw.append(byte)
            index += 1
            continue
        }
        flush()
        let next = source[index + 1]
        if next == UInt8(ascii: "u") {
            out += try hex(index + 2, 4)
            index += 6
        } else if next == UInt8(ascii: "x") {
            out += try hex(index + 2, 2)
            index += 4
        } else {
            out += simple[next] ?? String(decoding: [next], as: UTF8.self)
            index += 2
        }
    }
    throw GeneratorError("unterminated string in the Swagger bundle")
}

/// Download the OpenAPI document embedded in Garmin's Swagger page.
func fetchSpec() async throws -> JSON {
    let page = try await httpGet(swaggerPage)
    let bundlePattern =
        #/src="(/component---src-pages-gc-developer-program-personal-swagger-docs-js-[^"]+\.js)"/#
    guard let match = page.firstMatch(of: bundlePattern) else {
        throw GeneratorError(
            "Could not find the Swagger bundle on Garmin's page; the site layout changed.")
    }
    let bundle = Array(try await httpGet("https://developer.garmin.com" + match.1).utf8)
    let marker = Array("JSON.parse('{\"openapi\"".utf8)
    guard let index = firstIndex(of: marker, in: bundle) else {
        throw GeneratorError("Could not find the embedded OpenAPI document in the Swagger bundle.")
    }
    let start = index + Array("JSON.parse('".utf8).count
    return try JSONParser.parse(try decodeJavaScriptString(bundle, from: start))
}

private func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard needle.count <= haystack.count else { return nil }
    for index in 0...(haystack.count - needle.count)
    where haystack[index] == needle[0] && Array(haystack[index..<index + needle.count]) == needle {
        return index
    }
    return nil
}

// MARK: - Patching

func warn(_ message: String) {
    // Printed, not thrown: the weekly drift job turns these into a pull request note.
    print("warning: \(message)")
}

/// Schemas in document order.
typealias Schemas = [(name: String, schema: JSON)]

private func position(_ name: String, in schemas: Schemas) -> Int? {
    schemas.firstIndex { $0.name == name }
}

private func addNewSchemas(_ schemas: inout Schemas) {
    for (name, schema) in newSchemas {
        if position(name, in: schemas) != nil {
            warn("the spec now defines \(name); review newSchemas")
        } else {
            schemas.append((name, schema))
        }
    }
}

private func addExtraFields(_ schemas: inout Schemas) {
    for (schemaName, fields) in extraFields {
        guard let index = position(schemaName, in: schemas) else {
            warn("\(schemaName) is gone from the spec; drop it from extraFields")
            continue
        }
        var properties = schemas[index].schema["properties"] ?? [:]
        for member in fields.members {
            if properties[member.key] != nil {
                warn("\(schemaName).\(member.key) is now in the spec; drop it from extraFields")
            } else {
                properties.set(member.key, member.value)
            }
        }
        schemas[index].schema.set("properties", properties)
    }
}

private func replaceFields(_ schemas: inout Schemas) {
    for (schemaName, field, replacement) in fieldSchemas {
        guard let index = position(schemaName, in: schemas),
            let original = schemas[index].schema["properties"]?[field]
        else {
            warn("\(schemaName).\(field) is gone from the spec; drop it from fieldSchemas")
            continue
        }
        var properties = schemas[index].schema["properties"] ?? [:]
        var updated: JSON = ["description": original["description"] ?? .string("")]
        for member in replacement.members {
            updated.set(member.key, member.value)
        }
        properties.set(field, updated)
        schemas[index].schema.set("properties", properties)
    }
}

private func checkReferences(_ schemas: Schemas) {
    for required in requiredFields.sorted() {
        let parts = required.split(separator: ".").map(String.init)
        let index = position(parts[0], in: schemas)
        if index.flatMap({ schemas[$0].schema["properties"]?[parts[1]] }) == nil {
            warn("\(required) is gone from the spec; drop it from requiredFields")
        }
    }
    for name in seriesSchemas where position(name, in: schemas) == nil {
        warn("\(name) is gone from the spec; update Series.swift")
    }
}

/// The spec's schemas, in document order, with the corrections above applied.
func patchedSchemas(_ spec: JSON) -> Schemas {
    var schemas: Schemas = (spec["components"]?["schemas"]?.members ?? []).map {
        (name: $0.key, schema: $0.value)
    }
    addNewSchemas(&schemas)
    addExtraFields(&schemas)
    replaceFields(&schemas)
    checkReferences(schemas)
    return schemas
}

/// A compact, diff-friendly summary of every endpoint (no descriptions), in the same
/// format as gcpapi-sync-python's `spec/endpoints.json`.
func endpointSurface(_ spec: JSON) -> JSON {
    var endpoints: [JSON] = []
    for path in (spec["paths"]?.members ?? []).sorted(by: { $0.key < $1.key }) {
        for operation in path.value.members.sorted(by: { $0.key < $1.key })
        where ["get", "post", "put", "patch", "delete"].contains(operation.key) {
            let parameters = (operation.value["parameters"]?.array ?? []).map { parameter in
                let required: Bool =
                    if case .bool(true) = parameter["required"] { true } else { false }
                let kind = parameter["schema"]?["type"]?.string ?? "string"
                let name: JSON = parameter["name"] ?? .null
                let location: JSON = parameter["in"] ?? .null
                return [
                    "name": name, "in": location, "required": .bool(required),
                    "type": .string(kind),
                ] as JSON
            }
            let sorted = parameters.sorted {
                ($0["in"]?.string ?? "", $0["name"]?.string ?? "")
                    < ($1["in"]?.string ?? "", $1["name"]?.string ?? "")
            }
            let responses = operation.value["responses"]
            let success = responses?["200"] ?? responses?["default"] ?? [:]
            let content = success["content"]?.members.first?.value ?? [:]
            let entry: JSON = [
                "method": .string(operation.key.uppercased()),
                "path": .string(path.key),
                "parameters": .array(sorted),
                "response": schemaLabel(content["schema"]),
            ]
            endpoints.append(entry)
        }
    }
    return [
        "source": .string(swaggerPage),
        "title": spec["info"]?["title"] ?? .null,
        "version": spec["info"]?["version"] ?? .null,
        "endpoints": .array(endpoints),
    ]
}

private func schemaLabel(_ schema: JSON?) -> JSON {
    guard let schema, !schema.members.isEmpty else { return .null }
    if let reference = schema["$ref"]?.string {
        return .string(typeName(String(reference.split(separator: "/").last ?? "")))
    }
    if schema["type"]?.string == "array" {
        let inner = schemaLabel(schema["items"])
        return .string("list[\(inner.string ?? "None")]")
    }
    return .string(schema["type"]?.plainText ?? "None")
}

struct GeneratorError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
