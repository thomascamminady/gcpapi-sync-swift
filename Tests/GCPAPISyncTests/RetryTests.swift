import Foundation
import Testing

@testable import GCPAPISync

@Suite struct RetryTests {
    @Test func backoffDoublesAndIsCapped() throws {
        let config = try RetryConfig(initialDelay: 0.5, maxDelay: 3, jitter: 0)
        #expect((0..<5).map { config.backoff(attempt: $0) } == [0.5, 1.0, 2.0, 3.0, 3.0])
    }

    @Test func jitterStaysWithinBounds() throws {
        let config = try RetryConfig(initialDelay: 1, maxDelay: 10, jitter: 0.25)
        let delays = Set((0..<200).map { _ in config.backoff(attempt: 0) })
        #expect(delays.allSatisfy { (0.75...1.25).contains($0) })
        #expect(delays.count > 1)
    }

    @Test(
        arguments: [
            { try RetryConfig(maxRetries: -1) },
            { try RetryConfig(initialDelay: -1) },
            { try RetryConfig(maxDelay: -1) },
            { try RetryConfig(maxRetryAfter: -1) },
            { try RetryConfig(jitter: 1.5) },
            { try RetryConfig(jitter: -0.1) },
        ] as [@Sendable () throws -> RetryConfig])
    func invalidConfiguration(make: @Sendable () throws -> RetryConfig) {
        let error = #expect(throws: InvalidArgumentError.self) { try make() }
        #expect(
            error.map { $0.message.contains(">= 0") || $0.message.contains("between 0 and 1") }
                == true)
    }

    @Test func defaultsRetryTransientStatusesOnly() {
        let statuses = RetryConfig.default.retryStatuses
        #expect(Set([429, 500, 502, 503, 504]).isSubset(of: statuses))
        #expect(statuses.isDisjoint(with: [400, 401, 403, 404]))
        #expect(RetryConfig.default == (try? RetryConfig()))
    }

    @Test(
        arguments: [
            (nil, nil), ("5", 5.0), (" 2.5 ", 2.5), ("-3", 0.0), ("not a date", nil), ("inf", nil),
            ("Thu, 22 Oct 2026 06:00:30 GMT", 30.0), ("Thu, 22 Oct 2026 05:00:00 GMT", 0.0),
            ("Thu, 22 Oct 2026 06:00:30 -0000", 30.0), ("22 Oct 2026 08:00:30 +0200", 30.0),
            ("Thu, 22 Oct 2026 06:01 UT", 60.0), ("Thu, 22 Foo 2026 06:00:30 GMT", nil),
            ("Thu, 22 Oct 2026 06:00:30 CEST", nil), ("Thu, 22 Oct 2026 25:00:30 GMT", nil),
            ("Thu, 22 Oct 2026 06:xx:30 GMT", nil),
        ] as [(String?, Double?)])
    func parseRetryAfter(header: String?, expected: Double?) {
        #expect(RetryAfter.seconds(header, now: utc(2026, 10, 22, 6)) == expected)
    }

    @Test func retryAfterDefaultsToTheCurrentTime() {
        #expect(RetryAfter.seconds("Mon, 01 Jan 2001 00:00:00 GMT") == 0)
    }
}
