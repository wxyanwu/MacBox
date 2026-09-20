import XCTest
@testable import OKVideoCore

final class XtreamLiveCatalogTests: XCTestCase {
    private let providerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testLiveDTOAcceptsMixedScalarMetadataAndIgnoresDirectSource() throws {
        let data = Data(#"[{"stream_id":101,"name":"One","num":"7","category_id":10,"container_extension":"ts","direct_source":{"unexpected":"secret"}},{"stream_id":"102","num":8,"category_id":"20","name":null,"stream_icon":[]},{"stream_id":true,"category_id":{},"name":"Bad ID"},{}]"#.utf8)
        let values = try XtreamResponseDecoder().decodeArray(XtreamLiveStreamDTO.self, from: data)
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values[0].streamID, "101")
        XCTAssertEqual(values[0].categoryID, "10")
        XCTAssertEqual(values[0].number, "7")
        XCTAssertEqual(values[1].streamID, "102")
        XCTAssertEqual(values[1].number, "8")
        XCTAssertNil(values[1].name)
        XCTAssertNil(values[1].streamIcon)
        XCTAssertNil(values[2].streamID)
        XCTAssertNil(values[2].categoryID)
        XCTAssertNil(values[3].streamID)
    }

    func testLiveClientUsesBoundedMetadataRequestsAndOptionalCategory() async throws {
        let http = LiveCatalogHTTPClient(categories: "[]", streams: "[]")
        let client = XtreamClient(
            endpoint: try XtreamEndpoint(serverURL: XCTUnwrap(URL(string: "https://example.invalid/base"))),
            credentials: XtreamCredentials(username: "fixture-user", password: "fixture"),
            httpClient: http,
            userAgent: "LiveCatalogTests",
            catalogResponsePolicy: XtreamCatalogResponsePolicy(maximumResponseBytes: 123_456)
        )
        _ = try await client.liveCategories()
        _ = try await client.liveStreams(categoryID: "10")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(query("action", in: requests[0]), "get_live_categories")
        XCTAssertEqual(query("action", in: requests[1]), "get_live_streams")
        XCTAssertEqual(query("category_id", in: requests[1]), "10")
        for request in requests {
            XCTAssertEqual(request.url.path, "/base/player_api.php")
            XCTAssertEqual(request.method, .get)
            XCTAssertEqual(request.maximumResponseBytes, 123_456)
            XCTAssertEqual(request.earlyResponseLimitBytes, 123_456)
            XCTAssertEqual(request.redirectPolicy, .sameOriginNoDowngrade)
        }
    }

    func testCatalogSeparatesSameNamedCategoriesAndDeterministicallyDeduplicatesIDs() async throws {
        let http = LiveCatalogHTTPClient(
            categories: #"[{"category_id":10,"category_name":"Same"},{"category_id":"20","category_name":"Same"},{"category_id":10,"category_name":"Ignored Duplicate"}]"#,
            streams: #"[{"stream_id":101,"name":"Duplicate Title","category_id":10},{"stream_id":"102","name":"Duplicate Title","category_id":"20","container_extension":"m3u8"},{"stream_id":101,"name":"Ignored Duplicate ID","category_id":20},{"stream_id":103,"name":"Orphan","category_id":"missing"},{"stream_id":104,"category_id":null},{"name":"No ID"},{"stream_id":"https://invalid/path","name":"URL ID"},{"stream_id":true,"name":"Boolean ID"}]"#
        )
        let snapshot = try await provider(http: http).liveCatalog()
        XCTAssertEqual(snapshot.sourceID, .xtream(providerID))
        XCTAssertNil(snapshot.epgURL)
        XCTAssertEqual(snapshot.groups.map(\.name), ["Same", "Same", "Uncategorized"])
        XCTAssertEqual(Set(snapshot.groups.map(\.id)).count, 3)
        XCTAssertEqual(snapshot.groups.map { $0.channels.count }, [1, 1, 2])
        let channels = snapshot.groups.flatMap(\.channels)
        XCTAssertEqual(channels.map(\.name), ["Duplicate Title", "Duplicate Title", "Orphan", "104"])
        XCTAssertEqual(Set(channels.map(\.id)).count, 4)
        XCTAssertEqual(channels[0].streams.map(\.format), ["ts", "m3u8"])
        XCTAssertEqual(channels[1].streams.map(\.format), ["m3u8", "ts"])
        for group in snapshot.groups {
            for channel in group.channels {
                XCTAssertEqual(channel.groupID, group.id)
                XCTAssertNil(channel.tvgID)
                XCTAssertNil(channel.tvgName)
                XCTAssertTrue(channel.streams.allSatisfy { $0.url == nil && $0.headers.isEmpty && !$0.needsParsing })
            }
        }
    }

    func testRefreshKeepsChannelIdentityAcrossNamesGroupsAndFormatOrder() async throws {
        let http = LiveCatalogHTTPClient(
            categories: #"[{"category_id":10,"category_name":"Before"},{"category_id":20,"category_name":"Other"}]"#,
            streams: #"[{"stream_id":101,"name":"Before","category_id":10,"container_extension":"ts"}]"#
        )
        let provider = try provider(http: http)
        let first = try await provider.liveCatalog()
        await http.replace(
            categories: #"[{"category_id":10,"category_name":"Renamed"},{"category_id":20,"category_name":"Other"}]"#,
            streams: #"[{"stream_id":101,"name":"After","category_id":20,"container_extension":"m3u8"}]"#
        )
        let second = try await provider.liveCatalog()
        let originalChannel = try XCTUnwrap(first.groups.flatMap(\.channels).first)
        let refreshedChannel = try XCTUnwrap(second.groups.flatMap(\.channels).first)
        XCTAssertEqual(first.groups[0].id, second.groups[0].id)
        XCTAssertEqual(originalChannel.id, refreshedChannel.id)
        XCTAssertNotEqual(originalChannel.name, refreshedChannel.name)
        XCTAssertNotEqual(originalChannel.groupID, refreshedChannel.groupID)
        XCTAssertEqual(Set(originalChannel.streams.map(\.id)), Set(refreshedChannel.streams.map(\.id)))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4, "Explicit refresh must fetch metadata again, not reuse a stale snapshot")
    }

    func testSameRemoteIDsInDifferentProvidersNeverShareIdentity() async throws {
        let http = LiveCatalogHTTPClient(
            categories: #"[{"category_id":10,"category_name":"Same"}]"#,
            streams: #"[{"stream_id":101,"name":"Same","category_id":10}]"#
        )
        let first = try await provider(http: http).liveCatalog()
        let second = try await provider(http: http, providerID: UUID()).liveCatalog()
        XCTAssertNotEqual(first.sourceID, second.sourceID)
        XCTAssertNotEqual(first.groups[0].id, second.groups[0].id)
        XCTAssertNotEqual(first.groups[0].channels[0].id, second.groups[0].channels[0].id)
        XCTAssertNotEqual(first.groups[0].channels[0].streams[0].id, second.groups[0].channels[0].streams[0].id)
    }

    func testBrowsingNeverRequestsMediaOrEPGAndSerializationContainsNoCredentials() async throws {
        let http = LiveCatalogHTTPClient(
            categories: #"[{"category_id":10,"category_name":"Live"}]"#,
            streams: #"[{"stream_id":101,"name":"One","category_id":10,"direct_source":"https://example.invalid/live/fixture-user/fixture/101.ts","epg_channel_id":"private-epg"}]"#
        )
        let snapshot = try await provider(http: http).liveCatalog()
        let json = String(decoding: try JSONEncoder().encode(snapshot.groups), as: UTF8.self)
        XCTAssertEqual(snapshot.groups.first?.channels.first?.tvgID, "private-epg")
        for forbidden in ["fixture-user", "fixture", "example.invalid", "direct_source", "sourceIdentity", "episodeIdentity"] {
            XCTAssertFalse(json.contains(forbidden))
        }
        let requests = await http.requests
        XCTAssertEqual(Set(requests.compactMap { query("action", in: $0) }), Set(["get_live_categories", "get_live_streams"]))
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url.path == "/base/player_api.php" })
    }

    func testLogoFilterRejectsCredentialQueriesPathsFragmentsAndEncodedValues() async throws {
        let logos = [
            "https://images.example.invalid/logo.png",
            "https://images.example.invalid/logo.png?username=someone",
            "https://images.example.invalid/logo.png?u=someone&p=another",
            "https://images.example.invalid/live/other/secret/101.png",
            "https://images.example.invalid/fixture-user/logo.png",
            "https://images.example.invalid/fixture.png",
            "https://images.example.invalid/fixt%75re.png",
            "https://images.example.invalid/fixt%2575re.png",
            "https://images.example.invalid/logo.png#private",
            "https://user:pass@images.example.invalid/logo.png"
        ]
        let streamObjects: [[String: Any]] = logos.enumerated().map { index, logo in
            ["stream_id": index + 1, "name": "Logo \(index)", "stream_icon": logo]
        }
        let streams = String(decoding: try JSONSerialization.data(withJSONObject: streamObjects), as: UTF8.self)
        let snapshot = try await provider(http: LiveCatalogHTTPClient(categories: "[]", streams: streams)).liveCatalog()
        let channels = snapshot.groups.flatMap(\.channels)
        XCTAssertEqual(channels.count, logos.count)
        XCTAssertEqual(channels[0].logoURL?.absoluteString, logos[0])
        XCTAssertTrue(channels.dropFirst().allSatisfy { $0.logoURL == nil })
    }

    func testEmptyCategoriesAndStreamsProduceACompletedEmptySnapshot() async throws {
        let snapshot = try await provider(http: LiveCatalogHTTPClient(categories: "[]", streams: "[]")).liveCatalog()
        XCTAssertTrue(snapshot.groups.isEmpty)
        XCTAssertNil(snapshot.epgURL)
    }

    func testLivePlaybackResolutionBuildsStandardPathWithoutNetworkRequest() async throws {
        let http = LiveCatalogHTTPClient(categories: "[]", streams: "[]")
        let provider = try provider(http: http)
        let locator = try XtreamLivePlaybackLocator(
            providerID: providerID,
            streamID: "701",
            outputFormat: .m3u8
        )
        let reference = PlaybackResourceReference.xtreamLive(locator)

        let result = try provider.resolveLivePlayback(reference)

        let url = try XCTUnwrap(URL(string: result.url))
        XCTAssertEqual(url.path, "/base/live/fixture-user/fixture/701.m3u8")
        XCTAssertNil(url.query)
        XCTAssertEqual(result.format, "m3u8")
        XCTAssertEqual(result.headers["User-Agent"], "LiveCatalogTests")
        XCTAssertEqual(result.resourceReference, reference)
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLivePlaybackResolutionRejectsAnotherProviderReference() async throws {
        let http = LiveCatalogHTTPClient(categories: "[]", streams: "[]")
        let provider = try provider(http: http)
        let locator = try XtreamLivePlaybackLocator(
            providerID: UUID(), streamID: "701", outputFormat: .ts
        )
        XCTAssertThrowsError(
            try provider.resolveLivePlayback(.xtreamLive(locator))
        ) { error in
            XCTAssertEqual(error as? XtreamSiteProviderError, .invalidPlaybackLocator)
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLivePlaybackAccountValidationUsesAuthMetadataWithoutMediaProbe()
        async throws {
        let http = LiveCatalogHTTPClient(categories: "[]", streams: "[]")
        let provider = try provider(http: http)

        try await provider.validateLivePlaybackAccount()

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url.path, "/base/player_api.php")
        XCTAssertNil(query("action", in: requests[0]))
        XCTAssertEqual(requests[0].maximumResponseBytes, 8 * 1_024 * 1_024)
        XCTAssertNil(requests[0].earlyResponseLimitBytes)
        XCTAssertFalse(requests[0].url.path.contains("/live/"))
    }

    func testTenThousandChannelsMapWithoutMediaRequestsOrQuadraticGrouping() async throws {
        let count = 10_000
        let objects: [[String: Any]] = (1...count).map {
            ["stream_id": $0, "name": "Channel \($0)", "category_id": 10]
        }
        let streams = String(decoding: try JSONSerialization.data(withJSONObject: objects), as: UTF8.self)
        let http = LiveCatalogHTTPClient(categories: #"[{"category_id":10,"category_name":"Large"}]"#, streams: streams)
        let start = Date()
        let snapshot = try await provider(http: http).liveCatalog()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(snapshot.groups.count, 1)
        XCTAssertEqual(snapshot.groups[0].channels.count, count)
        XCTAssertEqual(Set(snapshot.groups[0].channels.map(\.id)).count, count)
        XCTAssertLessThan(elapsed, 15, "10k metadata mapping must remain bounded on the local test host")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    private func provider(http: HTTPClient, providerID: UUID? = nil) throws -> XtreamSiteProvider {
        try XtreamSiteProvider(
            configuration: XtreamProviderConfiguration(
                providerID: providerID ?? self.providerID,
                displayName: "Fixture Live",
                serverBaseURL: XCTUnwrap(URL(string: "https://example.invalid/base"))
            ),
            credentials: XtreamCredentials(username: "fixture-user", password: "fixture"),
            httpClient: http,
            userAgent: "LiveCatalogTests"
        )
    }

    private func query(_ key: String, in request: HTTPRequest) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
    }
}

private actor LiveCatalogHTTPClient: HTTPClient {
    private var responses: [String: Data]
    private let authentication: Data
    private(set) var requests: [HTTPRequest] = []

    init(
        categories: String,
        streams: String,
        authentication: String = #"{"user_info":{"auth":1,"status":"Active"}}"#
    ) {
        responses = ["get_live_categories": Data(categories.utf8), "get_live_streams": Data(streams.utf8)]
        self.authentication = Data(authentication.utf8)
    }

    func replace(categories: String, streams: String) {
        responses = ["get_live_categories": Data(categories.utf8), "get_live_streams": Data(streams.utf8)]
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let action = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
        guard request.url.path == "/base/player_api.php" else {
            XCTFail("Live catalog made an unexpected non-metadata request")
            throw HTTPClientError.invalidResponse
        }
        if action == nil {
            return HTTPResponse(
                url: request.url, statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: authentication
            )
        }
        guard let action, let data = responses[action] else {
            XCTFail("Live catalog made an unexpected metadata request")
            throw HTTPClientError.invalidResponse
        }
        return HTTPResponse(url: request.url, statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
    }
}
