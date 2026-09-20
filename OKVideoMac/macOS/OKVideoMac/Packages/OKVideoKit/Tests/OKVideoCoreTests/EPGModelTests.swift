import XCTest
@testable import OKVideoCore

final class EPGModelTests: XCTestCase {
    func testImportedEndBoundaryIsMaximumAndDoesNotRedefineFreshness() {
        let now = Date(timeIntervalSince1970: 1000)
        let guide = XMLTVGuide(channels: [], programmes: [100, 300, 200].map {
            EPGProgramme(channelID: "fixture", title: "Old", start: .distantPast,
                         end: Date(timeIntervalSince1970: Double($0)))
        })
        for availability in [EPGAvailability.fresh, .stale] {
            let snapshot = EPGSnapshot(key: EPGRequestKey(source: .imported(UUID()), revision: "r", resource: "xmltv"),
                availability: availability, fetchedAt: now, retryAfter: now.addingTimeInterval(60), guide: guide)
            XCTAssertEqual(snapshot.xmltvMaxProgrammeEnd, Date(timeIntervalSince1970: 300))
            XCTAssertEqual(snapshot.availability, availability)
        }
    }

    func testNoImportedCoverageBoundaryForEmptyTableOrNativeSnapshot() {
        let now = Date()
        let native = EPGSnapshot(key: EPGRequestKey(source: .xtream(UUID()), revision: "r", resource: "1"),
            availability: .fresh, fetchedAt: now, retryAfter: now,
            guide: XMLTVGuide(channels: [], programmes: [.init(channelID: "1", title: "Native", start: now, end: now.addingTimeInterval(60))]))
        XCTAssertNil(native.xmltvMaxProgrammeEnd)
        let empty = EPGSnapshot(key: EPGRequestKey(source: .imported(UUID()), revision: "r", resource: "xmltv"),
            availability: .empty, fetchedAt: now, retryAfter: now, guide: XMLTVGuide(channels: [], programmes: []))
        XCTAssertNil(empty.xmltvMaxProgrammeEnd)
    }

    func testSourceDomainsAndRevisionsNeverAlias() throws {
        let id = UUID()
        let a = EPGRequestKey(source: .imported(id), revision: "1", resource: "7")
        let b = EPGRequestKey(source: .xtream(id), revision: "1", resource: "7")
        let c = EPGRequestKey(source: .xtream(id), revision: "2", resource: "7")
        XCTAssertEqual(Set([a, b, c]).count, 3)
        XCTAssertEqual(try JSONDecoder().decode(EPGRequestKey.self, from: JSONEncoder().encode(a)), a)
    }

    func testNativeQueryUsesStreamNotDisplayNameAndProgressIsClamped() {
        let start = Date(timeIntervalSince1970: 100)
        let programme = EPGProgramme(channelID: "7", title: "News", start: start,
                                     end: start.addingTimeInterval(100))
        let guide = XMLTVGuide(channels: [], programmes: [programme])
        let snapshot = EPGSnapshot(key: EPGRequestKey(source: .xtream(UUID()), revision: "1", resource: "7"),
                                   availability: .fresh, fetchedAt: start,
                                   retryAfter: start, guide: guide)
        let channel = LiveChannel(groupName: "A", name: "Other name", tvgID: "wrong", streams: [])
        let value = snapshot.nowNext(for: channel, at: start.addingTimeInterval(50))
        XCTAssertEqual(value.current?.title, "News")
        XCTAssertEqual(value.progress(at: start.addingTimeInterval(50)), 0.5)
        XCTAssertEqual(value.progress(at: start.addingTimeInterval(500)), 1)
        XCTAssertEqual(value.progress(at: start.addingTimeInterval(-10)), 0)
        XCTAssertNil(snapshot.nowNext(for: channel, at: start.addingTimeInterval(100)).current)
    }
}
