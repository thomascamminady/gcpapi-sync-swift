public import Foundation
public import GCPAPISync
import Logging

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Where the command line tool reads and writes text.
public protocol Console: Sendable {
    /// Write a line to standard output.
    func write(_ line: String) async
    /// Write a line to standard error.
    func note(_ line: String) async
    /// Read a line from standard input.
    func readLine() async -> String?
    /// Read a secret from a hidden prompt.
    func readSecret(prompt: String) async -> String?
    /// Whether standard input is a terminal.
    var isTerminal: Bool { get }
}

/// The process's standard streams.
public struct StandardConsole: Console {
    /// The standard streams.
    public init() {}

    /// Write a line to standard output.
    public func write(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// Write a line to standard error.
    public func note(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Read a line from standard input.
    public func readLine() -> String? {
        Swift.readLine(strippingNewline: true)
    }

    /// Read a secret without echoing it.
    public func readSecret(prompt: String) -> String? {
        #if os(Windows)
            return Swift.readLine(strippingNewline: true)
        #else
            guard let pointer = getpass(prompt) else { return nil }
            return String(cString: pointer)
        #endif
    }

    /// Whether standard input is a terminal.
    public var isTerminal: Bool { isatty(0) == 1 }
}

/// Everything the commands depend on, so tests can replace it.
public struct CLIContext: Sendable {
    /// Environment variables and home directory.
    public var environment: ProcessEnvironment
    /// Standard streams.
    public var console: any Console
    /// The HTTP transport; `nil` for the default `URLSession` one.
    public var transport: (any HTTPTransport)?
    /// The retry policy.
    public var retry: RetryConfig
    /// The current time.
    public var now: @Sendable () -> Date
    /// The local time zone (for "today").
    public var timeZone: TimeZone

    /// A context.
    public init(
        environment: ProcessEnvironment, console: any Console,
        transport: (any HTTPTransport)? = nil, retry: RetryConfig = .default,
        now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current
    ) {
        self.environment = environment
        self.console = console
        self.transport = transport
        self.retry = retry
        self.now = now
        self.timeZone = timeZone
    }

    /// The running process.
    public static var live: Self {
        Self(environment: .current, console: StandardConsole())
    }

    /// The context commands run in.
    @TaskLocal public static var current = Self.live

    /// Warnings go to standard error; everything else is dropped.
    var logger: Logger {
        let console = self.console
        var logger = Logger(label: "gcpapi") { _ in ConsoleLogHandler(console: console) }
        logger.logLevel = .warning
        return logger
    }
}

/// Sends log messages to the console's standard error.
struct ConsoleLogHandler: LogHandler {
    let console: any Console
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .warning

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let console = self.console
        let line = "\(event.level): \(event.message)"
        Task { await console.note(line) }
    }
}
