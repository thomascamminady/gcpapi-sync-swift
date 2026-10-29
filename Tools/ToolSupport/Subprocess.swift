import Foundation

/// A failed or unavailable subprocess.
public struct SubprocessError: Error, CustomStringConvertible {
    /// What went wrong.
    public let description: String
}

/// Run `arguments` (looked up on `PATH`) and return its standard output.
///
/// The repository tools run on macOS and Linux; on platforms without processes (iOS and
/// friends, where Xcode still compiles them as part of the package) this always throws.
///
/// - Parameter arguments: The program and its arguments.
/// - Returns: The program's standard output.
/// - Throws: ``SubprocessError`` if the program fails or processes are unavailable.
public func runSubprocess(_ arguments: [String]) throws -> String {
    #if os(macOS) || os(Linux) || os(Windows)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SubprocessError(description: "\(arguments.joined(separator: " ")) failed")
        }
        return output
    #else
        throw SubprocessError(description: "subprocesses are not available on this platform")
    #endif
}
