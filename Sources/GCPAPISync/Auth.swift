public import Foundation
public import Logging

// The Personal API authenticates in two steps: a long-lived *API key* (created in Garmin
// Connect's settings) is exchanged for a 24-hour *access token* (a JWT), which is sent as
// a bearer token on every data request. There are no refresh tokens; the key is simply
// exchanged again.

/// A bearer token for the data endpoints.
///
/// Its `description` and mirror leave out the token, so it never ends up in logs.
public struct AccessToken: Hashable, Sendable, CustomStringConvertible, CustomReflectable {
    /// The raw token.
    public let value: String
    /// When the token expires.
    public let expiresAt: Date

    /// A token with a known expiry.
    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }

    /// A token whose expiry is read from the JWT `exp` claim.
    ///
    /// The signature is not verified; the claim is only used to schedule refreshes.
    /// Tokens without a readable `exp` are assumed to live for 24 hours from `now`.
    public init(jwt value: String, now: Date = Date()) {
        self.value = value
        expiresAt =
            Self.expiry(of: value) ?? now.addingTimeInterval(Constants.fallbackTokenLifetime)
    }

    /// Whether the token is expired or expires within `margin` seconds of `now`.
    public func expires(within margin: TimeInterval, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) <= margin
    }

    /// The expiry, without the token.
    public var description: String { "AccessToken(expiresAt: \(UTCTimestamp.iso(expiresAt)))" }

    /// The expiry, without the token.
    public var customMirror: Mirror {
        Mirror(self, children: ["expiresAt": expiresAt], displayStyle: .struct)
    }

    private struct Claims: Decodable {
        let exp: Double
    }

    private static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URLDecode(String(parts[1])),
            let claims = try? JSONDecoder().decode(Claims.self, from: payload)
        else { return nil }
        return representable(claims.exp)
    }

    /// Seconds since the epoch as a `Date`, if within the years 1 to 9999.
    static func representable(_ seconds: Double) -> Date? {
        (-62_135_596_800...253_402_300_799).contains(seconds)
            ? Date(timeIntervalSince1970: seconds) : nil
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// Storage for access tokens, keyed by a fingerprint of API key and base URL.
///
/// Implement this to keep tokens in the Keychain, a database, etc.
public protocol TokenCache: Sendable {
    /// The stored token for `key`, or `nil`.
    func load(_ key: String) async -> AccessToken?
    /// Store `token` under `key`.
    func save(_ token: AccessToken, for key: String) async throws
    /// Forget all stored tokens.
    func clear() async throws
}

/// Keeps tokens in memory for the lifetime of the process (the default).
public actor MemoryTokenCache: TokenCache {
    private var tokens: [String: AccessToken] = [:]

    /// An empty cache.
    public init() {}

    /// The stored token for `key`, or `nil`.
    public func load(_ key: String) -> AccessToken? {
        tokens[key]
    }

    /// Store `token` under `key`.
    public func save(_ token: AccessToken, for key: String) {
        tokens[key] = token
    }

    /// Forget all stored tokens.
    public func clear() {
        tokens.removeAll()
    }
}

/// Persists the most recent token in a JSON file readable only by the owner.
///
/// Reusing tokens across processes avoids one key exchange per run, which matters for
/// scripts and command line tools. The default path and format are shared with Garmin's
/// official client and with the Python version of this package.
public struct FileTokenCache: TokenCache, CustomStringConvertible {
    /// The cache file.
    public let url: URL
    private let logger: Logger

    /// A cache in `url`.
    public init(url: URL, logger: Logger = Logger(label: "gcpapi_sync")) {
        self.url = url
        self.logger = logger
    }

    /// A cache in the default location, `~/.config/garmin/connect-personal-api-bearer-token.json`.
    public init(
        environment: ProcessEnvironment = .current, logger: Logger = Logger(label: "gcpapi_sync")
    ) {
        self.init(url: environment.url(for: Constants.defaultTokenCacheFile), logger: logger)
    }

    /// The stored token, if it was issued for `key`.
    public func load(_ key: String) -> AccessToken? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                logger.warning("Cannot read token cache \(url.path)")
            }
            return nil
        }
        warnIfShared(url, "Token cache", logger: logger)
        guard let stored = try? JSONDecoder().decode(StoredToken.self, from: data),
            let expiresAt = AccessToken.representable(stored.expiresAt)
        else {
            logger.warning("Ignoring malformed token cache \(url.path)")
            return nil
        }
        guard stored.fingerprint == key else { return nil }
        return AccessToken(value: stored.accessToken, expiresAt: expiresAt)
    }

    /// Atomically replace the cache file with `token`.
    public func save(_ token: AccessToken, for key: String) throws {
        let stored = StoredToken(
            fingerprint: key, accessToken: token.value,
            expiresAt: token.expiresAt.timeIntervalSince1970
        )
        try PrivateFiles.write(JSONEncoder().encode(stored), to: url, permissions: 0o600)
    }

    /// Delete the cache file.
    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// `FileTokenCache(<path>)`.
    public var description: String { "FileTokenCache(\(url.path))" }
}

/// The token cache file's format, shared with Garmin's own client.
private struct StoredToken: Codable {
    let fingerprint: String
    let accessToken: String
    let expiresAt: Double

    enum CodingKeys: String, CodingKey {
        case fingerprint
        case accessToken = "access_token"
        case expiresAt = "expires_at"
    }
}

/// Where an API key was found.
public struct APIKeySource: Sendable, CustomStringConvertible, CustomReflectable {
    /// The kinds of places a key comes from.
    public enum Origin: String, Sendable {
        /// Passed in by the caller.
        case argument
        /// The `GARMIN_PERSONAL_API_KEY` environment variable.
        case environment
        /// A key file.
        case file
    }

    /// The key itself.
    public let value: String
    /// Where it came from.
    public let origin: Origin
    /// The key file, when ``origin`` is ``Origin/file``.
    public let url: URL?

    /// A short human-readable description, such as `file ~/.config/...`.
    public var description: String {
        switch origin {
        case .argument: "argument"
        case .environment: "environment variable \(Constants.apiKeyEnvironmentVariable)"
        case .file: "file \(url?.path ?? "")"
        }
    }

    /// Origin and path, without the key.
    public var customMirror: Mirror {
        Mirror(self, children: ["origin": origin, "url": url as Any], displayStyle: .struct)
    }
}

/// The fingerprint under which tokens for `apiKey` against `baseURL` are cached.
///
/// Matches Garmin's own client, so a shared ``FileTokenCache`` works for both.
public func tokenCacheKey(baseURL: String, apiKey: String) -> String {
    SHA256.hex(Array("\(baseURL)\u{0}\(apiKey)".utf8))
}

/// Find the Personal API key and report where it came from.
///
/// Sources, in order: the `apiKey` argument, the `keyFile` argument, the
/// `GARMIN_PERSONAL_API_KEY` environment variable, then
/// `~/.config/garmin/connect-personal-api-key`. An explicitly given source that is empty
/// or missing is an error; it never falls through to the next one.
///
/// - Throws: ``ConfigurationError`` if no usable key was found.
public func locateAPIKey(
    apiKey: String? = nil, keyFile: String? = nil,
    environment: ProcessEnvironment = .current, logger: Logger = Logger(label: "gcpapi_sync")
) throws -> APIKeySource {
    if let apiKey {
        return APIKeySource(
            value: try nonEmpty(apiKey, "the apiKey argument"), origin: .argument, url: nil
        )
    }
    if let keyFile {
        let url = environment.url(for: keyFile)
        return APIKeySource(
            value: try readKeyFile(url, explicit: true, logger: logger), origin: .file, url: url
        )
    }
    if let value = environment.variables[Constants.apiKeyEnvironmentVariable] {
        let source = "the \(Constants.apiKeyEnvironmentVariable) environment variable"
        return APIKeySource(value: try nonEmpty(value, source), origin: .environment, url: nil)
    }
    let url = environment.url(for: Constants.defaultAPIKeyFile)
    return APIKeySource(
        value: try readKeyFile(url, explicit: false, logger: logger), origin: .file, url: url
    )
}

/// Find the Personal API key (see ``locateAPIKey(apiKey:keyFile:environment:logger:)``).
///
/// - Throws: ``ConfigurationError`` if no usable key was found.
public func resolveAPIKey(
    apiKey: String? = nil, keyFile: String? = nil,
    environment: ProcessEnvironment = .current, logger: Logger = Logger(label: "gcpapi_sync")
) throws -> String {
    try locateAPIKey(apiKey: apiKey, keyFile: keyFile, environment: environment, logger: logger)
        .value
}

/// Store an API key in a file readable only by the current user and return its URL.
///
/// The default location is where ``resolveAPIKey(apiKey:keyFile:environment:logger:)``
/// (and Garmin's own client) look for it.
///
/// - Throws: ``ConfigurationError`` if the key is empty, ``FileExistsError`` if the file
///   exists and `overwrite` is false.
@discardableResult
public func saveAPIKey(
    _ apiKey: String, to url: URL? = nil, overwrite: Bool = false,
    environment: ProcessEnvironment = .current
) throws -> URL {
    let key = try nonEmpty(apiKey, "the apiKey argument")
    let target = url ?? environment.url(for: Constants.defaultAPIKeyFile)
    if FileManager.default.fileExists(atPath: target.path), !overwrite {
        throw FileExistsError(target)
    }
    try PrivateFiles.write(Data((key + "\n").utf8), to: target, permissions: 0o600)
    return target
}

/// Whether only the owner may access the file at `url` (always true where POSIX
/// permissions do not apply, or when the file does not exist).
public func fileIsPrivate(_ url: URL) -> Bool {
    PrivateFiles.isPrivate(url)
}

private func readKeyFile(_ url: URL, explicit: Bool, logger: Logger) throws -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
        if explicit {
            throw ConfigurationError("API key file \(url.path) does not exist")
        }
        throw ConfigurationError(
            "No Garmin Personal API key found. Run `gcpapi setup`, pass apiKey: ..., set "
                + "\(Constants.apiKeyEnvironmentVariable), or save the key to \(url.path) "
                + "(chmod 600). Create a key in Garmin Connect under Settings > Personal API."
        )
    }
    let value: String
    do {
        value = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw ConfigurationError("Cannot read API key file \(url.path)")
    }
    warnIfShared(url, "API key file", logger: logger)
    return try nonEmpty(value, "API key file \(url.path)")
}

private func nonEmpty(_ value: String, _ source: String) throws -> String {
    let stripped = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stripped.isEmpty else {
        throw ConfigurationError("The API key from \(source) is empty")
    }
    return stripped
}

private func warnIfShared(_ url: URL, _ description: String, logger: Logger) {
    if !PrivateFiles.isPrivate(url) {
        let advice = "restrict it with: chmod 600 \(url.path)"
        logger.warning("\(description) \(url.path) is accessible by other users; \(advice)")
    }
}
