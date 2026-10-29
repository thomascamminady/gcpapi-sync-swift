import Foundation
import Logging
import Testing

@testable import GCPAPISync

/// Collects log messages, to check warnings.
final class LogRecorder: Sendable {
    private let messages = Messages()

    actor Messages {
        var all: [String] = []
        func append(_ message: String) { all.append(message) }
    }

    var logger: Logger {
        Logger(label: "test") { _ in Handler(recorder: self) }
    }

    func text() async -> String { await messages.all.joined(separator: "\n") }

    func record(_ message: String) {
        let messages = self.messages
        Task { await messages.append(message) }
    }

    struct Handler: LogHandler {
        let recorder: LogRecorder
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            recorder.record("\(event.level): \(event.message)")
        }
    }

    /// Wait for queued messages to arrive.
    func settled() async -> String {
        for _ in 0..<50 where await messages.all.isEmpty {
            await Task.yield()
        }
        return await text()
    }
}

private let defaultKeyPath = ".config/garmin/connect-personal-api-key"

private func writeDefaultKey(
    _ environment: ProcessEnvironment, _ value: String = "file-key\n"
) throws -> URL {
    let url = environment.homeDirectory.appendingPathComponent(defaultKeyPath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
}

@Suite struct AccessTokenTests {
    @Test func readsTheJWTExpiry() {
        let expiry = utc(2026, 10, 23, 6)
        let token = AccessToken(jwt: makeJWT(expiresAt: expiry))
        #expect(token.expiresAt == expiry)
        #expect(!"\(token)".contains("eyJ"))
        #expect(!String(reflecting: token).contains("eyJ"))
        var dumped = ""
        dump(token, to: &dumped)
        #expect(!dumped.contains("eyJ"))
    }

    @Test(arguments: [
        "opaque-token", "a.b.c", "a.bm90LWpzb24.c", "a.e30.c", "a.eyJleHAiOjFlMzAwfQ.c",
    ])
    func withoutReadableExpiryLives24Hours(value: String) {
        let now = utc(2026, 10, 22)
        #expect(AccessToken(jwt: value, now: now).expiresAt == now.addingTimeInterval(86_400))
    }

    @Test func expiresWithin() {
        let now = utc(2026, 10, 22, 12)
        let token = AccessToken(value: "t", expiresAt: now.addingTimeInterval(600))
        #expect(!token.expires(within: 300, now: now))
        #expect(token.expires(within: 600, now: now))
        #expect(
            AccessToken(value: "t", expiresAt: Date().addingTimeInterval(-1)).expires(within: 0))
    }

    @Test func cacheKeyMatchesGarminsClient() {
        // sha256(b"https://host\0key"), as computed by Python's hashlib.
        #expect(
            tokenCacheKey(baseURL: "https://host", apiKey: "key")
                == "4204f00bb1b8cf500e53470345f961acdea499980ed9dfbc380a083cd349e5ca")
    }
}

@Suite struct KeyDiscoveryTests {
    @Test func explicitKeyWins() throws {
        let scratch = try Scratch()
        let environment = scratch.environment(["GARMIN_PERSONAL_API_KEY": "env"])
        _ = try writeDefaultKey(environment)
        let keyFile = try scratch.file("key", "explicit-file")

        #expect(
            try resolveAPIKey(
                apiKey: "  explicit \n", keyFile: keyFile.path, environment: environment)
                == "explicit")
        #expect(
            try resolveAPIKey(keyFile: keyFile.path, environment: environment) == "explicit-file")
        #expect(try resolveAPIKey(environment: environment) == "env")
        #expect(try resolveAPIKey(environment: scratch.environment()) == "file-key")
    }

    @Test func environmentVariableIsRead() throws {
        let scratch = try Scratch()
        let source = try locateAPIKey(
            environment: scratch.environment(["GARMIN_PERSONAL_API_KEY": "from-env"]))
        #expect(source.value == "from-env")
        #expect(source.origin == .environment)
        #expect(source.description == "environment variable GARMIN_PERSONAL_API_KEY")
        var dumped = ""
        dump(source, to: &dumped)
        #expect(!dumped.contains("from-env"))
    }

    @Test func describesFilesAndArguments() throws {
        let scratch = try Scratch()
        let environment = scratch.environment()
        let url = try writeDefaultKey(environment)
        #expect(try locateAPIKey(environment: environment).description == "file \(url.path)")
        #expect(try locateAPIKey(apiKey: "k", environment: environment).description == "argument")
    }

    @Test func missingKeyExplainsHowToConfigureOne() throws {
        let scratch = try Scratch()
        let error = #expect(throws: ConfigurationError.self) {
            try resolveAPIKey(environment: scratch.environment())
        }
        #expect(error?.message.contains("gcpapi setup") == true)
    }

    @Test(arguments: ["", "   ", "\n"])
    func emptyKeysAreRejected(value: String) throws {
        let scratch = try Scratch()
        let keyFile = try scratch.file("key", value)
        for attempt in [
            { try resolveAPIKey(apiKey: value, environment: scratch.environment()) },
            { try resolveAPIKey(keyFile: keyFile.path, environment: scratch.environment()) },
            {
                try resolveAPIKey(
                    environment: scratch.environment(["GARMIN_PERSONAL_API_KEY": value]))
            },
        ] {
            let error = #expect(throws: ConfigurationError.self) { try attempt() }
            #expect(error?.message.contains("empty") == true)
        }
    }

    @Test func explicitMissingKeyFileDoesNotFallBack() throws {
        let scratch = try Scratch()
        let error = #expect(throws: ConfigurationError.self) {
            try resolveAPIKey(
                keyFile: scratch.url.appendingPathComponent("missing").path,
                environment: scratch.environment(["GARMIN_PERSONAL_API_KEY": "env"]))
        }
        #expect(error?.message.contains("does not exist") == true)
    }

    @Test func tildeIsExpanded() throws {
        let scratch = try Scratch()
        let environment = scratch.environment()
        _ = try writeDefaultKey(environment, "tilde-key")
        #expect(
            try resolveAPIKey(keyFile: "~/\(defaultKeyPath)", environment: environment)
                == "tilde-key")
        #expect(environment.url(for: "~") == environment.homeDirectory)
        #expect(environment.url(for: "/abs/path").path == "/abs/path")
    }

    @Test func unreadableKeyFile() throws {
        let scratch = try Scratch()
        let error = #expect(throws: ConfigurationError.self) {
            try resolveAPIKey(keyFile: scratch.url.path, environment: scratch.environment())
        }
        #expect(error?.message.contains("Cannot read") == true)
    }

    @Test func sharedKeyFileWarns() async throws {
        let scratch = try Scratch()
        let environment = scratch.environment()
        let url = try writeDefaultKey(environment)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let recorder = LogRecorder()
        _ = try resolveAPIKey(environment: environment, logger: recorder.logger)
        #expect(await recorder.settled().contains("chmod 600"))
        #expect(!fileIsPrivate(url))
    }

    @Test func fileIsPrivateToleratesMissingFiles() throws {
        let scratch = try Scratch()
        #expect(fileIsPrivate(scratch.url.appendingPathComponent("missing")))
    }
}

@Suite struct SavingKeysTests {
    @Test func saveAPIKey() throws {
        let scratch = try Scratch()
        let target = scratch.url.appendingPathComponent("nested/key")
        #expect(try GCPAPISync.saveAPIKey(" secret \n", to: target) == target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "secret\n")
        let mode =
            try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(throws: FileExistsError.self) { try GCPAPISync.saveAPIKey("other", to: target) }
        try GCPAPISync.saveAPIKey("other", to: target, overwrite: true)
        #expect(
            try resolveAPIKey(keyFile: target.path, environment: scratch.environment()) == "other")
        #expect(throws: ConfigurationError.self) {
            try GCPAPISync.saveAPIKey("  ", to: scratch.url.appendingPathComponent("blank"))
        }
    }

    @Test func savesToTheDefaultLocation() throws {
        let scratch = try Scratch()
        let environment = scratch.environment()
        let saved = try GCPAPISync.saveAPIKey("k", environment: environment)
        #expect(saved == environment.homeDirectory.appendingPathComponent(defaultKeyPath))
    }

    @Test func failedWritesCleanUp() throws {
        let scratch = try Scratch()
        // Renaming a file over a non-empty directory fails.
        let target = scratch.url.appendingPathComponent("out/key")
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("child"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try GCPAPISync.saveAPIKey("secret", to: target, overwrite: true)
        }
        let left = try FileManager.default.contentsOfDirectory(
            atPath: target.deletingLastPathComponent().path)
        #expect(left == ["key"])
    }
}

@Suite struct TokenCacheTests {
    @Test func memoryCache() async {
        let cache = MemoryTokenCache()
        let token = AccessToken(value: "value", expiresAt: utc(2030, 1, 1))
        #expect(await cache.load("k") == nil)
        await cache.save(token, for: "k")
        #expect(await cache.load("k") == token)
        await cache.clear()
        #expect(await cache.load("k") == nil)
    }

    @Test func fileCacheRoundTrip() throws {
        let scratch = try Scratch()
        let cache = FileTokenCache(url: scratch.url.appendingPathComponent("dir/token.json"))
        let token = AccessToken(value: "value", expiresAt: utc(2030, 1, 1, 12, 30))

        #expect(cache.load("k") == nil)
        try cache.save(token, for: "k")
        #expect(cache.load("k") == token)
        #expect(cache.load("other key") == nil)
        #expect(FileTokenCache(url: cache.url).load("k") == token)
        let mode =
            try FileManager.default.attributesOfItem(atPath: cache.url.path)[.posixPermissions]
            as? Int
        #expect(mode == 0o600)
        #expect(cache.description == "FileTokenCache(\(cache.url.path))")
        try cache.clear()
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))
        try cache.clear()
    }

    @Test func defaultLocation() throws {
        let scratch = try Scratch()
        let environment = scratch.environment()
        #expect(
            FileTokenCache(environment: environment).url
                == environment.homeDirectory.appendingPathComponent(
                    ".config/garmin/connect-personal-api-bearer-token.json"))
    }

    @Test func fileCacheReadsGarminsFormat() throws {
        let scratch = try Scratch()
        let url = try scratch.file(
            "token.json",
            #"{"fingerprint": "k", "access_token": "abc", "expires_at": 1893456000.0}"#)
        #expect(
            FileTokenCache(url: url).load("k")
                == AccessToken(value: "abc", expiresAt: utc(2030, 1, 1)))
    }

    @Test(arguments: [
        "not json", "{}", #"{"fingerprint": "k"}"#,
        #"{"fingerprint": "k", "access_token": "a", "expires_at": 1e300}"#,
    ])
    func fileCacheIgnoresMalformedFiles(content: String) async throws {
        let scratch = try Scratch()
        let url = try scratch.file("token.json", content)
        let recorder = LogRecorder()
        #expect(FileTokenCache(url: url, logger: recorder.logger).load("k") == nil)
        #expect(await recorder.settled().contains("malformed"))
    }

    @Test func fileCacheIgnoresUnreadablePaths() async throws {
        let scratch = try Scratch()
        let recorder = LogRecorder()
        #expect(FileTokenCache(url: scratch.url, logger: recorder.logger).load("k") == nil)
        #expect(await recorder.settled().contains("Cannot read token cache"))
    }

    @Test func sharedCacheFileWarns() async throws {
        let scratch = try Scratch()
        let url = try scratch.file(
            "token.json",
            #"{"fingerprint": "k", "access_token": "abc", "expires_at": 1893456000.0}"#,
            permissions: 0o644)
        let recorder = LogRecorder()
        _ = FileTokenCache(url: url, logger: recorder.logger).load("k")
        #expect(await recorder.settled().contains("chmod 600"))
    }
}
