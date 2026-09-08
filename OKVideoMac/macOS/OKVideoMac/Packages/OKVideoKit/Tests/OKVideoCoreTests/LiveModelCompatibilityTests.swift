import Foundation
import XCTest
@testable import OKVideoCore

final class LiveModelCompatibilityTests: XCTestCase {
    private let providerID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testImportedAndXtreamSourcesWithSameUUIDAreDistinct() {
        let imported = LiveSourceID.imported(providerID)
        let xtream = LiveSourceID.xtream(providerID)
        XCTAssertNotEqual(imported, xtream)
        XCTAssertEqual(Set([imported, xtream]).count, 2)
        let descriptor = LiveSourceDescriptor(
            id: xtream, name: "Native", canRefresh: true,
            canExport: false, supportsEPG: false
        )
        XCTAssertEqual(descriptor.kind, .xtream)
        XCTAssertFalse(descriptor.canExport)
        XCTAssertFalse(descriptor.supportsEPG)
        XCTAssertEqual(LiveCatalogSnapshot(sourceID: imported, groups: []).sourceID, imported)
    }

    func testLegacyIdentityAndEncodedFieldsRemainUnchanged() throws {
        let raw = #"{"name":"News","channels":[{"groupName":"News","name":"Channel::One","streams":[{"name":"Main","url":"https://example.invalid/a%2Fb?value=%7E","headers":{"User-Agent":"Legacy"},"needsParsing":false}]}]}"#
        let legacyData = Data(raw.utf8)
        let group = try JSONDecoder().decode(LiveGroup.self, from: legacyData)
        let channel = try XCTUnwrap(group.channels.first)
        let stream = try XCTUnwrap(channel.streams.first)
        XCTAssertEqual(group.id, "News")
        XCTAssertEqual(channel.id, "News::Channel::One")
        XCTAssertEqual(channel.groupID, "News")
        XCTAssertEqual(stream.id, "https://example.invalid/a%2Fb?value=%7E")
        XCTAssertEqual(stream.url?.absoluteString, stream.id)
        let actual = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(group))
        XCTAssertEqual(actual, try JSONDecoder().decode(JSONValue.self, from: legacyData))
        XCTAssertNil(group.explicitID)
        XCTAssertNil(channel.explicitID)
        XCTAssertNil(channel.explicitGroupID)
    }

    func testExplicitChannelIdentitySurvivesDisplayRenameAndCategoryMove() throws {
        var channel = LiveChannel(
            groupName: "Before", name: "Same Name", streams: [try nativeStream()],
            explicitID: "xtream.channel.a.42", explicitGroupID: "xtream.group.a.1"
        )
        var group = LiveGroup(name: "Before", channels: [channel], explicitID: "xtream.group.a.1")
        group.name = "Renamed"
        channel.name = "Renamed Channel"
        channel.groupName = "New Category"
        channel.explicitGroupID = "xtream.group.a.2"
        XCTAssertEqual(group.id, "xtream.group.a.1")
        XCTAssertEqual(channel.id, "xtream.channel.a.42")
        XCTAssertEqual(channel.groupID, "xtream.group.a.2")
        XCTAssertEqual(
            try JSONDecoder().decode(LiveChannel.self, from: JSONEncoder().encode(channel)),
            channel
        )
    }

    func testLegacyStreamDecoderDoesNotInventMissingRequiredFields() {
        for raw in [
            #"{"name":"A","url":"https://example.invalid/a","needsParsing":false}"#,
            #"{"name":"A","url":"https://example.invalid/a","headers":{}}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(LiveStream.self, from: Data(raw.utf8)))
        }
    }

    func testProviderStreamHasOnlyAFormalReferenceAndNoDirectURL() throws {
        let stream = try nativeStream()
        XCTAssertNil(stream.url)
        let data = try JSONEncoder().encode(stream)
        let object = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
        XCTAssertEqual(object["targetVersion"], .integer(1))
        XCTAssertNotNil(object["providerResourceReference"])
        for forbidden in ["url", "headers", "needsParsing"] {
            XCTAssertNil(object[forbidden])
        }
        XCTAssertEqual(try JSONDecoder().decode(LiveStream.self, from: data), stream)
        XCTAssertNotEqual(stream.id, try nativeStream(format: .m3u8).id)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("https://"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("episodeIdentity"))
    }

    func testProviderStreamRejectsUnknownOrAmbiguousTargets() throws {
        let original = try XCTUnwrap(JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(nativeStream())
        ).objectValue)
        for replacement in [
            ["targetVersion": JSONValue.integer(2)],
            ["url": JSONValue.string("https://example.invalid/not-a-fallback")],
            ["headers": JSONValue.object(["Authorization": .string("Bearer test-secret")])],
            ["needsParsing": JSONValue.bool(true)],
            ["format": JSONValue.string("mp4")]
        ] {
            var object = original
            object.merge(replacement) { _, new in new }
            XCTAssertThrowsError(try JSONDecoder().decode(
                LiveStream.self, from: JSONEncoder().encode(JSONValue.object(object))
            ))
        }
    }

    func testMutatedProviderStreamCannotEncodeHeadersOrEpisodeReference() throws {
        var stream = try nativeStream()
        stream.headers = ["Cookie": "session=test-secret"]
        XCTAssertThrowsError(try JSONEncoder().encode(stream))
        stream.headers = [:]
        stream.needsParsing = true
        XCTAssertThrowsError(try JSONEncoder().encode(stream))
        stream.needsParsing = false
        guard case .provider(var reference) = stream.target else { return XCTFail("Expected provider") }
        reference.schemaVersion = 1
        stream.target = .provider(reference)
        XCTAssertThrowsError(try JSONEncoder().encode(stream))
        XCTAssertNil(stream.url)
    }

    func testDefaultHeadersOnlyApplyToDirectTargetsWithLegacyPrecedence() throws {
        let direct = LiveStream(
            name: "Direct", url: URL(string: "https://example.invalid/a")!,
            headers: ["User-Agent": "ChannelAgent"]
        )
        let native = try nativeStream()
        let playlist = LivePlaylist(format: .json, groups: [LiveGroup(
            name: "Group", channels: [LiveChannel(groupName: "Group", name: "A", streams: [direct, native])]
        )])
        let applied = playlist.applyingDefaultHeaders([
            "User-Agent": "SourceAgent", "Authorization": "Bearer imported-only"
        ])
        let streams = try XCTUnwrap(applied.groups.first?.channels.first?.streams)
        XCTAssertEqual(streams[0].headers, [
            "User-Agent": "ChannelAgent", "Authorization": "Bearer imported-only"
        ])
        XCTAssertEqual(streams[1], native)
        XCTAssertNoThrow(try JSONEncoder().encode(streams[1]))
        XCTAssertEqual(playlist.groups.first?.channels.first?.streams.first, direct)
    }

    func testAllLegacySourceFormatsRetainOriginalInputBytesAndIDs() async throws {
        let samples: [(String, LiveSourceFormat)] = [
            ("#EXTM3U\r\n#EXTINF:-1 group-title=\"Group\",One\r\nhttps://example.invalid/a%2Fb\r\n", .m3u),
            ("Group,#genre#\r\nOne,https://example.invalid/a%2Fb\r\n", .text),
            (#"[{"name":"Group","channel":[{"name":"One","urls":["https://example.invalid/a%2Fb"]}]}]"#, .json)
        ]
        let loader = LiveSourceLoader(httpClient: UnexpectedLiveModelHTTPClient())
        for (text, format) in samples {
            let loaded = try await loader.load(.pasted(text: text, baseURL: nil))
            XCTAssertEqual(loaded.rawData, Data(text.utf8))
            XCTAssertEqual(loaded.playlist.format, format)
            XCTAssertEqual(loaded.playlist.groups.first?.id, "Group")
            XCTAssertEqual(loaded.playlist.groups.first?.channels.first?.id, "Group::One")
            XCTAssertEqual(loaded.playlist.groups.first?.channels.first?.streams.first?.id, "https://example.invalid/a%2Fb")
        }
    }

    private func nativeStream(format: XtreamLiveOutputFormat = .ts) throws -> LiveStream {
        try LiveStream(
            name: "Native", target: .provider(.xtreamLive(XtreamLivePlaybackLocator(
                providerID: providerID, streamID: "42", outputFormat: format
            ))), format: format.rawValue
        )
    }
}

private struct UnexpectedLiveModelHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw AppError.live("Legacy pasted-source compatibility tests must not make requests")
    }
}
