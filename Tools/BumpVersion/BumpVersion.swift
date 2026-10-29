import ArgumentParser
import Foundation
import ToolSupport

/// Compute and apply the next version: `0.MINOR.YYYYMMDD`.
///
/// * `MINOR` counts releases with changes to this package. It is bumped at most once per
///   release, no matter how many changes go into it.
/// * `YYYYMMDD` is the date on which the current state of Garmin's API was picked up. It
///   changes only when Garmin changes something; our own changes keep it.
///
/// Starting from the release 0.1.20261022:
///
///     swift run bump-version feature --note "Add gcpapi plot"   # 0.2.20261022
///     swift run bump-version garmin --note "New sleep fields"   # 0.1.20261029
///     swift run bump-version show                               # current/released
///
/// Both update `Sources/GCPAPISync/Version.swift` and the top section of `CHANGELOG.md`.
/// Merging the result to `main` publishes the release.
@main
struct BumpVersion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bump-version",
        abstract: "Bump the version according to the 0.MINOR.YYYYMMDD scheme.",
        subcommands: [Show.self, Feature.self, Garmin.self]
    )
}

struct Version: Comparable, CustomStringConvertible {
    let minor: Int
    let day: String  // YYYYMMDD

    init(minor: Int, day: String) {
        self.minor = minor
        self.day = day
    }

    init(parsing text: String) throws {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".")
        guard parts.count == 3, parts[0] == "0", let minor = Int(parts[1]), parts[2].count == 8,
            Int(parts[2]) != nil
        else { throw ValidationError("\"\(text)\" is not a 0.MINOR.YYYYMMDD version") }
        self.init(minor: minor, day: String(parts[2]))
    }

    var description: String { "0.\(minor).\(day)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.minor, lhs.day) < (rhs.minor, rhs.day)
    }
}

enum Repository {
    static let versionFile = URL(fileURLWithPath: "Sources/GCPAPISync/Version.swift")
    static let changelog = URL(fileURLWithPath: "CHANGELOG.md")
    static let declaration = "public let packageVersion = \""

    static func current() throws -> Version {
        let source = try String(contentsOf: versionFile, encoding: .utf8)
        guard let start = source.range(of: declaration),
            let end = source[start.upperBound...].firstIndex(of: "\"")
        else { throw ValidationError("cannot find the version in \(versionFile.path)") }
        return try Version(parsing: String(source[start.upperBound..<end]))
    }

    /// The newest version with a `v...` git tag, if any.
    static func released() throws -> Version? {
        let output = try runSubprocess(["git", "tag", "--list", "v0.*"])
        return output.split(whereSeparator: \.isNewline).compactMap {
            try? Version(parsing: String($0.dropFirst()))
        }.max()
    }

    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }

    static func apply(_ new: Version, note: String) throws {
        let old = try current()
        let source = try String(contentsOf: versionFile, encoding: .utf8)
        try source.replacingOccurrences(
            of: "\(declaration)\(old)\"", with: "\(declaration)\(new)\""
        ).write(to: versionFile, atomically: true, encoding: .utf8)
        try updateChangelog(new, note: note)
        print("\(old) -> \(new)")
    }

    static func updateChangelog(_ new: Version, note: String) throws {
        var text = try String(contentsOf: changelog, encoding: .utf8)
        let day = today()
        let date = "\(day.prefix(4))-\(day.dropFirst(4).prefix(2))-\(day.suffix(2))"
        let heading = "## [\(new)] - \(date)"
        let bullet = note.isEmpty ? "" : "- \(note)\n"
        let last = try released()
        if let top = text.range(of: "\n## [") {
            let headingStart = text.index(after: top.lowerBound)
            let lineEnd = text[headingStart...].firstIndex(of: "\n") ?? text.endIndex
            let topLine = String(text[headingStart..<lineEnd])
            let topVersion = topLine.dropFirst(4).prefix { $0 != "]" }
            if let version = try? Version(parsing: String(topVersion)),
                last.map({ version > $0 }) ?? true
            {
                // The top section is not released yet: rename it and add the note.
                let sectionEnd =
                    text.range(of: "\n## [", range: lineEnd..<text.endIndex)?.lowerBound
                    ?? text.endIndex
                var section = String(text[lineEnd..<sectionEnd])
                while section.hasSuffix("\n") {
                    section.removeLast()
                }
                if !bullet.isEmpty {
                    section +=
                        (section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "\n\n### Changed\n\n" : "\n") + bullet.dropLast()
                }
                text.replaceSubrange(headingStart..<sectionEnd, with: heading + section + "\n")
            } else {
                let body = bullet.isEmpty ? "\n" : "\n\n### Changed\n\n\(bullet)"
                text.insert(contentsOf: heading + body + "\n", at: headingStart)
            }
        } else {
            text += "\n" + heading + (bullet.isEmpty ? "\n" : "\n\n### Changed\n\n\(bullet)")
        }
        try text.write(to: changelog, atomically: true, encoding: .utf8)
    }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the current and the last released version.")

    func run() throws {
        print("current:  \(try Repository.current())")
        print("released: \(try Repository.released().map(String.init(describing:)) ?? "-")")
    }
}

struct Feature: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "We changed the package: bump MINOR (once per release), keep the date.")

    @Option(help: "Changelog entry.")
    var note = ""

    func run() throws {
        let version = try Repository.current()
        let last = try Repository.released()
        let minor =
            last.map { version.minor > $0.minor ? version.minor : $0.minor + 1 } ?? version.minor
        try Repository.apply(Version(minor: minor, day: version.day), note: note)
    }
}

struct Garmin: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Garmin changed its API: set the date, keep MINOR.")

    @Option(help: "Changelog entry.")
    var note = ""

    @Option(help: "The date to use (YYYYMMDD); today (UTC) by default.")
    var day = ""

    func run() throws {
        let version = try Repository.current()
        let when = try Version(parsing: "0.0.\(day.isEmpty ? Repository.today() : day)").day
        guard when >= version.day else {
            throw ValidationError("\(when) is before the current date component \(version.day)")
        }
        try Repository.apply(Version(minor: version.minor, day: when), note: note)
    }
}
