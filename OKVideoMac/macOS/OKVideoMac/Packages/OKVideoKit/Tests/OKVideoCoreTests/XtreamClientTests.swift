import XCTest
@testable import OKVideoCore

final class XtreamClientTests: XCTestCase {
    func testCatalogUsesAdjustableEarlyLimitWithoutChangingMetadataRequests() async throws {
        let recorder = XtreamRecordingHTTPClient()
        let client = try makeClient(
            httpClient: recorder,
            catalogPolicy: XtreamCatalogResponsePolicy(maximumResponseBytes: 123_456)
        )

        _ = try await client.vodStreams(categoryID: "42")
        _ = try await client.vodInfo(streamID: "1001")

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].maximumResponseBytes, 123_456)
        XCTAssertEqual(requests[0].earlyResponseLimitBytes, 123_456)
        XCTAssertEqual(requests[0].redirectPolicy, .sameOriginNoDowngrade)
        XCTAssertEqual(requests[0].headers["User-Agent"], "OKVideoMac/Test")
        XCTAssertEqual(
            queryValue("category_id", in: requests[0].url),
            "42"
        )
        XCTAssertEqual(requests[1].maximumResponseBytes, 8 * 1_024 * 1_024)
        XCTAssertNil(requests[1].earlyResponseLimitBytes)
        XCTAssertEqual(queryValue("vod_id", in: requests[1].url), "1001")
    }

    func testInitialCatalogLimitIsCentralizedAndDocumentedAsPolicy() {
        XCTAssertEqual(
            XtreamCatalogResponsePolicy.initialSafetyDefault.maximumResponseBytes,
            64 * 1_024 * 1_024
        )
    }

    func testAuthenticationMapsActiveAccountAndRejectsExpiredAccount() async throws {
        let active = XtreamRecordingHTTPClient(
            responseData: try fixture("xtream-auth-success")
        )
        let activeClient = try makeClient(httpClient: active)

        let account = try await activeClient.authenticate()

        XCTAssertEqual(account.status, "Active")
        XCTAssertEqual(account.maxConnections, 3)
        XCTAssertEqual(account.allowedOutputFormats, ["m3u8", "ts"])

        let expired = XtreamRecordingHTTPClient(
            responseData: try fixture("xtream-auth-expired")
        )
        let expiredClient = try makeClient(httpClient: expired)
        do {
            _ = try await expiredClient.authenticate()
            XCTFail("Expected expired account rejection")
        } catch {
            XCTAssertEqual(
                error as? XtreamClientError,
                .authenticationRejected(status: "Expired")
            )
        }
    }

    func testAuthenticationAcceptsStandardAndCompatibleActiveAccounts() async throws {
        let standard = try await authenticate(
            #"{"user_info":{"auth":1,"status":"Active"}}"#
        )
        let compatible = try await authenticate(
            #"{"user_info":{"status":"Active"}}"#
        )
        let normalized = try await authenticate(
            #"{"user_info":{"status":" active "}}"#
        )

        XCTAssertEqual(standard.status, "Active")
        XCTAssertEqual(compatible.status, "Active")
        XCTAssertEqual(normalized.status, " active ")
    }

    func testAuthenticationRejectsActiveStatusWithPastExpiration() async {
        let client: XtreamClient
        do {
            client = try makeClient(
                httpClient: XtreamRecordingHTTPClient(
                    responseData: Data(
                        #"{"user_info":{"auth":1,"status":"Active","exp_date":"1700000000"}}"#.utf8
                    )
                )
            )
        } catch {
            XCTFail("Unable to construct client: \(error)")
            return
        }

        do {
            _ = try await client.authenticate(
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            XCTFail("Expected an Active account with a past exp_date to be rejected")
        } catch {
            XCTAssertEqual(
                error as? XtreamClientError,
                .accountUnavailable(status: "Expired")
            )
        }
    }

    func testAuthenticationRejectsExplicitDenialEvenWhenStatusIsActive() async {
        let error = await authenticationError(
            #"{"user_info":{"auth":0,"status":"Active"}}"#
        )

        XCTAssertEqual(
            error,
            .authenticationRejected(status: "Active")
        )
        XCTAssertEqual(
            error?.localizedDescription,
            "The Xtream server rejected this account."
        )
    }

    func testAuthenticationRejectsUnavailableStatusesWithOrWithoutAuth() async {
        let cases: [(String, String)] = [
            (#"{"user_info":{"auth":1,"status":"Expired"}}"#, "Expired"),
            (#"{"user_info":{"status":"Expired"}}"#, "Expired"),
            (#"{"user_info":{"status":"Banned"}}"#, "Banned"),
            (#"{"user_info":{"status":"Disabled"}}"#, "Disabled"),
            (#"{"user_info":{"status":"Disabled/Expired"}}"#, "Disabled/Expired")
        ]

        for (json, status) in cases {
            let error = await authenticationError(json)
            XCTAssertEqual(
                error,
                .accountUnavailable(status: status),
                "Expected unavailable account status for \(status)"
            )
        }
    }

    func testAuthenticationFailsClosedForUnknownOrMissingStatus() async {
        let unknown = await authenticationError(
            #"{"user_info":{"auth":1,"status":"Paused"}}"#
        )
        let missing = await authenticationError(
            #"{"user_info":{"auth":1}}"#
        )

        XCTAssertEqual(
            unknown,
            .unsupportedAccountStatus(status: "Paused")
        )
        XCTAssertEqual(missing, .invalidAuthenticationResponse)
    }

    func testPerClientConcurrencyLimitCapsParallelCatalogRequests() async throws {
        let probe = XtreamConcurrencyProbeHTTPClient()
        let client = try makeClient(httpClient: probe)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await client.vodCategories()
                }
            }
            try await group.waitForAll()
        }

        let maximumActiveRequests = await probe.maximumActiveRequests
        let requestCount = await probe.requestCount
        XCTAssertEqual(maximumActiveRequests, 2)
        XCTAssertEqual(requestCount, 8)
    }

    func testPlaybackURLIsCreatedOnlyOnDemand() throws {
        let client = try makeClient(httpClient: XtreamRecordingHTTPClient())

        let url = try client.playbackURL(
            kind: .movie,
            remoteID: "1001",
            containerExtension: "mkv"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.invalid/movie/fixture-user/test/1001.mkv"
        )
    }

    private func makeClient(
        httpClient: HTTPClient,
        catalogPolicy: XtreamCatalogResponsePolicy = .initialSafetyDefault
    ) throws -> XtreamClient {
        XtreamClient(
            endpoint: try XtreamEndpoint(
                serverURL: XCTUnwrap(URL(string: "https://example.invalid"))
            ),
            credentials: XtreamCredentials(
                username: "fixture-user",
                password: "test"
            ),
            httpClient: httpClient,
            userAgent: "OKVideoMac/Test",
            catalogResponsePolicy: catalogPolicy
        )
    }

    private func authenticate(_ json: String) async throws -> XtreamAccount {
        let httpClient = XtreamRecordingHTTPClient(
            responseData: Data(json.utf8)
        )
        return try await makeClient(httpClient: httpClient).authenticate()
    }

    private func authenticationError(_ json: String) async -> XtreamClientError? {
        do {
            _ = try await authenticate(json)
            XCTFail("Expected Xtream authentication to fail")
            return nil
        } catch {
            return error as? XtreamClientError
        }
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }
}

private actor XtreamRecordingHTTPClient: HTTPClient {
    private(set) var requests: [HTTPRequest] = []
    private let responseData: Data

    init(responseData: Data = Data("[]".utf8)) {
        self.responseData = responseData
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let isVODInfo = URLComponents(
            url: request.url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.contains(where: {
            $0.name == "action" && $0.value == "get_vod_info"
        }) == true
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: [:],
            body: isVODInfo
                ? Data(#"{"info":{},"movie_data":{}}"#.utf8)
                : responseData
        )
    }
}

private actor XtreamConcurrencyProbeHTTPClient: HTTPClient {
    private(set) var requestCount = 0
    private(set) var maximumActiveRequests = 0
    private var activeRequests = 0

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestCount += 1
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        try await Task.sleep(nanoseconds: 20_000_000)
        activeRequests -= 1
        return HTTPResponse(
            url: request.url,
            statusCode: 200,
            headers: [:],
            body: Data("[]".utf8)
        )
    }
}
