import XCTest
@testable import OKVideoCore

final class DanmakuCoreTests: XCTestCase {
    func testPlayerDecoderReadsNestedCatPawDanmaku() throws {
        let site = SiteConfiguration(
            key: "catpaw",
            name: "CatPaw",
            type: 3,
            api: "csp_Node"
        )
        let response = try UpstreamResponseDecoder.decodeJSON(
            Data(#"{"url":"https://media.example/video.mp4","extra":{"danmaku":{"url":"https://dm.example/1.xml"}}}"#.utf8),
            site: site,
            baseURL: nil
        )

        XCTAssertEqual(
            response.player?.danmaku,
            .object(["url": .string("https://dm.example/1.xml")])
        )
    }

    func testBilibiliXMLParsesSupportedModesAndSortsTimeline() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <i>
          <d p="2.5,5,36,16711680,0,0,hash,top">置顶 &amp; 测试</d>
          <d p="1.0,1,25,16777215,0,0,hash,scroll">滚动</d>
          <d p="3.0,4,18,255,0,0,hash,bottom">底部</d>
          <d p="invalid,1,25,1">丢弃</d>
        </i>
        """

        let timeline = try BilibiliDanmakuXMLParser().parse(Data(xml.utf8))

        XCTAssertEqual(timeline.comments.map(\.text), ["滚动", "置顶 & 测试", "底部"])
        XCTAssertEqual(timeline.comments.map(\.mode), [.scrolling, .top, .bottom])
        XCTAssertEqual(Array(timeline.comments(from: 1.5, through: 3)).map(\.text), ["置顶 & 测试", "底部"])
    }

    func testXMLParserEnforcesDocumentAndCommentLimits() throws {
        XCTAssertThrowsError(
            try BilibiliDanmakuXMLParser(maximumDocumentBytes: 3).parse(Data("<i/>".utf8))
        )
        let xml = "<i><d p=\"1,1,25,1\">一</d><d p=\"2,1,25,1\">二</d></i>"
        let timeline = try BilibiliDanmakuXMLParser(maximumComments: 1).parse(Data(xml.utf8))
        XCTAssertEqual(timeline.comments.map(\.text), ["一"])
    }

    func testSourceNormalizerHandlesNestedCatPawAndJSONStringShapes() throws {
        let generation: UInt64 = 9
        let value: JSONValue = .object([
            "extra": .object([
                "danmaku": .string(#"[{"name":"线路一","url":"/one.xml","default":true},{"name":"线路二","url":"https://example.com/two.xml"}]"#)
            ]),
            "danmaku": .array([
                .object([
                    "id": .string("remote-3"),
                    "name": .string("线路三"),
                    "url": .string("https://example.com/three.xml"),
                    "headers": .object(["Referer": .string("https://example.com/")])
                ])
            ])
        ])

        let sources = DanmakuSourceNormalizer.sources(
            from: value,
            provider: "catpaw",
            baseURL: URL(string: "https://runtime.example/base/")!,
            runtimeGeneration: generation
        )

        XCTAssertEqual(sources.count, 3)
        XCTAssertTrue(sources.contains { $0.runtime.url.absoluteString == "https://runtime.example/one.xml" && $0.isPreferred })
        let third = try XCTUnwrap(sources.first { $0.stable.resourceID == "remote-3" })
        XCTAssertEqual(third.runtime.headers["referer"], "https://example.com/")
        XCTAssertEqual(third.runtime.runtimeGeneration, generation)
    }

    func testRuntimeLocatorCannotBeEncodedThroughStableBinding() throws {
        let content = DanmakuContentIdentity(
            configurationID: UUID(),
            siteKey: "site",
            contentID: "show"
        )
        let episode = DanmakuEpisodeIdentity(content: content, episodeID: "ep-1", title: "第1集")
        let binding = DanmakuBinding(
            editionIdentity: DanmakuEditionIdentity(episode: episode, editionID: "line-a"),
            locator: StableDanmakuLocator(
                kind: .providerEpisode,
                provider: "catpaw",
                resourceID: "123",
                displayName: "弹幕"
            )
        )

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(binding), encoding: .utf8))
        XCTAssertFalse(encoded.contains("127.0.0.1"))
        XCTAssertFalse(encoded.contains("headers"))
        XCTAssertFalse(encoded.contains("runtimeGeneration"))
    }

    func testPresentationMetadataDoesNotChangeStableEpisodeIdentity() {
        let configurationID = UUID()
        let firstContent = DanmakuContentIdentity(
            configurationID: configurationID,
            siteKey: "site",
            contentID: "show",
            title: "原片名"
        )
        let renamedContent = DanmakuContentIdentity(
            configurationID: configurationID,
            siteKey: "site",
            contentID: "show",
            title: "更新后的片名"
        )
        let first = DanmakuEpisodeIdentity(
            content: firstContent,
            episodeID: "ep-1",
            title: "第 1 集",
            episodeNumber: 1
        )
        let renamed = DanmakuEpisodeIdentity(
            content: renamedContent,
            episodeID: "ep-1",
            title: "EP01",
            episodeNumber: nil
        )

        XCTAssertEqual(first, renamed)
        XCTAssertEqual(Set([first, renamed]).count, 1)
    }

    func testClockUsesPlayerAnchorAndStopsDuringBuffering() {
        var clock = DanmakuClock()
        clock.anchor(
            mediaTime: 10,
            monotonicTime: 100,
            rate: 2,
            isPlaying: true,
            isBuffering: false,
            isSeeking: false,
            generation: 1
        )
        XCTAssertEqual(clock.currentTime(at: 101.5), 13, accuracy: 0.001)

        clock.anchor(
            mediaTime: 13,
            monotonicTime: 101.5,
            rate: 2,
            isPlaying: true,
            isBuffering: true,
            isSeeking: false,
            generation: 1
        )
        XCTAssertEqual(clock.currentTime(at: 110), 13, accuracy: 0.001)
    }

    func testSelectionRejectsLateAndLowerAuthorityResults() {
        let sessionID = UUID()
        var selection = DanmakuSessionSelection(playbackSessionID: sessionID, runtimeGeneration: 5)
        let automatic = source("auto", generation: 5)
        let user = source("user", generation: 5)
        let initialRevision = selection.selectionRevision
        XCTAssertTrue(selection.select(
            user,
            authority: .userSelection,
            playbackSessionID: sessionID,
            runtimeGeneration: 5,
            basedOnRevision: initialRevision
        ))
        XCTAssertFalse(selection.select(
            automatic,
            authority: .automaticMatch,
            playbackSessionID: sessionID,
            runtimeGeneration: 5,
            basedOnRevision: selection.selectionRevision
        ))
        XCTAssertFalse(selection.select(
            automatic,
            authority: .userSelection,
            playbackSessionID: sessionID,
            runtimeGeneration: 4,
            basedOnRevision: selection.selectionRevision
        ))
        XCTAssertEqual(selection.selectedSource?.stable.resourceID, "user")
    }

    func testAmbiguousProvidedSourcesRequireSelection() {
        let sources = [source("one", generation: 1), source("two", generation: 1)]
        XCTAssertNil(DanmakuProvidedSourcePolicy.automaticSource(from: sources))

        var preferred = sources
        preferred[1].isPreferred = true
        XCTAssertEqual(
            DanmakuProvidedSourcePolicy.automaticSource(from: preferred)?.stable.resourceID,
            "two"
        )
    }

    func testLaneSchedulerDropsCollisionInsteadOfDelaying() {
        var scheduler = DanmakuLaneScheduler(laneCount: 1)
        XCTAssertNotNil(scheduler.reserve(at: 1, textWidth: 100, viewportWidth: 500, lifetime: 6))
        XCTAssertNil(scheduler.reserve(at: 1.1, textWidth: 80, viewportWidth: 500, lifetime: 6))
        XCTAssertNotNil(scheduler.reserve(at: 3, textWidth: 80, viewportWidth: 500, lifetime: 6))
    }

    private func source(_ id: String, generation: UInt64) -> DanmakuSourceDescriptor {
        DanmakuSourceDescriptor(
            stable: StableDanmakuLocator(
                kind: .providerEpisode,
                provider: "test",
                resourceID: id,
                displayName: id
            ),
            runtime: RuntimeDanmakuLocator(
                url: URL(string: "https://example.com/\(id).xml")!,
                runtimeGeneration: generation
            )
        )
    }
}
