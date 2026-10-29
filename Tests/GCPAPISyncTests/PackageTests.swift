import Foundation
import Testing

@testable import GCPAPISync

/// The repository root, found from this file's location.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

private func read(_ path: String) throws -> String {
    try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
}

private struct SurfaceParameter: Decodable {
    let name: String
    let location: String

    enum CodingKeys: String, CodingKey {
        case name
        case location = "in"
    }
}

private struct SurfaceEndpoint: Decodable {
    let method: String
    let path: String
    let parameters: [SurfaceParameter]
}

/// `spec/endpoints.json`.
private struct Surface: Decodable {
    let endpoints: [SurfaceEndpoint]
}

private func surface() throws -> Surface {
    try JSONDecoder().decode(Surface.self, from: Data(try read("spec/endpoints.json").utf8))
}

private func matches(_ template: String, _ path: String) -> Bool {
    let templateParts = template.split(separator: "/")
    let pathParts = path.split(separator: "/")
    return templateParts.count == pathParts.count
        && zip(templateParts, pathParts).allSatisfy { $0.hasPrefix("{") || $0 == $1 }
}

/// Package-level guarantees: versioning, changelog, spec coverage, README.
@Suite struct PackageTests {
    @Test func versionIsZeroMinorGarminDate() throws {
        let parts = packageVersion.split(separator: ".")
        try #require(parts.count == 3, "\(packageVersion) is not 0.MINOR.YYYYMMDD")
        #expect(parts[0] == "0")
        #expect((Int(parts[1]) ?? 0) >= 1)
        let day = try GarminDate(
            "\(parts[2].prefix(4))-\(parts[2].dropFirst(4).prefix(2))-\(parts[2].suffix(2))")
        #expect(day <= GarminDate.today().adding(days: 1), "the date lies in the future")
    }

    @Test func changelogDescribesThisVersion() throws {
        let changelog = try read("CHANGELOG.md")
        let heading = try #require(
            changelog.split(separator: "\n").first { $0.hasPrefix("## [") },
            "CHANGELOG.md has no version section")
        #expect(heading.hasPrefix("## [\(packageVersion)] - "), "run swift run bump-version")
    }

    @Test func everyDocumentedEndpointIsWrapped() throws {
        // Fails when Garmin adds an endpoint (spec/endpoints.json is refreshed weekly).
        for endpoint in try surface().endpoints {
            #expect(endpoint.method == "GET")
            #expect(
                cases.contains { matches(endpoint.path, $0.path) },
                "no client method calls \(endpoint.path)")
        }
    }

    @Test(arguments: cases.filter { $0.method != "getJSON" })
    func onlyDocumentedQueryParametersAreSent(testCase: Case) throws {
        let endpoints = try surface().endpoints.filter { matches($0.path, testCase.path) }
        try #require(endpoints.count == 1)
        let documented = Set(endpoints[0].parameters.filter { $0.location == "query" }.map(\.name))
        #expect(Set(testCase.params.map { $0[0] }).isSubset(of: documented))
    }

    @Test func readmeExamplesCompile() throws {
        let readme = try read("README.md")
        let blocks = readme.components(separatedBy: "```swift\n").dropFirst().map { chunk in
            chunk.components(separatedBy: "```").first ?? ""
        }.map { block in
            block.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("import ") }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let examples = try read("Tests/GCPAPISyncTests/ReadmeExamples.swift")
            .components(separatedBy: "    // README example\n").dropFirst().map { chunk in
                (chunk.components(separatedBy: "    // README end").first ?? "")
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.hasPrefix("    ") ? $0.dropFirst(4) : $0 }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        #expect(blocks.count == 6)
        #expect(blocks == examples, "update Tests/GCPAPISyncTests/ReadmeExamples.swift")
    }
}
