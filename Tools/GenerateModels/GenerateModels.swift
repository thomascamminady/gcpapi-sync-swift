import ArgumentParser
import Foundation
import ToolSupport

/// Generate the response models from Garmin's OpenAPI document.
///
/// Garmin publishes the Personal API spec only inside the JavaScript bundle of its Swagger
/// page, so this tool locates that bundle, extracts the embedded JSON, applies corrections
/// for places where the live API contradicts the spec (see `Spec.swift`), and writes one
/// Swift file per model.
@main
struct GenerateModels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-models",
        abstract: "Regenerate the models from Garmin's OpenAPI document."
    )

    @Option(help: "A local OpenAPI JSON file to use instead of downloading the current spec.")
    var spec: String?

    @Option(help: "Also write the (unpatched) spec to this path, for diffing.")
    var dumpSpec: String?

    mutating func run() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Package.swift").path)
        else { throw GeneratorError("run this from the repository root") }
        let raw: JSON
        if let spec {
            raw = try JSONParser.parse(String(contentsOfFile: spec, encoding: .utf8))
        } else {
            raw = try await fetchSpec()
        }
        if let dumpSpec {
            try (JSONWriter.write(raw) + "\n").write(
                toFile: dumpSpec, atomically: true, encoding: .utf8)
        }
        let schemas = patchedSchemas(raw).filter { !scalarSchemas.contains($0.name) }
            .sorted { typeName($0.name) < typeName($1.name) }
        let names = schemas.map { typeName($0.name) }
        guard Set(names).count == names.count else {
            throw GeneratorError("type name collision after stripping DTO suffixes")
        }

        let surface = root.appendingPathComponent("spec/endpoints.json")
        try (JSONWriter.write(endpointSurface(raw)) + "\n")
            .write(to: surface, atomically: true, encoding: .utf8)

        let models = root.appendingPathComponent("Sources/GCPAPISync/Models/Generated")
        // Replace the generated Swift files, keeping anything else (such as .swiftlint.yml).
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: models.path)
        where name.hasSuffix(".swift") {
            try FileManager.default.removeItem(at: models.appendingPathComponent(name))
        }
        var fields: [(name: String, fields: [Property])] = []
        for (schemaName, schema) in schemas {
            let name = typeName(schemaName)
            try renderModel(schemaName, schema)
                .write(
                    to: models.appendingPathComponent("\(name).swift"), atomically: true,
                    encoding: .utf8)
            fields.append((name, try properties(of: schemaName, schema)))
        }
        try renderIndex(names)
            .write(
                to: models.appendingPathComponent("AllModels.swift"), atomically: true,
                encoding: .utf8)

        let samples = root.appendingPathComponent("Tests/GCPAPISyncTests/Generated")
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        try renderSamples(fields)
            .write(
                to: samples.appendingPathComponent("ModelSamples.swift"), atomically: true,
                encoding: .utf8)

        try format([models.path, samples.path])
        print("wrote \(names.count) models to Sources/GCPAPISync/Models/Generated")
        print("wrote the endpoint surface to spec/endpoints.json")
    }

    private func format(_ paths: [String]) throws {
        _ = try runSubprocess(
            ["swift", "format", "--in-place", "--recursive", "--parallel"] + paths)
    }
}
