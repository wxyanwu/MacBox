import XCTest
@testable import OKVideoCore

/// The 9C.2 SQLite reader must reproduce these existing in-memory semantics.
/// Keep this oracle independent from persistence and SQL implementation details.
final class EPG9C2BehaviorContractTests: XCTestCase {
    private func channel(_ name: String, id: String? = nil, tvgName: String? = nil) -> LiveChannel {
        LiveChannel(groupName: "Fixture", name: name, tvgID: id, tvgName: tvgName, streams: [])
    }

    private func programme(
        _ channelID: String,
        _ title: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> EPGProgramme {
        EPGProgramme(channelID: channelID, title: title,
                     start: Date(timeIntervalSince1970: start),
                     end: Date(timeIntervalSince1970: end))
    }

    func testExactIDUsesSwiftCanonicalUnicodeEquivalence() {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let guide = XMLTVGuide(channels: [.init(id: composed, displayName: "Coffee")], programmes: [])

        let match = XMLTVChannelMatcher(guide: guide).match(channel("ignored", id: decomposed))

        XCTAssertEqual(match.kind, .exact)
        XCTAssertEqual(match.channelID, composed)
    }

    func testProgrammeOnlyChannelIDAlsoSuppliesNameAliases() {
        let guide = XMLTVGuide(
            channels: [],
            programmes: [programme("CCTV-1", "Programme-only", start: 0, end: 200)]
        )

        let match = XMLTVChannelMatcher(guide: guide).match(channel("CCTV1"))

        XCTAssertEqual(match.kind, .normalizedUnique)
        XCTAssertEqual(match.channelID, "CCTV-1")
    }

    func testNameAndTVGNameCandidatesAreUnionedBeforeAmbiguityDecision() {
        let guide = XMLTVGuide(
            channels: [
                .init(id: "one", displayName: "CCTV1"),
                .init(id: "two", displayName: "CCTV2")
            ],
            programmes: []
        )

        let match = XMLTVChannelMatcher(guide: guide)
            .match(channel("CCTV-1", tvgName: "CCTV2"))

        XCTAssertEqual(match.kind, .ambiguous)
        XCTAssertNil(match.channelID)
    }

    func testNowNextUsesHalfOpenTimeBoundsAndDoesNotFillGaps() {
        let guide = XMLTVGuide(
            channels: [.init(id: "one", displayName: "One")],
            programmes: [
                programme("one", "First", start: 10, end: 20),
                programme("one", "Second", start: 30, end: 40)
            ]
        )
        let index = XMLTVScheduleIndex(guide: guide)
        let live = channel("One", id: "one")

        XCTAssertEqual(index.currentAndNext(for: live, at: Date(timeIntervalSince1970: 10)).current?.title, "First")
        let boundary = index.currentAndNext(for: live, at: Date(timeIntervalSince1970: 20))
        XCTAssertNil(boundary.current)
        XCTAssertEqual(boundary.next?.title, "Second")
        let gap = index.currentAndNext(for: live, at: Date(timeIntervalSince1970: 25))
        XCTAssertNil(gap.current)
        XCTAssertEqual(gap.next?.title, "Second")
        XCTAssertEqual(index.currentAndNext(for: live, at: Date(timeIntervalSince1970: 30)).current?.title, "Second")
    }

    func testSameStartUsesLastSourceOrdinalForNowAndFirstForNext() {
        let guide = XMLTVGuide(
            channels: [.init(id: "one", displayName: "One")],
            programmes: [
                programme("one", "Ordinal 0", start: 100, end: 200),
                programme("one", "Ordinal 1", start: 100, end: 200),
                programme("one", "Ordinal 2", start: 100, end: 200)
            ]
        )
        let index = XMLTVScheduleIndex(guide: guide)
        let live = channel("One", id: "one")

        XCTAssertEqual(index.currentAndNext(for: live, at: Date(timeIntervalSince1970: 100)).current?.title,
                       "Ordinal 2")
        XCTAssertEqual(index.currentAndNext(for: live, at: Date(timeIntervalSince1970: 99)).next?.title,
                       "Ordinal 0")
    }

    func testOverlappingNowSelectsLatestStartThenLatestSourceOrdinal() {
        let guide = XMLTVGuide(
            channels: [.init(id: "one", displayName: "One")],
            programmes: [
                programme("one", "Long", start: 0, end: 500),
                programme("one", "Earlier", start: 100, end: 300),
                programme("one", "Latest A", start: 150, end: 250),
                programme("one", "Latest B", start: 150, end: 260)
            ]
        )

        let result = XMLTVScheduleIndex(guide: guide)
            .currentAndNext(for: channel("One", id: "one"), at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(result.current?.title, "Latest B")
        XCTAssertNil(result.next)
    }
}
