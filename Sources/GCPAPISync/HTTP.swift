public import Foundation

#if canImport(FoundationNetworking)
    public import FoundationNetworking
#endif

/// A query parameter. Names may repeat to send a parameter several times.
public struct QueryItem: Hashable, Sendable {
    /// The parameter name.
    public let name: String
    /// The parameter value.
    public let value: String

    /// A parameter.
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// An HTTP request as sent to a ``HTTPTransport``.
///
/// Its `description` and mirror leave out the headers, which carry credentials.
public struct HTTPRequest: Sendable, CustomStringConvertible, CustomReflectable {
    /// `GET` or `POST`.
    public let method: String
    /// The full URL, query included.
    public let url: URL
    /// The request headers, including `Authorization`.
    public let headers: [String: String]

    /// A request.
    public init(method: String, url: URL, headers: [String: String]) {
        self.method = method
        self.url = url
        self.headers = headers
    }

    /// The URL's path.
    public var path: String { url.path }

    /// The query parameters, in order.
    public var queryItems: [QueryItem] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.map { QueryItem($0.name, $0.value ?? "") }
    }

    /// The value of a header, matched case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// `METHOD /path`.
    public var description: String { "\(method) \(path)" }

    /// Method and URL only.
    public var customMirror: Mirror {
        Mirror(self, children: ["method": method, "url": url], displayStyle: .struct)
    }
}

/// An HTTP response.
public struct HTTPResponse: Sendable, CustomStringConvertible {
    /// The status code.
    public let statusCode: Int
    /// The response headers.
    public let headers: [String: String]
    /// The body.
    public let body: Data
    /// The request this response answers.
    public let request: HTTPRequest

    /// A response.
    public init(
        statusCode: Int, body: Data, request: HTTPRequest, headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.request = request
    }

    /// Whether the status is 400 or higher.
    public var isError: Bool { statusCode >= 400 }

    /// The body decoded as UTF-8.
    public var text: String { String(decoding: body, as: UTF8.self) }

    /// The value of a header, matched case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// `METHOD /path -> status`.
    public var description: String { "\(request) -> \(statusCode)" }
}

/// A transport-level failure: the request could not be sent or no response arrived.
///
/// Custom ``HTTPTransport``s throw this for failures worth retrying; the client turns it
/// into an ``APIConnectionError`` once retries are exhausted. Any other error a
/// transport throws (such as `CancellationError`) is passed through unchanged.
public struct TransportError: Error, Sendable {
    /// What went wrong.
    public let message: String
    /// Whether the request timed out.
    public let isTimeout: Bool

    /// A transport failure.
    public init(_ message: String, isTimeout: Bool = false) {
        self.message = message
        self.isTimeout = isTimeout
    }
}

/// Sends HTTP requests. ``URLSessionTransport`` is the default; tests and apps can
/// provide their own (for example to add a proxy or record traffic).
public protocol HTTPTransport: Sendable {
    /// Send `request` and return the response, whatever its status.
    ///
    /// - Throws: ``TransportError`` when no response could be obtained.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The default transport, built on `URLSession`.
///
/// Redirects are not followed, so credentials are never sent to another host.
public final class URLSessionTransport: HTTPTransport {
    /// The session of every transport made with ``init(timeout:)``: ephemeral (no cookies, no
    /// cache), never following redirects, and never torn down. Sessions are meant to last as
    /// long as the process; on Linux, releasing one that still holds open connections can crash
    /// (swiftlang/swift-corelibs-foundation#5203).
    private static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(
            configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }()

    let session: URLSession
    /// The timeout of every request, or `nil` for the session's own.
    let timeout: TimeInterval?
    private let ownsSession: Bool

    /// A transport on the shared session.
    ///
    /// - Parameter timeout: Seconds to wait for a response before failing.
    public init(timeout: TimeInterval = 30) {
        session = Self.shared
        self.timeout = timeout
        ownsSession = false
    }

    /// A transport with its own session using `configuration`, never following redirects.
    /// For tests, whose stubbed sessions open no connections.
    init(configuration: URLSessionConfiguration) {
        session = URLSession(
            configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil
        )
        timeout = nil
        ownsSession = true
    }

    /// A transport using `session`, which the caller configures and invalidates.
    ///
    /// Such a session follows redirects unless its delegate prevents it.
    public init(session: URLSession) {
        self.session = session
        timeout = nil
        ownsSession = false
    }

    deinit {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    /// The `URLRequest` for `request`. A timeout set here takes precedence over the
    /// session's, on Apple platforms and on Linux alike.
    func urlRequest(for request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if let timeout {
            urlRequest.timeoutInterval = timeout
        }
        return urlRequest
    }

    /// Send `request` with `URLSession`.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest(for: request))
        } catch let error as URLError {
            throw TransportError(error.localizedDescription, isTimeout: error.code == .timedOut)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TransportError("\(request) did not return an HTTP response")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }
        return HTTPResponse(
            statusCode: http.statusCode, body: data, request: request, headers: headers)
    }
}

/// Stops `URLSession` from following redirects.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
