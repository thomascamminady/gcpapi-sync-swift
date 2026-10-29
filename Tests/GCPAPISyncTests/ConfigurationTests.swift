import Foundation
import Testing

@testable import GCPAPISync

@Suite struct ConfigurationTests {
    @Test func missingCredentials() throws {
        let scratch = try Scratch()
        let error = #expect(throws: ConfigurationError.self) {
            try GarminClient(environment: scratch.environment())
        }
        #expect(error?.message.contains("No Garmin Personal API key") == true)
    }

    @Test func keyFromEnvironmentAndFile() throws {
        let scratch = try Scratch()
        #expect(
            try GarminClient(
                environment: scratch.environment(["GARMIN_PERSONAL_API_KEY": "env-key"])
            ).canRefresh)
        let keyFile = try scratch.file("key", "file-key")
        #expect(
            try GarminClient(keyFile: keyFile.path, environment: scratch.environment()).canRefresh)
    }

    @Test func baseURL() throws {
        let scratch = try Scratch()
        let environment = scratch.environment()
        #expect(
            try GarminClient(apiKey: testAPIKey, environment: environment).baseURL
                == "https://personal.connectapi.garmin.com")
        #expect(
            try GarminClient(
                apiKey: testAPIKey, baseURL: "https://example.test//", environment: environment
            ).baseURL
                == "https://example.test")
        let local = scratch.environment(["GARMIN_PERSONAL_API_BASE_URL": "http://localhost:8080"])
        #expect(
            try GarminClient(apiKey: testAPIKey, environment: local).baseURL
                == "http://localhost:8080")
        let error = #expect(throws: ConfigurationError.self) {
            try GarminClient(
                apiKey: testAPIKey, baseURL: "ftp://example.test", environment: environment)
        }
        #expect(error?.message.contains("https://") == true)
    }

    @Test func descriptionNeverShowsSecrets() throws {
        let scratch = try Scratch()
        let client = try GarminClient(apiKey: "super-secret", environment: scratch.environment())
        #expect(
            "\(client)"
                == "GarminClient(baseURL: https://personal.connectapi.garmin.com, auth: apiKey)")
        let token = makeJWT()
        let tokenClient = try GarminClient(accessToken: token, environment: scratch.environment())
        #expect(!"\(tokenClient)".contains(token))
        #expect("\(tokenClient)".contains("auth: accessToken"))
    }

    @Test func emptyAccessTokenIsRejected() throws {
        let error = #expect(throws: ConfigurationError.self) { try GarminClient(accessToken: "  ") }
        #expect(error?.message.contains("empty") == true)
    }

    @Test func accessTokenOnlyClientCannotRefresh() throws {
        #expect(try !GarminClient(accessToken: makeJWT()).canRefresh)
    }

    @Test func maxConcurrencyMustBePositive() throws {
        #expect(throws: InvalidArgumentError.self) {
            try GarminClient(apiKey: testAPIKey, maxConcurrency: 0)
        }
    }

    @Test func userAgent() async throws {
        let fake = FakeGarmin()
        await fake.reply("/x", .json([:]))
        _ = try await makeClient(fake, userAgent: "my-app/1.0").getJSON("/x")
        #expect(Set(await fake.requests.compactMap { $0.header("User-Agent") }) == ["my-app/1.0"])
        #expect(GarminClient.defaultUserAgent.contains(packageVersion))
        #expect(try GarminClient(apiKey: testAPIKey).userAgent == GarminClient.defaultUserAgent)
    }

    @Test func requestsDoNotLeakCredentials() async throws {
        let fake = FakeGarmin()
        await fake.reply("/x", .json([:]))
        _ = try await makeClient(fake).getJSON("/x", query: [QueryItem("q", "a b+c/ä")])
        let request = try #require(await fake.dataRequests.first)
        #expect(request.url.absoluteString == "https://garmin.test/x?q=a%20b%2Bc%2F%C3%A4")
        #expect(request.queryItems == [QueryItem("q", "a b+c/ä")])
        #expect("\(request)" == "GET /x")
        var dumped = ""
        dump(request, to: &dumped)
        #expect(!dumped.contains("Bearer"))
    }
}
