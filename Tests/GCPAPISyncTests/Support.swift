import Foundation
import Testing

@testable import GCPAPISync

// Test doubles: a fake Personal API served through a custom HTTPTransport.

let baseURL = "https://garmin.test"
let tokenPath = "/personalapitoken-service/personal-api/personal-api-key/token"
let testAPIKey = "test-api-key"
/// A policy that retries twice without waiting.
let noWait = RetryConfig.instant

extension RetryConfig {
    /// Two retries without any delay.
    static var instant: Self {
        (try? Self(initialDelay: 0, maxDelay: 0, jitter: 0)) ?? .default
    }
}

/// A temporary directory, removed when the value is released.
final class Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gcpapi-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// An environment without variables whose home directory is inside the scratch area.
    func environment(_ variables: [String: String] = [:]) -> ProcessEnvironment {
        let home = url.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return ProcessEnvironment(variables: variables, homeDirectory: home)
    }

    func file(_ name: String, _ content: String, permissions: Int = 0o600) throws -> URL {
        let target = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: target.path)
        return target
    }
}

/// An unsigned JWT with an `exp` claim (defaults to 24 hours from now).
func makeJWT(
    expiresAt: Date = Date().addingTimeInterval(86_400), subject: String = "test"
) -> String {
    func encode(_ json: String) -> String {
        Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let expiry = Int(expiresAt.timeIntervalSince1970)
    return encode(#"{"alg": "none"}"#) + "."
        + encode(#"{"sub": "\#(subject)", "exp": \#(expiry)}"#) + ".signature"
}

/// The bytes of `Fixtures/<name>.json`.
func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// A zip archive storing `files` uncompressed.
func zipArchive(_ files: [(String, Data)]) -> Data {
    var local = Data()
    var central = Data()
    func uint16(_ value: Int) -> Data { Data([UInt8(value & 0xff), UInt8(value >> 8 & 0xff)]) }
    func uint32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) })
    }
    for (name, content) in files {
        let nameBytes = Data(name.utf8)
        let size = uint32(UInt32(content.count))
        // Version, flags, method, time and date, then CRC, sizes and name length.
        var common = Data()
        for value in [20, 0, 0, 0, 0] {
            common += uint16(value)
        }
        common += uint32(CRC32.checksum([UInt8](content)))
        common += size
        common += size
        common += uint16(nameBytes.count)
        common += uint16(0)
        let offset = UInt32(local.count)
        local += uint32(0x0403_4b50)
        local += common
        local += nameBytes
        local += content
        central += uint32(0x0201_4b50)
        central += uint16(20)
        central += common
        for value in [0, 0, 0] {
            central += uint16(value)
        }
        central += uint32(0)
        central += uint32(offset)
        central += nameBytes
    }
    var end = uint32(0x0605_4b50)
    for value in [0, 0, files.count, files.count] {
        end += uint16(value)
    }
    end += uint32(UInt32(central.count))
    end += uint32(UInt32(local.count))
    end += uint16(0)
    return local + central + end
}

/// A canned response, or a transport failure to throw.
struct Reply: Sendable {
    var status = 200
    var body = Data()
    var headers: [String: String] = [:]
    var failure: TransportError?

    static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> Self
    {
        let body = (try? JSONEncoder().encode(value)) ?? Data()
        return Self(
            status: status, body: body,
            headers: headers.merging(["Content-Type": "application/json"]) { first, _ in first })
    }

    static func text(_ text: String, status: Int = 200) -> Self {
        Self(status: status, body: Data(text.utf8))
    }

    static func fixture(_ name: String) throws -> Self {
        Self(body: try GCPAPISyncTests.fixture(name), headers: ["Content-Type": "application/json"])
    }

    /// A fixture reply for static case tables; a missing fixture yields an empty body.
    static func bundled(_ name: String) -> Self {
        Self(
            body: (try? GCPAPISyncTests.fixture(name)) ?? Data(),
            headers: ["Content-Type": "application/json"])
    }

    static func failing(_ message: String = "simulated failure", timeout: Bool = false) -> Self {
        Self(failure: TransportError(message, isTimeout: timeout))
    }
}

/// A minimal stand-in for the Personal API.
///
/// The token endpoint issues JWTs for `testAPIKey`; data endpoints require one of the
/// issued, unrevoked tokens. Routes answer with queued replies; the last reply of each
/// route repeats.
actor FakeGarmin {
    private(set) var requests: [HTTPRequest] = []
    private(set) var issued: [String] = []
    private var revoked: Set<String> = []
    var tokenLifetime: TimeInterval = 86_400
    private var tokenReplies: [Reply] = []
    private var routes: [String: [Reply]] = [:]
    private var responders: [(String, @Sendable (HTTPRequest) -> Reply)] = []

    func reply(_ path: String, _ replies: Reply...) {
        routes[path] = replies
    }

    func respond(_ prefix: String, with responder: @escaping @Sendable (HTTPRequest) -> Reply) {
        responders.append((prefix, responder))
    }

    func queueTokenReplies(_ replies: Reply...) {
        tokenReplies += replies
    }

    func setTokenLifetime(_ seconds: TimeInterval) {
        tokenLifetime = seconds
    }

    func issue(_ token: String) {
        issued.append(token)
    }

    func revokeAll() {
        revoked.formUnion(issued)
    }

    var dataRequests: [HTTPRequest] { requests.filter { $0.path != tokenPath } }
    var tokenRequests: [HTTPRequest] { requests.filter { $0.path == tokenPath } }

    private static func next(_ queue: inout [Reply]) -> Reply {
        queue.count > 1 ? queue.removeFirst() : queue[0]
    }

    private func respond(_ request: HTTPRequest, _ reply: Reply) throws -> HTTPResponse {
        if let failure = reply.failure {
            throw failure
        }
        return HTTPResponse(
            statusCode: reply.status, body: reply.body, request: request, headers: reply.headers)
    }

    func handle(_ request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        if request.path == tokenPath {
            return try exchange(request)
        }
        return try serve(request)
    }

    private func exchange(_ request: HTTPRequest) throws -> HTTPResponse {
        if !tokenReplies.isEmpty {
            return try respond(request, Self.next(&tokenReplies))
        }
        guard request.header("Authorization") == "ApiKey \(testAPIKey)" else {
            return HTTPResponse(statusCode: 401, body: Data(), request: request)
        }
        let token = makeJWT(
            expiresAt: Date().addingTimeInterval(tokenLifetime), subject: "\(issued.count)")
        issued.append(token)
        return HTTPResponse(
            statusCode: 200, body: Data(token.utf8), request: request,
            headers: ["Content-Type": "text/plain"])
    }

    private func serve(_ request: HTTPRequest) throws -> HTTPResponse {
        let bearer = (request.header("Authorization") ?? "").replacingOccurrences(
            of: "Bearer ", with: "")
        guard issued.contains(bearer), !revoked.contains(bearer) else {
            return HTTPResponse(statusCode: 401, body: Data(), request: request)
        }
        for (prefix, responder) in responders where request.path.hasPrefix(prefix) {
            return try respond(request, responder(request))
        }
        guard var queue = routes[request.path] else {
            return try respond(
                request, .json(["error": .string("no route for \(request.path)")], status: 404))
        }
        let reply = Self.next(&queue)
        routes[request.path] = queue
        return try respond(request, reply)
    }
}

/// Sends every request to a ``FakeGarmin``.
struct FakeTransport: HTTPTransport {
    let fake: FakeGarmin

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await fake.handle(request)
    }
}

/// A client talking to `fake`, isolated from the real environment.
func makeClient(
    _ fake: FakeGarmin,
    apiKey: String? = testAPIKey,
    accessToken: String? = nil,
    tokenCache: (any TokenCache)? = nil,
    retry: RetryConfig = noWait,
    userAgent: String? = nil
) throws -> GarminClient {
    try GarminClient(
        apiKey: apiKey, accessToken: accessToken, tokenCache: tokenCache, baseURL: baseURL,
        retry: retry, userAgent: userAgent, transport: FakeTransport(fake: fake),
        environment: ProcessEnvironment(
            variables: [:], homeDirectory: FileManager.default.temporaryDirectory)
    )
}

extension HTTPRequest {
    /// The query parameters as (name, value) pairs.
    var params: [[String]] { queryItems.map { [$0.name, $0.value] } }

    /// The first value of the query parameter `name`.
    func param(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }
}

/// Decode a JSON value as `T`.
func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
}

/// Decode raw JSON text as `T`.
func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// A UTC date from its parts.
func utc(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
)
    -> Date
{
    let days = Civil.days(year: year, month: month, day: day)
    return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3600 + minute * 60 + second))
}
