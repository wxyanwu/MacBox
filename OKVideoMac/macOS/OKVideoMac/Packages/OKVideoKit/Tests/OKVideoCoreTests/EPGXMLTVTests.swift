import XCTest
@testable import OKVideoCore

final class EPGXMLTVTests: XCTestCase {
    func testWellFormedNonXMLTVAndWhollyInvalidSchedulesCannotReplaceCache() throws {
        XCTAssertThrowsError(try XMLTVParser().parse(Data("<html><body>Unavailable</body></html>".utf8)))
        XCTAssertThrowsError(try XMLTVParser().parse(Data(#"<tv><programme channel="1" start="bad" stop="bad"><title>Invalid</title></programme></tv>"#.utf8)))
        XCTAssertTrue(try XMLTVParser().parse(Data("<tv/>".utf8)).programmes.isEmpty)
    }
    func testOffsetsDSTMidnightAndUTCDefault() throws {
        let xml = """
        <tv>
        <programme channel="a" start="20261101013000 -0400" stop="20261101013000 -0500"><title>DST</title></programme>
        <programme channel="b" start="20260910233000 +0800" stop="20260911003000 +0800"><title>午夜</title></programme>
        <programme channel="c" start="20260910153000" stop="20260910163000"><title>UTC</title></programme>
        </tv>
        """
        let guide = try XMLTVParser().parse(Data(xml.utf8))
        XCTAssertEqual(guide.programmes.count, 3)
        XCTAssertTrue(guide.programmes.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
        XCTAssertEqual(guide.programmes[1].start, guide.programmes[2].start)
    }

    func testAmbiguousNamesDoNotBindButExactIDWins() {
        let date = Date(timeIntervalSince1970: 50)
        let guide = XMLTVGuide(channels: [EPGChannel(id: "a", displayName: "新闻"), EPGChannel(id: "b", displayName: "新闻")],
                              programmes: ["a", "b"].map { EPGProgramme(channelID: $0, title: $0, start: .init(timeIntervalSince1970: 0), end: .init(timeIntervalSince1970: 100)) })
        let index = XMLTVScheduleIndex(guide: guide)
        var channel = LiveChannel(groupName: "", name: "新闻", streams: [])
        XCTAssertNil(index.currentAndNext(for: channel, at: date).current)
        channel.tvgID = "b"
        XCTAssertEqual(index.currentAndNext(for: channel, at: date).current?.title, "b")
    }

    func testMalformedXMLAndCancellationAreNotEmptySuccess() async throws {
        XCTAssertThrowsError(try XMLTVParser().parse(Data("<tv><programme>".utf8)))
        let task = Task { () throws -> XMLTVGuide in
            while !Task.isCancelled { await Task.yield() }
            return try XMLTVParser().parse(Data("<tv/>".utf8))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }
}
