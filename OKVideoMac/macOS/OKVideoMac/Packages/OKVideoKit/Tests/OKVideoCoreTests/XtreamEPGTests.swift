import XCTest
@testable import OKVideoCore

final class XtreamEPGTests: XCTestCase {
    func testTimestampBase64AndSecretRedactionWithoutEPGChannelID() throws {
        let title = Data("中文 secret-password".utf8).base64EncodedString()
        let data = Data("{\"epg_listings\":[{\"title\":\"\(title)\",\"start_timestamp\":\"100\",\"stop_timestamp\":200}]}".utf8)
        let response = try XtreamEPGResponse(data: data)
        XCTAssertFalse(response.requiresServerTimezone)
        let value = try response.payload(streamID: "7", timezone: nil, secrets: ["secret-password"])
        XCTAssertEqual(value.guide.programmes.first?.title, "中文 <redacted>")
        XCTAssertEqual(value.guide.programmes.first?.channelID, "7")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value.guide), as: UTF8.self).contains("secret-password"))
    }

    func testEmptyMalformedAndStringDates() throws {
        XCTAssertTrue(try XtreamEPGResponse(data: Data("[]".utf8)).rows.isEmpty)
        XCTAssertThrowsError(try XtreamEPGResponse(data: Data("{}".utf8)))
        let response = try XtreamEPGResponse(data: Data(#"{"epg_listings":[{"title":"新闻","start":"2026-09-10 23:30:00","end":"2026-09-11 00:30:00"}]}"#.utf8))
        XCTAssertTrue(response.requiresServerTimezone)
        XCTAssertThrowsError(try response.payload(streamID: "7", timezone: nil, secrets: []))
        let value = try response.payload(streamID: "7", timezone: TimeZone(identifier: "Asia/Shanghai"), secrets: [])
        XCTAssertEqual(value.guide.programmes.first?.end.timeIntervalSince(value.guide.programmes.first!.start), 3600)
    }

    func testRequestIsBoundedStrictAndErrorsDoNotEscape() async throws {
        let http = EPGRequestFixture()
        let client = XtreamClient(endpoint: try XtreamEndpoint(serverURL: URL(string: "https://example.invalid/base")!),
                                  credentials: XtreamCredentials(username: "user", password: "secret"),
                                  httpClient: http, userAgent: "OKVideoMac")
        let value = try await client.shortEPG(streamID: "7")
        XCTAssertTrue(value.guide.programmes.isEmpty)
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.redirectPolicy, .sameOriginNoDowngrade)
        XCTAssertEqual(request.earlyResponseLimitBytes, 1024 * 1024)
        XCTAssertTrue(request.url.absoluteString.contains("get_short_epg"))
        XCTAssertEqual(requests.count, 1)
        await http.fail()
        do { _ = try await client.shortEPG(streamID: "7"); XCTFail("Expected error") }
        catch { XCTAssertTrue(error is EPGFetchError); XCTAssertFalse(String(describing: error).contains("secret")) }
    }

    func testTitleLimitIsUTF8BytesAndKeepsValidBoundary() throws {
        let title = String(repeating: "界", count: 2_000)
        let data = try JSONSerialization.data(withJSONObject: ["epg_listings": [[
            "title": title, "start_timestamp": "100", "stop_timestamp": "200"
        ]]])
        let value = try XtreamEPGResponse(data: data).payload(streamID: "7", timezone: nil, secrets: [])
        let bounded = try XCTUnwrap(value.guide.programmes.first?.title)
        XCTAssertLessThanOrEqual(bounded.utf8.count, 4_096)
        XCTAssertFalse(bounded.contains("�"))
    }
}

private actor EPGRequestFixture: HTTPClient {
    var requests: [HTTPRequest] = []
    var failing = false
    func fail() { failing = true }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if failing { throw HTTPClientError.transport(request.url.absoluteString) }
        return HTTPResponse(url: request.url, statusCode: 200, headers: [:], body: Data(#"{"epg_listings":[]}"#.utf8))
    }
}
