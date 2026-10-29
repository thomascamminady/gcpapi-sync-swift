public import Foundation
public import Logging

/// Client for the Garmin Connect Personal API.
///
/// ```swift
/// let garmin = try GarminClient()
/// let sleep = try await garmin.getDailySleep("2026-10-21")
/// let steps = try await garmin.getDailySteps(start: "2026-01-01", end: "2026-10-21")
/// ```
///
/// Every method is `async`. Date ranges longer than an endpoint allows are split into
/// windows that are fetched concurrently (at most ``maxConcurrency`` at a time) and joined
/// in order; activity searches of any size are paged.
public final class GarminClient: Sendable, CustomStringConvertible {
    /// The API host, without a trailing slash.
    public let baseURL: String
    /// The retry policy.
    public let retry: RetryConfig
    /// Maximum parallel requests when a date range is split.
    public let maxConcurrency: Int
    /// The `User-Agent` sent with every request.
    public let userAgent: String
    let transport: any HTTPTransport
    let logger: Logger
    private let tokens: TokenManager

    /// A client.
    ///
    /// - Parameters:
    ///   - apiKey: Personal API key. If omitted, it is read from `keyFile`, the
    ///     `GARMIN_PERSONAL_API_KEY` environment variable, or
    ///     `~/.config/garmin/connect-personal-api-key`, in that order.
    ///   - accessToken: An already issued access token. Without an API key the client
    ///     uses it until it expires.
    ///   - keyFile: File containing the API key (`~` is expanded).
    ///   - tokenCache: Where access tokens are kept. Defaults to memory; use
    ///     ``FileTokenCache`` to reuse tokens across processes, or your own (for example
    ///     the Keychain).
    ///   - baseURL: API host. Defaults to `GARMIN_PERSONAL_API_BASE_URL` or the production
    ///     host.
    ///   - timeout: Request timeout in seconds (for the default transport).
    ///   - retry: Retry policy. `try RetryConfig(maxRetries: 0)` disables retries.
    ///   - userAgent: Override the `User-Agent` header.
    ///   - transport: Bring your own ``HTTPTransport``.
    ///   - maxConcurrency: Maximum parallel requests when a date range is split.
    ///   - environment: Environment variables and home directory to read configuration
    ///     from.
    ///   - logger: Requests are logged at `debug`, retries at `info`, problems with key
    ///     and token files at `warning`. Keys and tokens are never logged.
    /// - Throws: ``ConfigurationError`` if no API key or access token could be found or
    ///   the base URL is invalid, ``InvalidArgumentError`` for a `maxConcurrency` below 1.
    public init(
        apiKey: String? = nil,
        accessToken: String? = nil,
        keyFile: String? = nil,
        tokenCache: (any TokenCache)? = nil,
        baseURL: String? = nil,
        timeout: TimeInterval = 30,
        retry: RetryConfig = .default,
        userAgent: String? = nil,
        transport: (any HTTPTransport)? = nil,
        maxConcurrency: Int = 4,
        environment: ProcessEnvironment = .current,
        logger: Logger = Logger(label: "gcpapi_sync")
    ) throws {
        guard maxConcurrency >= 1 else {
            throw InvalidArgumentError("maxConcurrency must be at least 1")
        }
        var url =
            baseURL ?? environment.variables[Constants.baseURLEnvironmentVariable]
            ?? Constants.defaultBaseURL
        while url.hasSuffix("/") {
            url.removeLast()
        }
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else {
            throw ConfigurationError("baseURL must start with https://, got \"\(url)\"")
        }
        self.baseURL = url
        self.retry = retry
        self.maxConcurrency = maxConcurrency
        self.userAgent = userAgent ?? Self.defaultUserAgent
        self.transport = transport ?? URLSessionTransport(timeout: timeout)
        self.logger = logger
        var initialToken: AccessToken?
        if let accessToken {
            let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ConfigurationError("accessToken is empty") }
            initialToken = AccessToken(jwt: trimmed)
        }
        // With an access token alone the client works until the token expires; it can only
        // renew it when it also has an API key.
        let key: String? =
            accessToken != nil && apiKey == nil && keyFile == nil
            ? nil
            : try resolveAPIKey(
                apiKey: apiKey, keyFile: keyFile, environment: environment, logger: logger)
        tokens = TokenManager(
            apiKey: key, cacheKey: key.map { tokenCacheKey(baseURL: url, apiKey: $0) },
            cache: tokenCache ?? MemoryTokenCache(), initialToken: initialToken
        )
    }

    /// `gcpapi-sync-swift/<version> Swift/<platform>`.
    public static var defaultUserAgent: String {
        #if os(iOS)
            let platform = "iOS"
        #elseif os(macOS)
            let platform = "macOS"
        #elseif os(Linux)
            let platform = "Linux"
        #else
            let platform = "other"
        #endif
        return "gcpapi-sync-swift/\(packageVersion) Swift (\(platform))"
    }

    /// Whether the client can obtain new access tokens (it has an API key).
    public var canRefresh: Bool { tokens.apiKey != nil }

    /// The host and the kind of credentials, never the credentials themselves.
    public var description: String {
        "GarminClient(baseURL: \(baseURL), auth: \(canRefresh ? "apiKey" : "accessToken"))"
    }

    // MARK: - Authentication

    /// A valid access token, exchanging the API key if needed.
    ///
    /// - Parameter forceRefresh: Always exchange the API key for a new token.
    /// - Returns: The token.
    /// - Throws: ``ConfigurationError`` if a new token is needed but there is no API key, or an
    ///   ``APIError`` if the exchange fails.
    public func getAccessToken(forceRefresh: Bool = false) async throws -> AccessToken {
        try await tokens.token(stale: nil, force: forceRefresh) { try await self.exchangeKey() }
    }

    private func exchangeKey() async throws -> AccessToken {
        guard let apiKey = tokens.apiKey else {
            throw ConfigurationError(
                "The access token was rejected or has expired and no API key is configured to "
                    + "obtain a new one. Pass apiKey: ... to let the client renew tokens."
            )
        }
        let headers = [
            "Authorization": "ApiKey \(apiKey)", "Accept": "*/*", "User-Agent": userAgent,
        ]
        let response = try await send("POST", url(Constants.keyExchangePath, []), headers)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw AuthenticationError(
                message: "Garmin rejected the API key (HTTP \(response.statusCode)). It may be "
                    + "expired, deleted or mistyped; create a new one in Garmin Connect under "
                    + "Settings > Personal API.",
                response: response
            )
        }
        if response.isError {
            throw statusError(response)
        }
        let value = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !value.isEmpty else {
            throw ResponseValidationError(
                "The token endpoint returned an empty body", response: response)
        }
        let token = AccessToken(jwt: value)
        logger.debug("Obtained access token valid until \(UTCTimestamp.iso(token.expiresAt))")
        return token
    }

    // MARK: - Transport

    func url(_ path: String, _ query: [QueryItem]) -> URL {
        var text = baseURL + path
        if !query.isEmpty {
            text +=
                "?"
                + query.map { "\(Self.escape($0.name))=\(Self.escape($0.value))" }
                .joined(separator: "&")
        }
        // Every component is percent-encoded above, so the URL is always valid.
        return URL(string: text) ?? URL(fileURLWithPath: "/")
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    private func headers(_ token: String, _ accept: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": accept, "User-Agent": userAgent]
    }

    /// Seconds to wait before retrying, or `nil` to give up. `response` is `nil` when the
    /// attempt failed at the transport level.
    func retryDelay(attempt: Int, response: HTTPResponse?) -> Double? {
        guard attempt < retry.maxRetries else { return nil }
        guard let response else { return retry.backoff(attempt: attempt) }
        guard retry.retryStatuses.contains(response.statusCode) else { return nil }
        guard let retryAfter = RetryAfter.seconds(response.header("Retry-After")) else {
            return retry.backoff(attempt: attempt)
        }
        return retryAfter <= retry.maxRetryAfter ? retryAfter : nil
    }

    private func send(
        _ method: String, _ url: URL, _ headers: [String: String]
    ) async throws
        -> HTTPResponse
    {
        let request = HTTPRequest(method: method, url: url, headers: headers)
        var attempt = 0
        while true {
            let started = ContinuousClock.now
            let delay: Double
            do {
                let response = try await transport.send(request)
                let elapsed = started.duration(to: .now)
                logger.debug("\(method) \(request.path) -> \(response.statusCode) (\(elapsed))")
                guard let wait = retryDelay(attempt: attempt, response: response) else {
                    return response
                }
                delay = wait
                logRetry(attempt, delay, "HTTP \(response.statusCode)")
            } catch let error as TransportError {
                guard let wait = retryDelay(attempt: attempt, response: nil) else {
                    throw APIConnectionError(
                        message: "\(method) \(request.path) failed: \(error.message)",
                        request: request, isTimeout: error.isTimeout
                    )
                }
                delay = wait
                logRetry(attempt, delay, error.message)
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            attempt += 1
        }
    }

    private func logRetry(_ attempt: Int, _ delay: Double, _ reason: String) {
        let seconds = (delay * 10).rounded() / 10
        logger.info(
            "Retrying in \(seconds)s (retry \(attempt + 1) of \(retry.maxRetries)): \(reason)")
    }

    private static let statusHints = [
        400: "Garmin rejected the parameters; it sends no details for most 400s",
        401: "the access token is invalid or expired, or the API key was revoked",
        403: "this resource is not available to the authenticated user",
    ]

    func statusError(_ response: HTTPResponse) -> any APIStatusError {
        let status = response.statusCode
        var message = "\(response.request.method) \(response.request.path) returned HTTP \(status)"
        if let detail = Self.summarize(response) {
            message += ": \(detail)"
        } else if let hint = Self.statusHints[status] {
            message += " (\(hint))"
        }
        switch status {
        case 400: return BadRequestError(message: message, response: response)
        case 401: return AuthenticationError(message: message, response: response)
        case 403: return PermissionDeniedError(message: message, response: response)
        case 404: return NotFoundError(message: message, response: response)
        case 429:
            return RateLimitError(
                message: message, response: response,
                retryAfter: RetryAfter.seconds(response.header("Retry-After"))
            )
        case 500...: return InternalServerError(message: message, response: response)
        default: return UnexpectedStatusError(message: message, response: response)
        }
    }

    private static func summarize(_ response: HTTPResponse, limit: Int = 300) -> String? {
        let body = ErrorBody.decode(response.body)
        switch body {
        case .none, .some(.object([:])), .some(.array([])): return nil
        case .some(.string(let text)): return String(text.prefix(limit))
        default:
            if let summary = ErrorBody(body)?.summary {
                return String(summary.prefix(limit))
            }
            return String(
                response.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
    }

    func request<T>(_ endpoint: Endpoint<T>) async throws -> T {
        let url = url(endpoint.path, endpoint.query)
        let token = try await tokens.token(stale: nil, force: false) {
            try await self.exchangeKey()
        }.value
        var response = try await send("GET", url, headers(token, endpoint.accept))
        if response.statusCode == 401, canRefresh {
            // The token was revoked or expired early: renew it once and retry.
            let renewed = try await tokens.token(stale: token, force: false) {
                try await self.exchangeKey()
            }
            response = try await send("GET", url, headers(renewed.value, endpoint.accept))
        }
        if response.isError {
            throw statusError(response)
        }
        return try endpoint.parse(response)
    }

    /// Fetch a date range in windows of at most `maxDays` days, concurrently, in order.
    func collect<T: Sendable>(
        _ start: some DateLike, _ end: some DateLike, maxDays: Int,
        _ build: (GarminDate, GarminDate) throws -> Endpoint<[T]>
    ) async throws -> [T] {
        let (first, last) = try DateRange.resolve(start, end)
        let endpoints = try DateRange.windows(first, last, maxDays: maxDays).map {
            try build($0.0, $0.1)
        }
        if endpoints.count == 1 {
            return try await request(endpoints[0])
        }
        var results = [[T]](repeating: [], count: endpoints.count)
        try await withThrowingTaskGroup(of: (Int, [T]).self) { group in
            var next = 0
            func start(_ index: Int) {
                let endpoint = endpoints[index]
                group.addTask { (index, try await self.request(endpoint)) }
            }
            while next < min(maxConcurrency, endpoints.count) {
                start(next)
                next += 1
            }
            while let (index, items) = try await group.next() {
                results[index] = items
                if next < endpoints.count {
                    start(next)
                    next += 1
                }
            }
        }
        return results.flatMap(\.self)
    }
}

/// All activities matching a search, fetched lazily page by page (see
/// ``GarminClient/iterActivities(start:pageSize:filters:)``).
public struct ActivitySequence: AsyncSequence, Sendable {
    /// Each element is one activity.
    public typealias Element = SummarizedActivity

    let client: GarminClient
    let start: Int
    let pageSize: Int
    let query: [QueryItem]

    /// Fetches the next page when the current one is used up.
    public struct AsyncIterator: AsyncIteratorProtocol {
        let sequence: ActivitySequence
        var offset: Int
        var buffer: [SummarizedActivity] = []
        var finished = false

        /// The next activity, or `nil` after the last page.
        public mutating func next() async throws -> SummarizedActivity? {
            while buffer.isEmpty {
                guard !finished else { return nil }
                let page = try await sequence.client.request(
                    Endpoints.searchActivities(
                        start: offset, limit: sequence.pageSize, filters: sequence.query)
                )
                finished = page.count < sequence.pageSize
                offset += page.count
                buffer = page.reversed()
            }
            return buffer.popLast()
        }
    }

    /// An iterator starting at the first page.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(sequence: self, offset: start)
    }
}

/// Access tokens: the cache, the initial token, and the one key exchange in flight.
final class TokenManager: Sendable {
    let apiKey: String?
    private let state: State

    init(apiKey: String?, cacheKey: String?, cache: any TokenCache, initialToken: AccessToken?) {
        self.apiKey = apiKey
        state = State(
            canRefresh: apiKey != nil, cacheKey: cacheKey, cache: cache, initialToken: initialToken)
    }

    func token(
        stale: String?, force: Bool, exchange: @escaping @Sendable () async throws -> AccessToken
    ) async throws -> AccessToken {
        try await state.token(stale: stale, force: force, exchange: exchange)
    }

    private actor State {
        let canRefresh: Bool
        let cacheKey: String?
        let cache: any TokenCache
        var initialToken: AccessToken?
        var pending: Task<AccessToken, any Error>?

        init(canRefresh: Bool, cacheKey: String?, cache: any TokenCache, initialToken: AccessToken?)
        {
            self.canRefresh = canRefresh
            self.cacheKey = cacheKey
            self.cache = cache
            self.initialToken = initialToken
        }

        /// A cached token that is neither `stale` (rejected by the server) nor expiring.
        private func usable(stale: String?) async -> AccessToken? {
            var candidates = [initialToken]
            if let cacheKey {
                candidates.insert(await cache.load(cacheKey), at: 0)
            }
            for case let token? in candidates where token.value != stale {
                if !canRefresh || !token.expires(within: Constants.tokenRefreshMargin) {
                    return token
                }
            }
            return nil
        }

        func token(
            stale: String?, force: Bool,
            exchange: @escaping @Sendable () async throws -> AccessToken
        ) async throws -> AccessToken {
            if !force, let token = await usable(stale: stale) {
                return token
            }
            if let pending {
                return try await pending.value
            }
            let task = Task { try await exchange() }
            pending = task
            defer { pending = nil }
            let token = try await task.value
            if let cacheKey {
                try await cache.save(token, for: cacheKey)
            }
            initialToken = nil
            return token
        }
    }
}
