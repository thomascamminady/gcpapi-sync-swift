import Foundation
import ToolSupport

// MARK: - Naming

/// Strip Garmin's `DTO`/`Dto` suffix from a schema name.
func typeName(_ schemaName: String) -> String {
    if let name = classNames[schemaName] {
        return name
    }
    for suffix in ["DTO", "Dto"] where schemaName.hasSuffix(suffix) {
        return String(schemaName.dropLast(suffix.count))
    }
    return schemaName
}

/// Swift property names for each JSON member: Garmin's own `camelCase` names, minus
/// `_` before digits (`fastestSplit_100` -> `fastestSplit100`) and a `DTO` infix
/// (`summaryDTO` -> `summary`) unless that would clash.
func propertyNames(_ schemaName: String, _ properties: [JSON.Member]) throws -> [String: String] {
    let digitUnderscore = #/_(?=\d)/#
    let base = properties.map { member -> (String, String) in
        var name = member.key.replacing(digitUnderscore, with: "")
        if let first = name.first, first.isUppercase {
            name = first.lowercased() + name.dropFirst()
        }
        return (member.key, name)
    }
    var taken = Set(base.map(\.1))
    var result: [String: String] = [:]
    let infix = #/(DTO|Dto)(?=$|[A-Z][a-z])/#
    for (key, name) in base {
        var property = name
        let short = name.replacing(infix, with: "")
        if short != name, !short.isEmpty, !taken.contains(short) {
            taken.remove(name)
            taken.insert(short)
            property = short
        }
        if swiftKeywords.contains(property) {
            property = "`\(property)`"
        }
        result[key] = property
    }
    let reserved: Set<String> = ["extraFields", "container", "knownKeys", "decoder", "encoder"]
    guard Set(result.values).count == result.count, reserved.isDisjoint(with: result.values) else {
        throw GeneratorError("duplicate or reserved property names in \(schemaName): \(result)")
    }
    return result
}

private let swiftKeywords: Set<String> = [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
    "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public",
    "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case",
    "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in",
    "repeat", "return", "switch", "where", "while", "as", "catch", "false", "is", "nil",
    "self", "super", "throw", "throws", "true", "try", "any", "some", "Type", "Self",
]

// MARK: - Types

/// What a property decodes to.
indirect enum FieldType: Equatable {
    case int, double, bool, string, uuid, date, time, local, utc, json
    case model(String)
    case list(Self)
    case seriesRows
    case map(Self)

    /// Whether the Swift type comes from Foundation (`Date`, `UUID`).
    var needsFoundation: Bool {
        switch self {
        case .utc, .uuid: true
        case .list(let element), .map(let element): element.needsFoundation
        default: false
        }
    }

    var swift: String {
        switch self {
        case .int: "Int"
        case .double: "Double"
        case .bool: "Bool"
        case .string: "String"
        case .uuid: "UUID"
        case .date: "GarminDate"
        case .time: "GarminTime"
        case .local: "LocalDateTime"
        case .utc: "Date"
        case .json: "JSONValue"
        case .model(let name): name
        case .list(let element): "[\(element.swift)]"
        case .seriesRows: "[SeriesRow]"
        case .map(let value): "[String: \(value.swift)?]"
        }
    }
}

private func unwrapAllOf(_ schema: JSON) -> JSON {
    guard let options = schema["allOf"]?.array, options.count == 1 else { return schema }
    var merged = options[0]
    for member in schema.members where member.key != "allOf" {
        merged.set(member.key, member.value)
    }
    return unwrapAllOf(merged)
}

private func matches(_ text: String, _ pattern: String) -> Bool {
    guard let regex = try? Regex(pattern).ignoresCase() else { return false }
    return text.contains(regex)
}

private func timestampType(_ name: String, _ schema: JSON) -> FieldType {
    let lowered = name.lowercased()
    if lowered.contains("gmt") || lowered.contains("utc") {
        return .utc
    }
    if lowered.contains("local") {
        return .local
    }
    let utcDescription = #"\bin UTC\b|UTC (time|timestamp|date)|UTC timezone|RFC 3339|Unix epoch"#
    return matches(schema["description"]?.string ?? "", utcDescription) ? .utc : .local
}

private func isBareObject(_ schema: JSON) -> Bool {
    let kind = schema["type"]?.string
    return (kind == "object" || kind == nil)
        && ["$ref", "properties", "additionalProperties", "items"].allSatisfy { schema[$0] == nil }
}

/// The Swift type (without `?`) for a property schema.
func fieldType(_ name: String, _ raw: JSON) -> FieldType {
    let schema = unwrapAllOf(raw)
    if let reference = schema["$ref"]?.string {
        let target = String(reference.split(separator: "/").last ?? "")
        switch target {
        case "ConnectDate": return .date
        case "ConnectTimestamp": return timestampType(name, schema)
        case "LocalTime": return .time
        default: return .model(typeName(target))
        }
    }
    switch schema["type"]?.string {
    case "string": return stringType(name, schema)
    case "integer":
        let description = schema["description"]?.string ?? ""
        return matches(description, "milliseconds since the Unix epoch") ? .utc : .int
    case "array": return arrayType(name, schema)
    case "number": return .double
    case "boolean": return .bool
    default:
        if let value = schema["additionalProperties"], value.isObject {
            return .map(fieldType(name, value))
        }
        return .json
    }
}

private func stringType(_ name: String, _ schema: JSON) -> FieldType {
    let format = schema["format"]?.string
    let description = schema["description"]?.string ?? ""
    switch format {
    case "date": return .date
    case "time": return .time
    case "uuid": return .uuid
    default: break
    }
    let sample = "\(schema["pattern"]?.plainText ?? "") \(schema["example"]?.plainText ?? "")"
    let timestampPattern =
        #"\d{4}\S{0,3}-\S{0,3}\d{2}\S{0,3}-\S{0,3}\d{2}\S{0,3}T|\\d\{4\}-\\d\{2\}-\\d\{2\}T"#
    if format == "date-time" || matches(sample, timestampPattern)
        || matches(description, "yyyy-MM-dd[ 'T]+HH:mm")
    {
        return timestampType(name, schema)
    }
    if name.hasSuffix("Date"), !matches(description, "time") {
        // "calendarDate", "summaryDate", ...: plain YYYY-MM-DD strings without a format.
        return .date
    }
    return .string
}

private func arrayType(_ name: String, _ schema: JSON) -> FieldType {
    let items = unwrapAllOf(schema["items"] ?? [:])
    if items["type"]?.string == "array", isBareObject(unwrapAllOf(items["items"] ?? [:])) {
        return .seriesRows
    }
    if isBareObject(items) {
        return .list(.json)
    }
    return .list(fieldType(name, items))
}

// MARK: - Documentation

/// Collapse whitespace, decode double-escaped characters, end with punctuation, and turn
/// Python-style ``code`` into Markdown `code`.
func cleanDocumentation(_ text: String) -> String {
    var cleaned = text
    while let range = cleaned.range(of: #"\\u[0-9a-fA-F]{4}"#, options: .regularExpression) {
        let code = UInt32(cleaned[range].dropFirst(2), radix: 16) ?? 0x3F
        cleaned.replaceSubrange(
            range, with: String(Unicode.Scalar(code).map(Character.init) ?? "?"))
    }
    cleaned = cleaned.replacingOccurrences(of: "``", with: "`")
    cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if let last = cleaned.last, !".!?)".contains(last) {
        cleaned += "."
    }
    return cleaned
}

/// `///` lines for `text`, wrapped to fit 100 columns at `indent`.
func docComment(_ text: String, indent: String) -> [String] {
    let width = 100 - indent.count - 4
    var lines: [String] = []
    var line = ""
    for word in cleanDocumentation(text).split(separator: " ") {
        if !line.isEmpty, line.count + 1 + word.count > width {
            lines.append(line)
            line = ""
        }
        line += line.isEmpty ? String(word) : " \(word)"
    }
    if !line.isEmpty {
        lines.append(line)
    }
    return lines.map { "\(indent)/// \($0)" }
}

private func fieldDocumentation(_ key: String, _ raw: JSON) -> String {
    let schema = unwrapAllOf(raw)
    var parts: [String] = []
    if let description = schema["description"]?.string, !description.isEmpty {
        parts.append(description)
    }
    let values = schema["enum"]?.array ?? unwrapAllOf(schema["items"] ?? [:])["enum"]?.array
    if let values, !values.isEmpty {
        parts.append(
            "Known values: " + values.map { "``\($0.plainText)``" }.joined(separator: ", "))
    }
    if case .bool(true) = schema["deprecated"] {
        parts.append("Deprecated")
    }
    guard !parts.isEmpty else { return "Garmin's ``\(key)``." }
    return parts.map {
        var part = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        while part.hasSuffix(".") {
            part.removeLast()
        }
        return part + "."
    }.joined(separator: " ")
}

// MARK: - Rendering

struct Property {
    let key: String
    let name: String
    let type: FieldType
    let required: Bool
    let documentation: String

    var declaration: String {
        "public var \(name): \(type.swift)\(required ? "" : "?")"
    }

    var bareName: String { name.replacingOccurrences(of: "`", with: "") }
}

func properties(of schemaName: String, _ schema: JSON) throws -> [Property] {
    let members = schema["properties"]?.members ?? []
    let names = try propertyNames(schemaName, members)
    return members.map { member in
        Property(
            key: member.key, name: names[member.key] ?? member.key,
            type: fieldType(member.key, member.value),
            required: requiredFields.contains("\(schemaName).\(member.key)"),
            documentation: fieldDocumentation(member.key, member.value)
        )
    }
}

private func decodeStatement(_ property: Property) throws -> String {
    let key = ".\(property.bareName)"
    switch property.type {
    case .utc where !property.required:
        return "\(property.name) = try container.decodeUTC(\(key))"
    case .list(.utc) where !property.required:
        return "\(property.name) = try container.decodeUTCList(\(key))"
    case .utc, .list(.utc), .map(.utc), .list(.list(.utc)):
        throw GeneratorError("unsupported UTC field \(property.key)")
    default:
        let method = property.required ? "decode" : "decodeIfPresent"
        return
            "\(property.name) = try container.\(method)("
            + "\(property.type.swift).self, forKey: \(key))"
    }
}

private func encodeStatement(_ property: Property) -> String {
    let key = ".\(property.bareName)"
    return switch property.type {
    case .utc: "try container.encodeUTC(\(property.name), forKey: \(key))"
    case .list(.utc): "try container.encodeUTCList(\(property.name), forKey: \(key))"
    default:
        "try container.\(property.required ? "encode" : "encodeIfPresent")("
            + "\(property.name), forKey: \(key))"
    }
}

/// The stored properties and the memberwise initializer.
private func renderStorage(_ fields: [Property]) -> [String] {
    var lines: [String] = []
    for field in fields {
        lines += docComment(field.documentation, indent: "    ")
        lines.append("    \(field.declaration)")
    }
    lines += [
        "    /// Fields Garmin sent that this model does not describe, by their JSON names.",
        "    public var extraFields: [String: JSONValue]",
        "",
        "    /// A value with the given fields; optional fields default to `nil`.",
        "    public init(",
    ]
    lines += fields.map {
        "        \($0.bareName): \($0.type.swift)\($0.required ? "" : "? = nil"),"
    }
    lines += ["        extraFields: [String: JSONValue] = [:]", "    ) {"]
    lines += fields.map { "        self.\($0.bareName) = \($0.bareName)" }
    return lines + ["        self.extraFields = extraFields", "    }", ""]
}

/// `Codable` conformance: coding keys, `init(from:)` and `encode(to:)`.
private func renderCoding(_ fields: [Property]) throws -> [String] {
    guard !fields.isEmpty else {
        return [
            "    /// Decode Garmin's JSON; every member goes to ``extraFields``.",
            "    public init(from decoder: any Decoder) throws {",
            "        extraFields = try decoder.extraFields(known: [])",
            "    }",
            "",
            "    /// Encode as Garmin's JSON.",
            "    public func encode(to encoder: any Encoder) throws {",
            "        try encoder.encodeExtraFields(extraFields)",
            "    }",
        ]
    }
    var lines = ["    private enum CodingKeys: String, CodingKey, CaseIterable {"]
    lines += fields.map { field in
        field.bareName == field.key
            ? "        case \(field.name)" : "        case \(field.name) = \"\(field.key)\""
    }
    lines += [
        "    }",
        "",
        "    private static let knownKeys = Set(CodingKeys.allCases.map(\\.rawValue))",
        "",
        "    /// Decode Garmin's JSON; unknown members go to ``extraFields``.",
        "    public init(from decoder: any Decoder) throws {",
        "        let container = try decoder.container(keyedBy: CodingKeys.self)",
    ]
    lines += try fields.map { "        " + (try decodeStatement($0)) }
    lines += [
        "        extraFields = try decoder.extraFields(known: Self.knownKeys)",
        "    }",
        "",
        "    /// Encode as Garmin's JSON; `nil` fields are omitted.",
        "    public func encode(to encoder: any Encoder) throws {",
        "        var container = encoder.container(keyedBy: CodingKeys.self)",
    ]
    lines += fields.map { "        " + encodeStatement($0) }
    return lines + ["        try encoder.encodeExtraFields(extraFields)", "    }"]
}

/// One model file.
func renderModel(_ schemaName: String, _ schema: JSON) throws -> String {
    let fields = try properties(of: schemaName, schema)
    let summary = schema["description"]?.string ?? "Garmin's ``\(schemaName)`` object."
    var lines = [generatedHeader]
    if fields.contains(where: \.type.needsFoundation) {
        lines += ["public import Foundation", ""]
    }
    lines += docComment(summary, indent: "")
    lines.append("public struct \(typeName(schemaName)): GarminModel {")
    lines += renderStorage(fields)
    lines += try renderCoding(fields)
    lines.append("}")
    return lines.joined(separator: "\n") + "\n"
}

let generatedHeader = """
    // Generated by `swift run generate-models` from Garmin's OpenAPI document, with
    // corrections where the live API disagrees with it. Do not edit by hand.

    """

/// The list of every model type, for tests.
func renderIndex(_ names: [String]) -> String {
    var lines = [
        generatedHeader,
        "/// Every generated model type, in alphabetical order.",
        "let allModelTypes: [any GarminModel.Type] = [",
    ]
    lines += names.map { "    \($0).self," }
    lines.append("]")
    return lines.joined(separator: "\n") + "\n"
}

// MARK: - Test samples

/// A JSON literal (as `JSONValue` Swift syntax) satisfying `type`.
private func sample(_ type: FieldType, models: [String: [Property]]) -> String {
    switch type {
    case .int: "7"
    case .double: "1.5"
    case .bool: "true"
    case .string: "\"text\""
    case .uuid: "\"00000000-0000-4000-8000-000000000000\""
    case .date: "\"2026-01-15\""
    case .time: "\"08:00:00\""
    case .local, .utc: "\"2026-01-15T08:00:00.0\""
    case .json: "\"value\""
    case .model(let name): minimalSample(models[name] ?? [], models: models)
    case .list(let element): "[\(sample(element, models: models))]"
    case .seriesRows: "[[1_792_533_600_000, 42]]"
    case .map(let value): "[\"key\": \(sample(value, models: models))]"
    }
}

private func objectLiteral(_ entries: [String]) -> String {
    entries.isEmpty ? "[:]" : "[" + entries.joined(separator: ", ") + "]"
}

private func minimalSample(_ fields: [Property], models: [String: [Property]]) -> String {
    objectLiteral(
        fields.filter(\.required).map { "\"\($0.key)\": \(sample($0.type, models: models))" })
}

/// Sample payloads for every model: one with every field, one with only required ones.
func renderSamples(_ models: [(name: String, fields: [Property])]) -> String {
    let byName = Dictionary(uniqueKeysWithValues: models.map { ($0.name, $0.fields) })
    var lines = [
        generatedHeader,
        "@testable import GCPAPISync",
        "",
        "/// A payload with every field of a model, one with only its required fields, and a",
        "/// copy made through the memberwise initializer.",
        "struct ModelSample: Sendable {",
        "    let type: any GarminModel.Type",
        "    let full: JSONValue",
        "    let minimal: JSONValue",
        "    let rebuild: @Sendable (any GarminModel) -> (any GarminModel)?",
        "}",
        "",
        "let modelSamples: [ModelSample] = [",
    ]
    for (name, fields) in models {
        let full = objectLiteral(
            fields.map { "\"\($0.key)\": \(sample($0.type, models: byName))" })
        let arguments =
            (fields.map { "\($0.bareName): $0.\($0.name)" } + ["extraFields: $0.extraFields"])
            .joined(separator: ", ")
        lines.append(
            "    ModelSample(type: \(name).self, full: \(full), "
                + "minimal: \(minimalSample(fields, models: byName))) "
                + "{ ($0 as? \(name)).map { \(name)(\(arguments)) } },"
        )
    }
    lines.append("]")
    return lines.joined(separator: "\n") + "\n"
}
