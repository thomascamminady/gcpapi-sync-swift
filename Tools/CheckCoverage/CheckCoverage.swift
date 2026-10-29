import ArgumentParser
import Foundation

/// Fail when line coverage of `Sources/` is below a minimum.
///
///     swift test --enable-code-coverage
///     swift run check-coverage "$(swift test --show-codecov-path)" --minimum 99
@main
struct CheckCoverage: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-coverage",
        abstract: "Check the line coverage of Sources/ in an llvm-cov JSON export."
    )

    @Argument(help: "The JSON written by `swift test --enable-code-coverage`.")
    var report: String

    @Option(help: "The minimum line coverage in percent.")
    var minimum = 99.0

    func run() throws {
        let export = try JSONDecoder().decode(
            CoverageExport.self, from: Data(contentsOf: URL(fileURLWithPath: report)))
        let files = export.data.flatMap(\.files).filter {
            $0.filename.contains("/Sources/") && !$0.filename.contains("/.build/")
        }
        let covered = files.reduce(0) { $0 + $1.summary.lines.covered }
        let total = files.reduce(0) { $0 + $1.summary.lines.count }
        for file in files where file.summary.lines.covered < file.summary.lines.count {
            let missed = file.summary.lines.count - file.summary.lines.covered
            let name = file.filename.components(separatedBy: "/Sources/").last ?? file.filename
            print("\(missed) lines not covered in Sources/\(name)")
        }
        let percent = total == 0 ? 0 : Double(covered) / Double(total) * 100
        print(String(format: "line coverage: %.2f%% (%d of %d lines)", percent, covered, total))
        guard percent >= minimum else {
            throw ValidationError(String(format: "line coverage is below %.1f%%", minimum))
        }
    }
}

/// The parts of an llvm-cov JSON export this tool reads.
private struct CoverageExport: Decodable {
    let data: [CoverageData]
}

private struct CoverageData: Decodable {
    let files: [CoverageFile]
}

private struct CoverageFile: Decodable {
    let filename: String
    let summary: CoverageSummary
}

private struct CoverageSummary: Decodable {
    let lines: CoverageLines
}

private struct CoverageLines: Decodable {
    let count: Int
    let covered: Int
}
