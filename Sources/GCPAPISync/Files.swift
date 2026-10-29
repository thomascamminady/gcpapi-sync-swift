public import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Where the client looks for configuration: environment variables and the home
/// directory (for `~` in paths).
///
/// ``current`` reads the running process; pass your own to isolate tests or to run
/// several configurations side by side.
public struct ProcessEnvironment: Sendable {
    /// Environment variables.
    public var variables: [String: String]
    /// The directory `~` stands for.
    public var homeDirectory: URL

    /// An environment.
    public init(variables: [String: String], homeDirectory: URL) {
        self.variables = variables
        self.homeDirectory = homeDirectory
    }

    /// The running process's environment and home directory.
    public static var current: Self {
        Self(
            variables: ProcessInfo.processInfo.environment,
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )
    }

    /// A file URL for `path`, with a leading `~` replaced by the home directory.
    public func url(for path: String) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}

/// Atomic file writes.
enum PrivateFiles {
    /// Write `data` to `url` through a temporary file in the same directory, so readers
    /// never see a partial file. With `permissions`, the file gets that POSIX mode and
    /// missing parent directories mode `0700`.
    static func write(_ data: Data, to url: URL, permissions: Int?) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: permissions.map { _ in [.posixPermissions: 0o700] }
        )
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString)"
        )
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: data,
                attributes: permissions.map { [.posixPermissions: $0] }
            )
        else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
                ]
            )
        }
    }

    /// Whether only the owner may access `url` (always true where POSIX permissions do
    /// not apply, or when the file cannot be inspected).
    static func isPrivate(_ url: URL) -> Bool {
        #if os(Windows)
            return true
        #else
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let mode = attributes[.posixPermissions] as? Int
            else { return true }
            return mode & 0o077 == 0
        #endif
    }
}
