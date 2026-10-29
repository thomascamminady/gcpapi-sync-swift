import Foundation
import Testing

@testable import GCPAPISync

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Answers by path, without any shared state: `/ok`, `/redirect`, `/timeout`, `/offline`.
final class StubProtocol: URLProtocol {
    override static func canInit(with _: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        switch url.path {
        case "/redirect":
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": "https://elsewhere.test/ok"])
            if let response, let target = URL(string: "https://elsewhere.test/ok") {
                client.urlProtocol(
                    self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client.urlProtocolDidFinishLoading(self)
        case "/timeout":
            client.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case "/offline":
            client.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        default:
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/plain", "X-Agent": agent])
            if let response {
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client.urlProtocol(self, didLoad: Data("method=\(request.httpMethod ?? "")".utf8))
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

#if canImport(FoundationNetworking)
    private let canStubRedirects = false
#else
    private let canStubRedirects = true
#endif

private func transport() -> URLSessionTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSessionTransport(configuration: configuration)
}

private func request(_ path: String) throws -> HTTPRequest {
    HTTPRequest(
        method: "POST", url: try #require(URL(string: "https://stub.test\(path)")),
        headers: ["User-Agent": "tests"])
}

@Suite struct TransportTests {
    @Test func sendsTheRequestAndReturnsTheResponse() async throws {
        let response = try await transport().send(try request("/ok"))
        #expect(response.statusCode == 200)
        #expect(response.text == "method=POST")
        #expect(response.header("x-agent") == "tests")
        #expect(response.description == "POST /ok -> 200")
        #expect(response.request.header("user-agent") == "tests")
    }

    // Linux's Foundation cannot simulate redirects from a URLProtocol stub; real redirects
    // there still reach the session delegate.
    @Test(.enabled(if: canStubRedirects))
    func redirectsAreNotFollowed() async throws {
        let response = try await transport().send(try request("/redirect"))
        #expect(response.statusCode == 302)
        #expect(response.request.url.host == "stub.test")
    }

    @Test func transportFailuresBecomeTransportErrors() async {
        let timeout = await capture(TransportError.self) {
            try await transport().send(try request("/timeout"))
        }
        #expect(timeout?.isTimeout == true)
        let offline = await capture(TransportError.self) {
            try await transport().send(try request("/offline"))
        }
        #expect(offline?.isTimeout == false)
    }

    @Test func callerOwnedSessions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionTransport(session: session)
        let response = try await transport.send(try request("/ok"))
        #expect(response.statusCode == 200)
        #expect(transport.session === session)
        #expect(transport.timeout == nil)
    }

    @Test func defaultTransportsShareOneSession() throws {
        // Sessions are never torn down: on Linux that can crash with open connections.
        let quick = URLSessionTransport(timeout: 5)
        let patient = URLSessionTransport()
        #expect(quick.session === patient.session)
        #expect(patient.timeout == 30)
        let built = quick.urlRequest(for: try request("/ok"))
        #expect(built.timeoutInterval == 5)
        #expect(built.httpMethod == "POST")
        #expect(built.value(forHTTPHeaderField: "User-Agent") == "tests")
        #expect(transport().urlRequest(for: try request("/ok")).timeoutInterval == 60)
    }

    @Test func queryItemsWithoutValues() throws {
        let bare = HTTPRequest(
            method: "GET", url: try #require(URL(string: "https://stub.test/x?flag")), headers: [:])
        #expect(bare.queryItems == [QueryItem("flag", "")])
    }
}
