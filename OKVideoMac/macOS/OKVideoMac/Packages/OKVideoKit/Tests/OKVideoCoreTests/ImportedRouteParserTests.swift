import Foundation
import XCTest
@_spi(MigrationDiagnostics) import OKVideoCore

final class ImportedRouteParserTests: XCTestCase {
    private let url = "https://fixture.invalid/live"

    private func entry(_ extra: String = "", route: String? = nil, attributes: String = "") -> String {
        "#EXTINF:-1 group-title=\"G\" \(attributes),Channel\n\(extra)\(route ?? url)\n"
    }

    private func parse(_ text: String, base: URL? = nil) throws -> (LivePlaylist, [LiveParserObservation]) {
        var observations: [LiveParserObservation] = []
        let playlist = try LiveSourceParser().parseObserving(Data(text.utf8), baseURL: base) { observations.append($0) }
        XCTAssertEqual(playlist, try LiveSourceParser().parse(text, baseURL: base))
        return (playlist, observations)
    }

    private func routes(_ playlist: LivePlaylist) throws -> [LiveStream] {
        XCTAssertEqual(playlist.groups.count, 1)
        let group = try XCTUnwrap(playlist.groups.first)
        XCTAssertEqual(group.channels.count, 1)
        let channel = try XCTUnwrap(group.channels.first)
        XCTAssertEqual(channel.id, "G::Channel")
        return channel.streams
    }

    func testM3USameURLDifferentHeadersPreserved() throws {
        let (p, raw) = try parse("#EXTM3U\n" + entry("ua=A\n") + entry("ua=B\n"))
        XCTAssertEqual(try routes(p).map { $0.headers["User-Agent"] }, ["A", "B"])
        XCTAssertEqual(raw.count, 2)
        XCTAssertEqual(raw.map(\.ordinal), [1, 2])
        XCTAssertEqual(raw.flatMap(\.streams), try routes(p))
    }

    func testM3UFormatVariantsPreserved() throws {
        let (p, _) = try parse("#EXTM3U\n" + entry() + entry("format=ts\n") + entry("format=m3u8\n"))
        XCTAssertEqual(try routes(p).map(\.format), [nil, "ts", "m3u8"])
    }

    func testM3UParsingVariantsPreserved() throws {
        let (p, _) = try parse("#EXTM3U\n" + entry() + entry("parse=1\n") + entry("parse=0\n"))
        XCTAssertEqual(try routes(p).map(\.needsParsing), [false, true])
    }

    func testM3UExactDuplicateRetainsFirstLabelAndRawRecords() throws {
        let (p, raw) = try parse("#EXTM3U\n" + entry(route: url + "$First") + entry(route: url + "$Alias"))
        XCTAssertEqual(try routes(p).map(\.name), ["First"])
        XCTAssertEqual(raw.flatMap(\.streams).map(\.name), ["First", "Alias"])
    }

    func testHeaderOrderDoesNotCreateVariantButCaseDoes() throws {
        let (p, raw) = try parse("#EXTM3U\n" + entry("#EXTHTTP:{\"X\":\"1\",\"Y\":\"2\"}\n")
            + entry("#EXTHTTP:{\"Y\":\"2\",\"X\":\"1\"}\n") + entry("#EXTHTTP:{\"x\":\"1\",\"Y\":\"2\"}\n"))
        XCTAssertEqual(try routes(p).count, 2)
        XCTAssertEqual(raw.count, 3)
    }

    func testMergedHeadersComparedAfterParserOverrides() throws {
        let (p, _) = try parse("#EXTM3U\nglobal-header=User-Agent=Global\n"
            + entry("ua=Override\n", route: url + "|User-Agent=Final")
            + entry("ua=Final\n") + entry())
        XCTAssertEqual(try routes(p).map { $0.headers["User-Agent"] }, ["Final", "Global"])
    }

    func testRestoreVariantAtFirstOccurrenceWithoutReorderingOtherRoutes() throws {
        let (p, _) = try parse("#EXTM3U\n" + entry("ua=A\n", route: url + "$A")
            + entry(route: url + "-other$Other") + entry("ua=B\n", route: url + "$B")
            + entry("ua=A\n", route: url + "$Duplicate") + entry("ua=B\n", route: url + "$DuplicateB"))
        XCTAssertEqual(try routes(p).map(\.name), ["A", "Other", "B"])
    }

    func testGroupingIDsEPGAndFirstMetadataStayUnchanged() throws {
        let first = "tvg-id=\"1\" tvg-name=\"Alias1\" tvg-chno=\"10\" tvg-logo=\"https://fixture.invalid/logo1\""
        let second = "tvg-id=\"2\" tvg-name=\"Alias2\" tvg-chno=\"20\" tvg-logo=\"https://fixture.invalid/logo2\""
        let (p, raw) = try parse("#EXTM3U x-tvg-url=\"https://fixture.invalid/epg.xml\"\n"
            + entry("ua=A\n", attributes: first) + entry("ua=B\n", attributes: second))
        XCTAssertEqual(try routes(p).count, 2)
        let c = p.groups[0].channels[0]
        XCTAssertEqual(c.tvgID, "1"); XCTAssertEqual(c.tvgName, "Alias1"); XCTAssertEqual(c.number, "10")
        XCTAssertEqual(c.logoURL?.absoluteString, "https://fixture.invalid/logo1")
        XCTAssertEqual(p.epgURL?.absoluteString, "https://fixture.invalid/epg.xml")
        XCTAssertEqual(p.groups[0].id, "G")
        XCTAssertEqual(raw.map(\.tvgID), ["1", "2"])
        XCTAssertEqual(raw.map(\.tvgName), ["Alias1", "Alias2"])
    }

    func testTXTHeaderVariantsAndDuplicateLabels() throws {
        let (p, raw) = try parse("G,#genre#\nChannel,\(url)$First|Cookie=A#\(url)$Second|Cookie=B#\(url)$Alias|Cookie=A\n")
        XCTAssertEqual(try routes(p).map(\.name), ["First", "Second"])
        XCTAssertEqual(try routes(p).map { $0.headers["Cookie"] }, ["A", "B"])
        XCTAssertEqual(raw.count, 1); XCTAssertEqual(raw[0].streams.count, 3)
    }

    func testTXTFormatAndParsingVariants() throws {
        let (p, raw) = try parse("G,#genre#\nChannel,\(url)\nformat=ts\nChannel,\(url)\nparse=1\nChannel,\(url)\n")
        XCTAssertEqual(try routes(p).map(\.format), [nil, "ts", "ts"])
        XCTAssertEqual(try routes(p).map(\.needsParsing), [false, false, true])
        XCTAssertEqual(raw.count, 3)
    }

    func testProtectedGroupAndGroupOrderUnchanged() throws {
        let (p, _) = try parse("Z_password,#genre#\nX,\(url)\nG_secret,#genre#\nChannel,\(url)|Cookie=A#\(url)|Cookie=B\n")
        XCTAssertEqual(p.groups.map(\.name), ["Z", "G"])
        XCTAssertEqual(p.groups.map(\.password), ["password", "secret"])
        XCTAssertEqual(p.groups.flatMap(\.channels).map(\.id), ["Z::X", "G::Channel"])
        XCTAssertEqual(p.groups[1].channels[0].streams.count, 2)
    }

    private func json(_ urls: [String], duplicateChannel: Bool = false) throws -> String {
        let channel: [String: Any] = ["name": "Channel", "tvgId": "one", "tvgName": "Alias", "format": "ts", "parse": 1, "urls": urls]
        let data = try JSONSerialization.data(withJSONObject: [["name": "G", "channel": duplicateChannel ? [channel, channel] : [channel]]], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testJSONExactDuplicateRetainsFirstOccurrenceAndRawLines() throws {
        let (p, raw) = try parse(json([url + "$First", url + "$Alias", url + "-other$Other"]))
        XCTAssertEqual(try routes(p).map(\.name), ["First", "Other"])
        XCTAssertEqual(raw[0].streams.map(\.name), ["First", "Alias", "Other"])
    }

    func testJSONSameURLDifferentHeadersPreserved() throws {
        let (p, _) = try parse(json([url + "|Cookie=A", url + "|Cookie=B", url + "|Cookie=A"]))
        XCTAssertEqual(try routes(p).map { $0.headers["Cookie"] }, ["A", "B"])
        XCTAssertEqual(try routes(p).map(\.format), ["ts", "ts"])
        XCTAssertEqual(try routes(p).map(\.needsParsing), [true, true])
    }

    func testJSONDoesNotMergeDistinctChannelRecordsWithSameID() throws {
        let (p, raw) = try parse(json([url, url + "$Alias"], duplicateChannel: true))
        let channels = p.groups[0].channels
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels.map(\.id), ["G::Channel", "G::Channel"])
        XCTAssertEqual(channels.map { $0.streams.count }, [1, 1])
        XCTAssertEqual(channels.map(\.tvgID), ["one", "one"])
        XCTAssertEqual(raw.count, 2); XCTAssertEqual(raw.map { $0.streams.count }, [2, 2])
    }

    func testValidURLBytesRemainDistinctThroughAllThreeParsers() throws {
        let urls = [url + "%2fpath?a=%7E&b=2", url + "%2Fpath?a=%7E&b=2", url + "/path?a=~&b=2",
                    url + "%2fpath?b=2&a=%7E", url + "%2fpath?a=%7e&b=2", url + "%2fpath?a=%7E&b=2&b=2"]
        let inputs = ["#EXTM3U\n" + urls.map { entry(route: $0) }.joined(),
                      "G,#genre#\nChannel," + urls.joined(separator: "#"), try json(urls)]
        for input in inputs {
            let (p, raw) = try parse(input)
            XCTAssertEqual(try routes(p).map { $0.url?.absoluteString }, urls)
            XCTAssertEqual(raw.flatMap(\.streams).map { $0.url?.absoluteString }, urls)
        }
    }

    func testExistingInvalidEscapeRepairNotRepeatedByEquality() throws {
        let (p, raw) = try parse("#EXTM3U\n" + entry(route: url + "?x=%0&y=a b")
            + entry(route: url + "?x=%250&y=a%20b"))
        let expected = url + "?x=%250&y=a%20b"
        XCTAssertEqual(raw.flatMap(\.streams).map { $0.url?.absoluteString }, [expected, expected])
        XCTAssertEqual(try routes(p).map { $0.url?.absoluteString }, [expected])
    }

    func testRelativeURLResolutionIsUnchanged() throws {
        let (p, raw) = try parse("#EXTM3U\n" + entry(route: "../live%2fpath?b=2&a=%7E")
            + entry(route: "https://fixture.invalid/live%2fpath?b=2&a=%7E"), base: URL(string: "https://fixture.invalid/base/list.m3u"))
        let expected = "https://fixture.invalid/live%2fpath?b=2&a=%7E"
        XCTAssertEqual(try routes(p).map { $0.url?.absoluteString }, [expected])
        XCTAssertEqual(raw.flatMap(\.streams).map { $0.url?.absoluteString }, [expected, expected])
    }

    func testEveryPermutationHasSameTransportSetAndFirstOccurrenceOrder() throws {
        let a = entry("ua=A\n", route: url + "$A"), b = entry("ua=B\n", route: url + "$B"), c = entry("ua=A\n", route: url + "$Alias")
        for input in [[a,b,c], [a,c,b], [b,a,c], [b,c,a], [c,a,b], [c,b,a]] {
            let (p, raw) = try parse("#EXTM3U\n" + input.joined())
            let streams = try routes(p)
            XCTAssertEqual(streams.count, 2)
            XCTAssertEqual(streams, ImportedRouteTransport.deduplicated(raw.flatMap(\.streams)))
            XCTAssertEqual(Set(streams.compactMap { $0.headers["User-Agent"] }), ["A", "B"])
        }
    }
}
