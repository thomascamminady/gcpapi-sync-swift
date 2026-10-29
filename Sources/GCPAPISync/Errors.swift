public import Foundation

// Errors thrown by the client. Every one conforms to ``GarminError``:
//
//     GarminError
//     ├── ConfigurationError            no API key found, conflicting options
//     ├── InvalidArgumentError          malformed dates, reversed ranges, bad options
//     └── APIError                      anything that went wrong talking to Garmin
//         ├── APIConnectionError        network failure (after retries); .isTimeout
//         ├── APIStatusError            non-2xx response (after retries)
//         │   ├── BadRequestError       400
//         │   ├── AuthenticationError   401 (key or token invalid/expired)
//         │   ├── PermissionDeniedError 403
//         │   ├── NotFoundError         404
//         │   ├── RateLimitError        429
//         │   ├── InternalServerError   5xx
//         │   └── UnexpectedStatusError any other status
//         └── ResponseValidationError   2xx response that does not match the models
//
// `GarminError`, `APIError` and `APIStatusError` are protocols, so they can be caught as
// a group (`catch let error as any APIStatusError`) as well as individually.

/// An error thrown by this package.
public protocol GarminError: LocalizedError, CustomStringConvertible {
    /// A description of what went wrong. Never contains keys or tokens.
    var message: String { get }
}

extension GarminError {
    /// The message.
    public var description: String { message }
    /// The message.
    public var errorDescription: String? { message }
}

/// The client is misconfigured, for example no API key could be found.
public struct ConfigurationError: GarminError {
    /// What is wrong.
    public let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// An argument was invalid: a malformed date, a reversed range, an out-of-range option.
///
/// Thrown before any request is made.
public struct InvalidArgumentError: GarminError {
    /// What is wrong.
    public let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// A request to the Garmin API failed.
public protocol APIError: GarminError {
    /// The request that failed, if one was made.
    var request: HTTPRequest? { get }
}

/// The API could not be reached (DNS, TLS, connection reset, timeout, ...).
public struct APIConnectionError: APIError {
    /// What went wrong.
    public let message: String
    /// The request that failed.
    public let request: HTTPRequest?
    /// Whether the request timed out.
    public let isTimeout: Bool
}

/// The JSON error document Garmin returns for some failures.
///
/// Most errors carry an empty body (`{}`); then every field is `nil`.
public struct ErrorBody: Hashable, Sendable {
    /// Error class name, such as `NotAcceptableException`.
    public let error: String?
    /// Human-readable message.
    public let clientMessage: String?
    /// Alternative message field used by some services.
    public let message: String?
    /// Reference to quote when contacting Garmin.
    public let errorID: String?

    /// A one-line description, or `nil` if the body says nothing useful.
    public var summary: String? {
        guard let text = clientMessage ?? message ?? error else { return nil }
        return errorID.map { "\(text) (errorId \($0))" } ?? text
    }

    /// Interpret a decoded body as Garmin's error document, if it is a JSON object whose
    /// known fields are strings.
    init?(_ body: JSONValue?) {
        guard case .object(let members) = body else { return nil }
        var fields: [String: String] = [:]
        for key in ["error", "clientMessage", "message", "errorId"] {
            switch members[key] {
            case .none, .some(.null): continue
            case .some(.string(let text)): fields[key] = text
            default: return nil
            }
        }
        error = fields["error"]
        clientMessage = fields["clientMessage"]
        message = fields["message"]
        errorID = fields["errorId"]
    }

    /// Decode a response body as JSON, falling back to its text (`nil` if it is empty).
    static func decode(_ data: Data) -> JSONValue? {
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .string(text)
    }
}

/// Garmin answered with a non-success HTTP status.
public protocol APIStatusError: APIError {
    /// The response.
    var response: HTTPResponse { get }
}

extension APIStatusError {
    /// The request that failed.
    public var request: HTTPRequest? { response.request }
    /// The HTTP status code.
    public var statusCode: Int { response.statusCode }
    /// The decoded JSON body, the raw text if it is not JSON, or `nil` if it is empty.
    public var body: JSONValue? { ErrorBody.decode(response.body) }
    /// The body parsed as Garmin's error document, if it is one.
    public var errorBody: ErrorBody? { ErrorBody(body) }
    /// Garmin's error reference (`errorId`), if the body contains one.
    public var errorID: String? { errorBody?.errorID }
}

/// HTTP 400: malformed or unsupported parameters.
public struct BadRequestError: APIStatusError {
    /// What went wrong.
    public let message: String
    /// The response.
    public let response: HTTPResponse
}

/// HTTP 401: the API key or access token is invalid, expired or revoked.
public struct AuthenticationError: APIStatusError {
    /// What went wrong.
    public let message: String
    /// The response.
    public let response: HTTPResponse
}

/// HTTP 403: the authenticated user may not access this resource.
public struct PermissionDeniedError: APIStatusError {
    /// What went wrong.
    public let message: String
    /// The response.
    public let response: HTTPResponse
}

/// HTTP 404: the resource does not exist.
public struct NotFoundError: APIStatusError {
    /// What went wrong.
    public let message: String
    /// The response.
    public let response: HTTPResponse
}

/// HTTP 429: too many requests.
public struct RateLimitError: APIStatusError {
    /// What went wrong.
    public let message: String
    /// The response.
    public let response: HTTPResponse
    /// Seconds the server asked to wait, if it said so.
    public let retryAfter: Double?
}

/// HTTP 5xx: Garmin failed to handle the request.
public struct InternalServerError: APIStatusError {
    /// What went wrong.
    public let message: String
    /// The response.
    public let response: HTTPResponse
}

/// Any other non-success HTTP status.
public struct UnexpectedStatusError: APIStatusError {
    /// What went wrong.
    public let message: String
    /// The response.
    public let response: HTTPResponse
}

/// A successful response did not match the expected model.
///
/// The undecoded payload is kept in ``raw`` so callers can still get at the data.
public struct ResponseValidationError: APIError {
    /// What went wrong.
    public let message: String
    /// The response.
    public let response: HTTPResponse
    /// A description of the underlying decoding failure, if any.
    public let validationError: String?

    init(_ message: String, response: HTTPResponse, validationError: String? = nil) {
        self.message = message
        self.response = response
        self.validationError = validationError
    }

    /// The request that was answered.
    public var request: HTTPRequest? { response.request }
    /// The response body.
    public var raw: Data { response.body }
}
