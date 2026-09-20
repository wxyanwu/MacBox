import XCTest
@testable import OKVideoCore

final class EPGMatchingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 100)
    private func channel(_ name: String, id: String? = nil, alias: String? = nil) -> LiveChannel {
        LiveChannel(groupName: "Group", name: name, tvgID: id, tvgName: alias, streams: [])
    }
    private func guide(_ channels: [EPGChannel], programmes: [EPGProgramme]? = nil) -> XMLTVGuide {
        XMLTVGuide(channels: channels, programmes: programmes ?? channels.map {
            EPGProgramme(channelID: $0.id, title: $0.displayName, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 200))
        })
    }
    func testExactIDWinsOverConflictingNames() {
        let g = guide([.init(id: "one", displayName: "CCTV1"), .init(id: "two", displayName: "CCTV2")])
        let match = XMLTVChannelMatcher(guide: g).match(channel("CCTV-2", id: "one"))
        XCTAssertEqual(match.kind, .exact); XCTAssertEqual(match.channelID, "one")
    }
    func testNonemptyUnknownIDNeverFallsBack() {
        let g = guide([.init(id: "one", displayName: "CCTV1")])
        let c = channel("CCTV-1", id: "missing", alias: "CCTV1")
        XCTAssertEqual(XMLTVChannelMatcher(guide: g).match(c).kind, .unmatched)
        XCTAssertNil(XMLTVScheduleIndex(guide: g).currentAndNext(for: c, at: date).current)
    }
    func testExactChannelWithoutProgrammesDoesNotUseAnotherChannel() {
        let p = EPGProgramme(channelID: "two", title: "Wrong", start: date.addingTimeInterval(-10), end: date.addingTimeInterval(10))
        let g = guide([.init(id: "one", displayName: "One"), .init(id: "two", displayName: "Two")], programmes: [p])
        let c = channel("Two", id: "one")
        XCTAssertEqual(XMLTVChannelMatcher(guide: g).match(c).kind, .exact)
        XCTAssertNil(XMLTVScheduleIndex(guide: g).currentAndNext(for: c, at: date).current)
    }
    func testCCTVSeparatorsAndUnicode() {
        let matcher = XMLTVChannelMatcher(guide: guide([.init(id: "CCTV1", displayName: "CCTV1")]))
        for name in ["CCTV-1", "CCTV 1", "CCTV1", "  cctv   1  ", "ＣＣＴＶ－１"] {
            XCTAssertEqual(matcher.match(channel(name)).kind, .normalizedUnique, name)
        }
        XCTAssertEqual(matcher.match(channel("CCTV1", id: " \n")).kind, .normalizedUnique)
        for number in 1...17 {
            let id = "CCTV\(number)"
            let indexed = XMLTVChannelMatcher(guide: guide([.init(id: id, displayName: id)]))
            for name in ["CCTV-\(number)", "CCTV \(number)", id] {
                XCTAssertEqual(indexed.match(channel(name)).channelID, id)
            }
        }
    }
    func testPlusIsIdentityNotDecoration() {
        let matcher = XMLTVChannelMatcher(guide: guide([.init(id: "CCTV5", displayName: "CCTV5")]))
        XCTAssertEqual(matcher.match(channel("CCTV-5")).kind, .normalizedUnique)
        XCTAssertEqual(matcher.match(channel("CCTV-5+")).kind, .unmatched)
        let plus = XMLTVChannelMatcher(guide: guide([.init(id: "CCTV5+", displayName: "CCTV5+")]))
        XCTAssertEqual(plus.match(channel("CCTV-5+")).kind, .normalizedUnique)
        XCTAssertEqual(plus.match(channel("CCTV-5")).kind, .unmatched)
    }
    func testThirteenNeverMatchesOne() {
        let matcher = XMLTVChannelMatcher(guide: guide([.init(id: "CCTV1", displayName: "CCTV1")]))
        XCTAssertEqual(matcher.match(channel("CCTV-13")).kind, .unmatched)
    }
    func testUniqueQualitySuffix() {
        let matcher = XMLTVChannelMatcher(guide: guide([.init(id: "hn", displayName: "湖南卫视")]))
        for name in ["湖南卫视高清", "湖南卫视超清", "湖南卫视 HD"] {
            XCTAssertEqual(matcher.match(channel(name)).kind, .normalizedUnique)
        }
    }
    func testQualitySuffixCollisionIsAmbiguousEvenWithDirectName() {
        let g = guide([.init(id: "hn", displayName: "湖南卫视"), .init(id: "hnHD", displayName: "湖南卫视高清")])
        XCTAssertEqual(XMLTVChannelMatcher(guide: g).match(channel("湖南卫视高清")).kind, .ambiguous)
        XCTAssertNil(XMLTVScheduleIndex(guide: g).currentAndNext(for: channel("湖南卫视"), at: date).current)
    }
    func testDisplayAndTVGNameConflictsAreAmbiguous() {
        let g = guide([.init(id: "a", displayName: "CCTV1"), .init(id: "b", displayName: "CCTV2")])
        XCTAssertEqual(XMLTVChannelMatcher(guide: g).match(channel("CCTV-1", alias: "CCTV2")).kind, .ambiguous)
    }
    func testAliasesForSameChannelDoNotCreateAmbiguity() throws {
        let xml = #"<tv><channel id="one"><display-name>CCTV1</display-name><display-name>主频道</display-name></channel></tv>"#
        let parsed = try XMLTVParser().parse(Data(xml.utf8))
        XCTAssertEqual(parsed.channels.count, 1)
        XCTAssertEqual(parsed.channels.first?.aliases, ["主频道"])
        XCTAssertEqual(XMLTVChannelMatcher(guide: parsed).match(channel("CCTV-1", alias: "主频道")).kind, .normalizedUnique)
    }
    func testProgrammeAvailabilityNeverResolvesAmbiguity() {
        let g = guide([.init(id: "a", displayName: "CCTV1"), .init(id: "b", displayName: "CCTV 1")],
            programmes: [.init(channelID: "a", title: "Only A has current", start: date.addingTimeInterval(-1), end: date.addingTimeInterval(1))])
        XCTAssertEqual(XMLTVChannelMatcher(guide: g).match(channel("CCTV-1")).kind, .ambiguous)
        XCTAssertNil(XMLTVScheduleIndex(guide: g).currentAndNext(for: channel("CCTV-1"), at: date).current)
    }
    func testUnknownNamesAndGeneralPunctuationAreNotGuessed() {
        let matcher = XMLTVChannelMatcher(guide: guide([.init(id: "a", displayName: "ABC-1"), .init(id: "b", displayName: "湖南卫视")]))
        for name in ["ABC1", "湖南", "湖南卫视国际", "央视一套", "Unrelated"] {
            XCTAssertEqual(matcher.match(channel(name)).kind, .unmatched)
        }
    }
    func testLegacyChannelCacheWithoutAliasesStillDecodes() throws {
        let c = try JSONDecoder().decode(EPGChannel.self, from: Data(#"{"id":"one","displayName":"CCTV1"}"#.utf8))
        XCTAssertNil(c.aliases)
        XCTAssertEqual(XMLTVChannelMatcher(guide: guide([c])).match(channel("CCTV-1")).kind, .normalizedUnique)
    }
}
