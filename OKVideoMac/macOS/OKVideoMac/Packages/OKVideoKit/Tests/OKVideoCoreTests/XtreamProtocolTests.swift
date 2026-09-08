import XCTest
@testable import OKVideoCore

final class XtreamProtocolTests: XCTestCase {
    private let decoder = XtreamResponseDecoder()

    func testEndpointBuildsAPIURLForHTTPCustomPortAndBasePath() throws {
        let endpoint = try XtreamEndpoint(
            serverURL: XCTUnwrap(URL(string: "http://example.invalid:8080/iptv/"))
        )
        let url = try XtreamURLBuilder(endpoint: endpoint).playerAPIURL(
            credentials: XtreamCredentials(
                username: "user+name",
                password: "p&ssword"
            ),
            action: .vodStreams,
            parameters: [URLQueryItem(name: "category_id", value: "42")]
        )
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.scheme, "http")
        XCTAssertEqual(components.host, "example.invalid")
        XCTAssertEqual(components.port, 8080)
        XCTAssertEqual(components.path, "/iptv/player_api.php")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }),
            [
                "username": "user+name",
                "password": "p&ssword",
                "action": "get_vod_streams",
                "category_id": "42"
            ]
        )
    }

    func testPlaybackURLPercentEncodesCredentialsAndUsesSafeExtension() throws {
        let endpoint = try XtreamEndpoint(
            serverURL: XCTUnwrap(URL(string: "https://example.invalid/base"))
        )
        let builder = XtreamURLBuilder(endpoint: endpoint)
        let credentials = XtreamCredentials(
            username: "user/name",
            password: "p?#ss"
        )

        let url = try builder.playbackURL(
            kind: .series,
            remoteID: "episode 7",
            containerExtension: "MP4?token=bad",
            credentials: credentials
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.invalid/base/series/user%2Fname/p%3F%23ss/episode%207.mp4"
        )
    }

    func testEndpointRejectsUnsafeOrCredentialBearingServerURL() throws {
        XCTAssertThrowsError(
            try XtreamEndpoint(
                serverURL: XCTUnwrap(URL(string: "ftp://example.invalid"))
            )
        ) {
            XCTAssertEqual($0 as? XtreamEndpointError, .unsupportedScheme)
        }
        XCTAssertThrowsError(
            try XtreamEndpoint(
                serverURL: XCTUnwrap(URL(string: "https://u:p@example.invalid"))
            )
        ) {
            XCTAssertEqual($0 as? XtreamEndpointError, .embeddedCredentials)
        }
        XCTAssertThrowsError(
            try XtreamEndpoint(
                serverURL: XCTUnwrap(URL(string: "https://example.invalid?token=x"))
            )
        ) {
            XCTAssertEqual(
                $0 as? XtreamEndpointError,
                .queryOrFragmentNotAllowed
            )
        }
    }

    func testPersistedProviderDescriptorHasOnlyCredentialFreeFields() throws {
        let providerID = UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )!
        let descriptor = try XtreamProviderConfiguration(
            providerID: providerID,
            displayName: "Fixture Account",
            serverBaseURL: XCTUnwrap(
                URL(string: "https://example.invalid:8443/iptv/")
            )
        )

        let data = try descriptor.encoded()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set(["version", "providerID", "displayName", "serverBaseURL"])
        )
        XCTAssertNil(object["username"])
        XCTAssertNil(object["password"])
        XCTAssertEqual(
            try XtreamProviderConfiguration(data: data),
            descriptor
        )
        XCTAssertEqual(
            descriptor.providerConfiguration.sites.first?.key,
            "xtream:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        XCTAssertEqual(
            descriptor.providerConfiguration.sites.first?.api,
            XtreamProviderConfiguration.nativeAPIIdentifier
        )
    }

    func testAuthenticationFixtureDecodesMixedScalarTypes() throws {
        let response = try decoder.decode(
            XtreamAuthenticationResponseDTO.self,
            from: fixture("xtream-auth-success", extension: "json")
        )

        XCTAssertEqual(response.userInfo?.auth, true)
        XCTAssertEqual(response.userInfo?.status, "Active")
        XCTAssertEqual(response.userInfo?.expirationTimestamp, 1_900_000_000)
        XCTAssertEqual(response.userInfo?.isTrial, false)
        XCTAssertEqual(response.userInfo?.activeConnections, 1)
        XCTAssertEqual(response.userInfo?.maxConnections, 3)
        XCTAssertEqual(response.userInfo?.allowedOutputFormats, ["m3u8", "ts"])
        XCTAssertEqual(response.serverInfo?.port, 8080)
        XCTAssertEqual(response.serverInfo?.httpsPort, 8443)
    }

    func testExpiredAuthenticationFixtureRemainsDecodable() throws {
        let response = try decoder.decode(
            XtreamAuthenticationResponseDTO.self,
            from: fixture("xtream-auth-expired", extension: "json")
        )

        XCTAssertEqual(response.userInfo?.auth, false)
        XCTAssertEqual(response.userInfo?.status, "Expired")
        XCTAssertEqual(response.userInfo?.expirationTimestamp, 1_600_000_000)
    }

    func testAuthenticationFieldDistinguishesMissingAndAcceptedRejectedValues() throws {
        let cases: [(String, Bool?)] = [
            (#"{"user_info":{"status":"Active"}}"#, nil),
            (#"{"user_info":{"auth":null,"status":"Active"}}"#, nil),
            (#"{"user_info":{"auth":1,"status":"Active"}}"#, true),
            (#"{"user_info":{"auth":"1","status":"Active"}}"#, true),
            (#"{"user_info":{"auth":true,"status":"Active"}}"#, true),
            (#"{"user_info":{"auth":0,"status":"Active"}}"#, false),
            (#"{"user_info":{"auth":"0","status":"Active"}}"#, false),
            (#"{"user_info":{"auth":false,"status":"Active"}}"#, false)
        ]

        for (json, expected) in cases {
            let response = try decoder.decode(
                XtreamAuthenticationResponseDTO.self,
                from: Data(json.utf8)
            )
            XCTAssertEqual(response.userInfo?.auth, expected)
        }
    }

    func testMalformedAuthenticationFieldIsNotTreatedAsMissing() {
        let malformedValues = [
            #""sometimes""#,
            "2",
            #"{"unexpected":true}"#
        ]

        for auth in malformedValues {
            let data = Data(
                #"{"user_info":{"auth":\#(auth),"status":"Active"}}"#.utf8
            )
            XCTAssertThrowsError(
                try decoder.decode(
                    XtreamAuthenticationResponseDTO.self,
                    from: data
                )
            ) {
                XCTAssertEqual(
                    $0 as? XtreamResponseDecodingError,
                    .malformedJSON
                )
            }
        }
    }

    func testVODFixturesDecodeNumericAndStringIdentifiers() throws {
        let categories = try decoder.decodeArray(
            XtreamCategoryDTO.self,
            from: fixture("xtream-vod-categories", extension: "json")
        )
        let streams = try decoder.decodeArray(
            XtreamVODStreamDTO.self,
            from: fixture("xtream-vod-streams", extension: "json")
        )
        let info = try decoder.decode(
            XtreamVODInfoResponseDTO.self,
            from: fixture("xtream-vod-info", extension: "json")
        )

        XCTAssertEqual(categories.map(\.categoryID), ["10", "20"])
        XCTAssertEqual(streams.map(\.streamID), ["1001", "1002"])
        XCTAssertEqual(streams.first?.rating, 7.4)
        XCTAssertNil(streams.last?.streamIcon)
        XCTAssertEqual(info.info?.durationSeconds, 5_530)
        XCTAssertEqual(info.info?.backdropPaths.count, 2)
        XCTAssertEqual(info.movieData?.containerExtension, "mkv")
    }

    func testEmptyVODMetadataArraysAreAbsentButNonemptyArraysRemainInvalid() throws {
        for payload in [#"{"info":[],"movie_data":{}}"#, #"{"info":null}"#, #"{}"#] {
            let response = try decoder.decode(XtreamVODInfoResponseDTO.self, from: Data(payload.utf8))
            XCTAssertNil(response.info)
        }
        for payload in [#"{"info":[{"name":"unexpected"}]}"#, #"{"info":42}"#, #"{"info":"broken"}"#] {
            XCTAssertThrowsError(try decoder.decode(XtreamVODInfoResponseDTO.self, from: Data(payload.utf8)))
        }
    }

    func testClassicSeriesFixtureKeepsSeasonHierarchy() throws {
        let response = try decoder.decode(
            XtreamSeriesInfoResponseDTO.self,
            from: fixture("xtream-series-info-classic", extension: "json")
        )

        XCTAssertEqual(response.info?.name, "Fixture Series")
        XCTAssertEqual(response.seasons.map(\.seasonNumber), [1, 2])
        XCTAssertEqual(response.episodesBySeason[1]?.map(\.id), ["7001", "7002"])
        XCTAssertEqual(
            response.episodesBySeason[2]?.first?.info?.durationSeconds,
            2_700
        )
    }

    func testFlatSeriesFixtureGroupsEpisodesUsingFlexibleSeasonValues() throws {
        let response = try decoder.decode(
            XtreamSeriesInfoResponseDTO.self,
            from: fixture("xtream-series-info-flat", extension: "json")
        )

        XCTAssertEqual(response.episodesBySeason[1]?.count, 1)
        XCTAssertEqual(response.episodesBySeason[2]?.count, 2)
        XCTAssertEqual(response.episodesBySeason[2]?.last?.episodeNumber, 2)
    }

    func testSeriesCatalogFixtureToleratesMissingAndUnexpectedFields() throws {
        let series = try decoder.decodeArray(
            XtreamSeriesDTO.self,
            from: fixture("xtream-series-list", extension: "json")
        )

        XCTAssertEqual(series.map(\.seriesID), ["700", "701"])
        XCTAssertEqual(series.first?.episodeRunTime, 45)
        XCTAssertEqual(series.last?.backdropPaths, [])
        XCTAssertNil(series.last?.rating)
    }

    func testArrayDecoderToleratesKnownEmptyShapesButRejectsErrorObject() throws {
        XCTAssertEqual(
            try decoder.decodeArray(
                XtreamCategoryDTO.self,
                from: Data("null".utf8)
            ).count,
            0
        )
        XCTAssertEqual(
            try decoder.decodeArray(
                XtreamCategoryDTO.self,
                from: Data("{}".utf8)
            ).count,
            0
        )
        XCTAssertThrowsError(
            try decoder.decodeArray(
                XtreamCategoryDTO.self,
                from: Data(#"{"error":"maintenance"}"#.utf8)
            )
        ) {
            XCTAssertEqual(
                $0 as? XtreamResponseDecodingError,
                .unexpectedResponseShape
            )
        }
    }

    func testDecoderClassifiesEmptyHTMLAndMalformedResponsesWithoutEchoingBody() {
        let cases: [(Data, XtreamResponseDecodingError)] = [
            (Data(), .emptyResponse),
            (Data("  <html>credential-secret</html>".utf8), .htmlResponse),
            (Data("[broken".utf8), .malformedJSON)
        ]

        for (data, expected) in cases {
            XCTAssertThrowsError(
                try decoder.decode(
                    XtreamAuthenticationResponseDTO.self,
                    from: data
                )
            ) {
                XCTAssertEqual($0 as? XtreamResponseDecodingError, expected)
                XCTAssertFalse($0.localizedDescription.contains("credential-secret"))
            }
        }
    }

    private func fixture(_ name: String, extension pathExtension: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: pathExtension,
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }
}
