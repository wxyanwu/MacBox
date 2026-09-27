import XCTest
@testable import OKVideoCore

final class DanmakuAutomationTests: XCTestCase {
    func testCombinedOrConflictingServiceEpisodeIsNotMatchedAsSingleEpisode() throws {
        let endpoint = try XCTUnwrap(DanmakuServiceEndpoint(url: URL(string: "https://danmaku.example")!))
        for name in ["第34-35集", "S01E34 S02E34"] {
            let data = try JSONSerialization.data(withJSONObject: ["animes": [[
                "animeTitle": "兰香如故", "type": "电视剧",
                "episodes": [["episodeId": 34, "episodeTitle": name]]
            ]]])
            let sources = try endpoint.decode(data, generation: 1)
            XCTAssertEqual(sources.count, 1)
            XCTAssertNil(sources.first?.match?.episode)
            let request = DanmakuMatchRequest(title: "兰香如故", category: "电视剧", episode: .init(name: "第34集", url: ""))
            XCTAssertNil(DanmakuMatcher.automaticSource(sources, for: request))
        }
    }
    func testEpisodeAPIWinsOverTencentWebpageAndKeepsVideoIdentity() throws {
        let endpoint = try XCTUnwrap(DanmakuServiceEndpoint(url: URL(string: "http://localhost:9321/key")!))
        let data = Data(#"{"animes":[{"animeTitle":"兰香如故(2026)【电视剧】from tencent","type":"电视剧","episodes":[{"episodeId":10035,"episodeTitle":"【qq】 兰香如故_34","url":"https://v.qq.com/x/cover/show/vid34.html"}]}]}"#.utf8)
        let result = try XCTUnwrap(endpoint.decode(data, generation: 1).first)
        XCTAssertEqual(result.runtime.url.absoluteString, "http://localhost:9321/key/api/v2/comment/10035?format=xml")
        XCTAssertEqual(result.stable.resourceID, "qq:vid34")
        XCTAssertEqual(result.match?.episode, 34)
        XCTAssertEqual(result.match?.year, "2026")
        XCTAssertEqual(DanmakuServiceEndpoint.normalizedTitle(result.match!.title), "兰香如故")
        let renumbered = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "10035", with: "20035").utf8)
        let restored = try XCTUnwrap(endpoint.decode(renumbered, generation: 2).first)
        XCTAssertEqual(result.id, restored.id)
        XCTAssertNotEqual(result.runtime.url, restored.runtime.url)
    }
    func testProviderWebPageIsNotAnAPIAndPortsAreDistinct() throws {
        XCTAssertNil(DanmakuServiceEndpoint(url: URL(string: "http://localhost:8888/website/danmu/fe")!))
        XCTAssertNotEqual(DanmakuServiceEndpoint(url: URL(string: "http://localhost:1/key")!)?.identity,
                          DanmakuServiceEndpoint(url: URL(string: "http://localhost:2/key")!)?.identity)
        let endpoint = try XCTUnwrap(DanmakuServiceEndpoint(url: URL(string: "https://example.com/key/api/v2/search/episodes?token=test")!))
        XCTAssertEqual(endpoint.searchURL(keyword: "A&B")?.query, "token=test&anime=A%26B")
        XCTAssertFalse(endpoint.identity.contains("token"))
    }
    func testHTMLAndUnrelatedXMLFailClearlyAndBOMJSONWorks() throws {
        XCTAssertThrowsError(try DanmakuPayloadParser().parse(Data("<!DOCTYPE html><html></html>".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("网页"))
        }
        XCTAssertThrowsError(try DanmakuPayloadParser().parse(Data("<error>wrong</error>".utf8)))
        let data = Data([0xEF,0xBB,0xBF]) + Data(#"{"comments":[{"p":"1,1,16777215","m":"hello"}]}"#.utf8)
        XCTAssertEqual(try DanmakuPayloadParser().parse(data).comments.count, 1)
        XCTAssertTrue(try DanmakuPayloadParser().parse(Data("<i/>".utf8)).comments.isEmpty)
    }
    func testContextualEpisodeRequiresDirectoryEvidenceAndRejectsWrongEpisodes() throws {
        let siblings = (1...34).map { PlayEpisode(name: "\($0) [2.06GB]", url: "\($0)") }
        let request = DanmakuMatchRequest(title: "兰香如故", category: "电视剧", episode: siblings[33], siblings: siblings)
        XCTAssertEqual(request.episode, 34)
        XCTAssertNil(DanmakuMatchRequest(title: "兰香如故", category: "电视剧", episode: siblings[33]).episode)
        let endpoint = DanmakuServiceEndpoint(url: URL(string: "http://localhost:9321/key")!)!
        let data = Data(#"{"animes":[{"animeTitle":"兰香如故(2026)【电视剧】from tencent","type":"电视剧","episodes":[{"episodeId":7,"episodeTitle":"【qq】 兰香如故_07","url":"https://v.qq.com/x/cover/show/vid7.html"},{"episodeId":34,"episodeTitle":"【qq】 兰香如故_34","url":"https://v.qq.com/x/cover/show/vid34.html"},{"episodeId":35,"episodeTitle":"【qq】 兰香如故花絮_34","url":"https://v.qq.com/x/cover/show/bonus.html"}]}]}"#.utf8)
        let sources = try endpoint.decode(data, generation: 1)
        let unknownCategory = DanmakuMatchRequest(title: "兰香如故", episode: siblings[33], siblings: siblings)
        XCTAssertNil(unknownCategory.episode)
        XCTAssertEqual(unknownCategory.contextualEpisode, 34)
        XCTAssertEqual(DanmakuMatcher.automaticSource(sources, for: unknownCategory)?.match?.episode, 34)

        XCTAssertEqual(DanmakuMatcher.automaticSource(sources, for: request)?.match?.episode, 34)
        XCTAssertEqual(DanmakuMatcher.candidates(sources, for: request).count, 1)
        var otherYear = request; otherYear.year = "2020"
        XCTAssertNil(DanmakuMatcher.automaticSource(sources, for: otherYear))
        var wrongSeason = sources[1]; wrongSeason.match?.season = 2
        var firstSeason = request; firstSeason.season = 1
        XCTAssertNil(DanmakuMatcher.automaticSource([wrongSeason], for: firstSeason))
        var otherWork = sources[1]; otherWork.match?.workID = "remake"
        XCTAssertNil(DanmakuMatcher.automaticSource([sources[1], otherWork], for: request))
        XCTAssertNotNil(DanmakuMatcher.automaticSource([sources[1], otherWork], for: request, preferredWork: "qq:show"))
    }
    func testSpecialEpisodesNeverBecomeMainEpisodes() {
        for name in ["第1-2集", "第34集花絮", "第34集上部"] {
            let request = DanmakuMatchRequest(title: "剧", category: "电视剧", episode: .init(name: name, url: ""))
            XCTAssertFalse(request.isMain)
        }
        let movie = DanmakuMatchRequest(title: "电影2046", category: "电影", episode: .init(name: "正片", url: ""))
        XCTAssertNil(movie.episode)
    }

    func testRecordedRealServicePayloadMatches34AndParsesComments() throws {
        guard let directory = ProcessInfo.processInfo.environment["OKVIDEO_DANMAKU_EVIDENCE"] else { throw XCTSkip("Opt-in recorded service evidence") }
        let search = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("okvideo-danmaku-search.json"))
        let endpoint = DanmakuServiceEndpoint(url: URL(string: "https://fixture.invalid/api")!)!
        let candidates = try endpoint.decode(search, generation: 1)
        let episodes = (1...34).map { PlayEpisode(name: "\($0) [2.06GB]", url: "\($0)") }
        let request = DanmakuMatchRequest(title: "兰香如故", episode: episodes[33], siblings: episodes)
        let chosen = try XCTUnwrap(DanmakuMatcher.automaticSource(candidates, for: request))
        XCTAssertEqual(chosen.match?.episode, 34)
        XCTAssertEqual(chosen.match?.videoID, "qq:h4102ygaw7u")
        for file in ["okvideo-danmaku-json34.data", "okvideo-danmaku-xml07.data"] {
            let timeline = try DanmakuPayloadParser().parse(Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(file)))
            XCTAssertGreaterThan(timeline.comments.count, 20_000)
        }
    }

}

private actor DanmakuDiscoveryHTTP: HTTPClient {
    var requests: [HTTPRequest] = []
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return .init(url: request.url, statusCode: 200, headers: [:],
                     body: Data(#"{"code":0,"data":{"urls":[{"name":"内置弹幕","builtin":true,"address":"http://localhost:9321"},{"name":"其他服务","address":"https://example.com/danmaku"}]}}"#.utf8))
    }
}
extension DanmakuAutomationTests {
    func testCatPawPageDiscoversDeclaredAPIsAndDoesNotAppendSearchToHTML() async throws {
        let http = DanmakuDiscoveryHTTP(), client = DanmakuServiceClient(http: DanmakuDiscoveryHTTP())
        let unrelated = await client.discover(page: URL(string: "https://example.com/page.html")!, identity: "source")
        XCTAssertTrue(unrelated.isEmpty)
        let actual = DanmakuServiceClient(http: http)
        let endpoints = await actual.discover(page: URL(string: "http://localhost:12345/website/danmu/fe")!, identity: "source:config")
        XCTAssertEqual(endpoints.count, 2)
        XCTAssertEqual(endpoints.first?.identity, "source:config:builtin")
        let requests = await http.requests
        XCTAssertEqual(requests.first?.url.path, "/website/danmu/setting")
        XCTAssertNotNil(requests.first?.earlyResponseLimitBytes)
    }
}
