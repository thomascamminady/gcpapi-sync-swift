import Foundation

/// How the client retries failed requests.
///
/// Connection errors, timeouts and the statuses in ``retryStatuses`` are retried with
/// exponential backoff and jitter. A `Retry-After` header is honored, unless it asks for
/// more than ``maxRetryAfter`` seconds, in which case the error is thrown immediately.
public struct RetryConfig: Hashable, Sendable {
    /// Retries after the first attempt. `0` disables retrying.
    public let maxRetries: Int
    /// Delay before the first retry, in seconds.
    public let initialDelay: Double
    /// Upper bound for the computed backoff, in seconds.
    public let maxDelay: Double
    /// Random fraction (`0...1`) added to or removed from each delay.
    public let jitter: Double
    /// Longest `Retry-After` the client is willing to wait, in seconds.
    public let maxRetryAfter: Double
    /// HTTP statuses considered transient.
    public let retryStatuses: Set<Int>

    /// The default policy: two retries starting at half a second.
    public static let `default` = Self(
        unchecked: 2, initialDelay: 0.5, maxDelay: 8, jitter: 0.25, maxRetryAfter: 60,
        retryStatuses: [408, 429, 500, 502, 503, 504]
    )

    /// A retry policy.
    ///
    /// - Throws: ``InvalidArgumentError`` for negative counts or delays, or a jitter
    ///   outside `0...1`.
    public init(
        maxRetries: Int = 2,
        initialDelay: Double = 0.5,
        maxDelay: Double = 8,
        jitter: Double = 0.25,
        maxRetryAfter: Double = 60,
        retryStatuses: Set<Int> = [408, 429, 500, 502, 503, 504]
    ) throws {
        guard maxRetries >= 0 else {
            throw InvalidArgumentError("maxRetries must be >= 0")
        }
        guard initialDelay >= 0, maxDelay >= 0, maxRetryAfter >= 0 else {
            throw InvalidArgumentError("delays must be >= 0")
        }
        guard (0...1).contains(jitter) else {
            throw InvalidArgumentError("jitter must be between 0 and 1")
        }
        self.init(
            unchecked: maxRetries, initialDelay: initialDelay, maxDelay: maxDelay,
            jitter: jitter, maxRetryAfter: maxRetryAfter, retryStatuses: retryStatuses
        )
    }

    private init(
        unchecked maxRetries: Int, initialDelay: Double, maxDelay: Double, jitter: Double,
        maxRetryAfter: Double, retryStatuses: Set<Int>
    ) {
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.maxRetryAfter = maxRetryAfter
        self.retryStatuses = retryStatuses
    }

    /// Delay before retry number `attempt` (0-based), including jitter.
    public func backoff(attempt: Int) -> Double {
        var delay = min(initialDelay * pow(2, Double(attempt)), maxDelay)
        if jitter > 0 {
            delay *= 1 + Double.random(in: -jitter...jitter)
        }
        return max(delay, 0)
    }
}

/// Parsing of the `Retry-After` header.
enum RetryAfter {
    private static let months = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    /// Seconds to wait, from delta-seconds or an HTTP date (RFC 2822); `nil` if absent or
    /// unparseable.
    static func seconds(_ header: String?, now: Date = Date()) -> Double? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(value), seconds.isFinite {
            return max(seconds, 0)
        }
        guard let when = httpDate(value) else { return nil }
        return max(when.timeIntervalSince(now), 0)
    }

    /// `[Day, ]DD Mon YYYY HH:MM[:SS] (GMT|UT|Z|±HHMM)`.
    static func httpDate(_ text: String) -> Date? {
        var parts = text.split(separator: " ").map(String.init)
        if let first = parts.first, first.hasSuffix(",") {
            parts.removeFirst()
        }
        guard parts.count == 5, let day = Int(parts[0]),
            let month = months.firstIndex(of: parts[1].lowercased()),
            let year = Int(parts[2]), Civil.isValid(year: year, month: month + 1, day: day)
        else { return nil }
        let clockParts = parts[3].split(separator: ":")
        let clock = clockParts.compactMap { Int($0) }
        guard (2...3).contains(clock.count), clock.count == clockParts.count,
            let zone = offset(parts[4])
        else { return nil }
        let (hour, minute) = (clock[0], clock[1])
        let second = clock.count == 3 ? clock[2] : 0
        guard hour < 24, minute < 60, second < 61 else { return nil }
        let days = Civil.days(year: year, month: month + 1, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - zone
        return Date(timeIntervalSince1970: Double(seconds))
    }

    private static func offset(_ zone: String) -> Int? {
        if ["GMT", "UT", "UTC", "Z"].contains(zone.uppercased()) {
            return 0
        }
        guard zone.count == 5, let sign = zone.first, sign == "+" || sign == "-",
            let digits = Int(zone.dropFirst())
        else { return nil }
        let seconds = digits / 100 * 3600 + digits % 100 * 60
        return sign == "-" ? -seconds : seconds
    }
}
