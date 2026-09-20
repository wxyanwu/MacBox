import Foundation
import XCTest
import OKVideoCore
@testable import EPGBaseline

final class SemanticsTests: XCTestCase {
    func testCacheGuardUsesRealpathNotFoundationTmpAlias() throws {
        let path = "/private/tmp/OKVideoMac-9A.Guard-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
        defer { try? fm.removeItem(atPath: path) }
        let child = path + "/Cache-test"
        XCTAssertTrue(safeSyntheticCachePath(child))
        try fm.createDirectory(atPath: child, withIntermediateDirectories: false)
        XCTAssertTrue(safeSyntheticCachePath(child))
        try fm.createSymbolicLink(atPath: path + "/Cache-link", withDestinationPath: child)
        XCTAssertFalse(safeSyntheticCachePath(path + "/Cache-link"))
        XCTAssertFalse(safeSyntheticCachePath("/tmp/OKVideoMac-9A.Guard/Cache-test"))
        XCTAssertFalse(safeSyntheticCachePath(path + "/../Cache-escape"))
    }
    func programme(_ start: Double, _ end: Double, _ title: String = "P") -> EPGProgramme {
        EPGProgramme(channelID: "a", title: title, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }
    func guide(_ programmes: [EPGProgramme]) -> XMLTVGuide {
        XMLTVGuide(channels: [EPGChannel(id: "a", displayName: "A")], programmes: programmes)
    }
    func testEndEqualsNowIsNotCurrent() {
        let index = XMLTVScheduleIndex(guide: guide([programme(0, 10)]))
        XCTAssertNil(index.currentAndNext(for: liveChannel("a"), at: Date(timeIntervalSince1970: 10)).current)
    }
    func testProductionIndexOverlapDiffersFromLegacyGuideHelper() {
        let value = guide([programme(0,100,"older"), programme(5,20,"newer")])
        let now = Date(timeIntervalSince1970: 10)
        XCTAssertEqual(value.currentAndNext(channelID: "a", at: now).current?.title, "older")
        XCTAssertEqual(XMLTVScheduleIndex(guide: value).currentAndNext(for: liveChannel("a"), at: now).current?.title, "newer")
    }
    func testEqualStartProductionUsesLastSurvivingInputOccurrence() {
        let index = XMLTVScheduleIndex(guide: guide([programme(0,100,"first"), programme(0,100,"second")]))
        XCTAssertEqual(index.currentAndNext(for: liveChannel("a"), at: Date(timeIntervalSince1970: 10)).current?.title, "second")
    }
    func testGapAndExpiredRecentOverlapFallsBackToLongProgramme() {
        let index = XMLTVScheduleIndex(guide: guide([programme(0,100,"long"), programme(5,10,"short"), programme(200,300,"next")]))
        XCTAssertEqual(index.currentAndNext(for: liveChannel("a"), at: Date(timeIntervalSince1970: 50)).current?.title, "long")
        let gap = index.currentAndNext(for: liveChannel("a"), at: Date(timeIntervalSince1970: 150))
        XCTAssertNil(gap.current); XCTAssertEqual(gap.next?.title, "next")
    }
    func testWindowIntersectsRatherThanStartWithin() {
        let values = [programme(-100,10), programme(0,5), programme(5,20), programme(20,30)]
        let result = values.filter { $0.start.timeIntervalSince1970 < 20 && $0.end.timeIntervalSince1970 > 5 }
        XCTAssertEqual(result, [values[0], values[2]])
    }
    func testProgrammeOnlyIDsParticipateInAmbiguityEvenOutsideWindow() {
        let value = XMLTVGuide(channels: [EPGChannel(id: "a", displayName: "CCTV1")],
            programmes: [EPGProgramme(channelID: "CCTV1", title: "expired", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1))])
        XCTAssertEqual(XMLTVChannelMatcher(guide: value).match(liveChannel(nil, name:"CCTV-1")).kind, .ambiguous)
        XCTAssertEqual(XMLTVChannelMatcher(guide: value).match(liveChannel("a", name:"CCTV-1")).kind, .exact)
    }
    func testNonemptyUnmatchedIDNeverFallsBack() {
        XCTAssertEqual(XMLTVChannelMatcher(guide: guide([])).match(liveChannel("missing", name:"A")).kind, .unmatched)
    }
    func testUnicodeIDAndMultipleAliasesMatchExistingSwiftSemantics() {
        let value = XMLTVGuide(channels: [EPGChannel(id:"é", displayName:"A", aliases:["CCTV1", "中央一套"])], programmes: [])
        let matcher = XMLTVChannelMatcher(guide:value)
        XCTAssertEqual(matcher.match(liveChannel("e\u{301}")).kind, .exact)
        XCTAssertEqual(matcher.match(liveChannel(nil, name:"CCTV-1")).channelID, "é")
    }
    func testMidnightTimezoneAndEmptyValidXML() throws {
        let value = try XMLTVParser().parse(Data("<tv><programme channel='a' start='20260913235900 +0800' stop='20260914003000 +0800'><title>T</title></programme></tv>".utf8))
        XCTAssertEqual(value.programmes.first?.end.timeIntervalSince(value.programmes[0].start), 1860)
        XCTAssertTrue(try XMLTVParser().parse(Data("<tv/>".utf8)).programmes.isEmpty)
    }
    func testInvalidProgrammeIgnoredButMalformedDocumentFails() throws {
        let xml = "<tv><programme channel='a' start='bad' stop='bad'><title>X</title></programme><programme channel='a' start='20260913000000 +0000' stop='20260913010000 +0000'><title>Y</title></programme></tv>"
        XCTAssertEqual(try XMLTVParser().parse(Data(xml.utf8)).programmes.map(\.title), ["Y"])
        XCTAssertThrowsError(try XMLTVParser().parse(Data(xml.dropLast(5).utf8)))
    }
    func testPercentileNearestRankAndConsumerChecksum() {
        let value = distribution((1...100).map(Double.init), checksum:77)
        XCTAssertEqual(value.p50ms,50); XCTAssertEqual(value.p95ms,95); XCTAssertEqual(value.checksum,77)
    }
    func testCanonicalDigestSensitiveToAliasAndOrdering() {
        var value = guide([programme(0,10)])
        let before = semanticDigest(value)
        value.channels[0].aliases = ["B"]
        XCTAssertNotEqual(before,semanticDigest(value))
        XCTAssertEqual(semanticDigest(value),semanticDigest(value))
    }
}
