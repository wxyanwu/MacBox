import Foundation
import XCTest
@testable import OKVideoCore
@testable import OKVideoPersistence

final class EPGGuideXMLTVLoaderTests: XCTestCase {
    private func cacheDirectory() -> URL {
        URL(fileURLWithPath: "/private/tmp/EPGCache-Guide-Loader-" + UUID().uuidString)
    }

    func testTwoSlicesDeduplicateOverlappingRecordsAndKeepOneCoherentToken() async throws {
        let directory = cacheDirectory()
        let xml = Data("""
        <tv>
          <channel id="a"><display-name>Alpha</display-name></channel>
          <programme channel="a" start="20260920000000 +0000" stop="20260920130000 +0000"><title>Long</title></programme>
          <programme channel="a" start="20260920130000 +0000" stop="20260920140000 +0000"><title>After</title></programme>
        </tv>
        """.utf8)
        let server = try EPGImportTestServer(xml: xml, gzip: Data())
        let repository = EPGProductionRepository(cacheDirectory: directory)
        defer {
            server.close()
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let source = LiveSourceID.imported(UUID())
        let revision = String(repeating: "a", count: 64)
        let key = EPGRequestKey(source: source, revision: revision, resource: "xmltv")
        let status = try await repository.refreshXMLTV(
            key: key, url: server.url("fixture.xml"), force: true
        )
        let anchor = Date(timeIntervalSince1970: 1_789_862_400)
        let channels = [
            LiveChannel(groupName: "", name: "Exact", tvgID: "a", streams: [], explicitID: "row-1"),
            LiveChannel(groupName: "", name: "Alpha", streams: [], explicitID: "row-2"),
            LiveChannel(groupName: "", name: "Missing", streams: [], explicitID: "row-3")
        ]
        let demandRevision = UUID()
        let demand = try EPGGuideDemand(
            source: EPGSourceKey(source), revision: revision,
            demandRevision: demandRevision, capability: .xmltv,
            channels: channels, visibleRange: 0..<channels.count,
            slices: [
                try EPGGuideTimeSlice(start: anchor, end: anchor.addingTimeInterval(12 * 3_600)),
                try EPGGuideTimeSlice(start: anchor.addingTimeInterval(12 * 3_600),
                                      end: anchor.addingTimeInterval(24 * 3_600))
            ]
        )

        let snapshot = try await EPGGuideXMLTVLoader.load(
            repository: repository, key: key, demand: demand,
            availability: status.availability
        )

        XCTAssertEqual(snapshot.rows[0].programmes.map(\.title), ["Long", "After"])
        XCTAssertEqual(snapshot.rows[1].programmes.map(\.title), ["Long", "After"])
        XCTAssertEqual(snapshot.rows[0].programmes.map(\.id.ordinal), [0, 1])
        XCTAssertEqual(snapshot.rows[1].programmes.map(\.id.ordinal), [0, 1])
        XCTAssertEqual(snapshot.rows[0].state, .ready)
        XCTAssertEqual(snapshot.rows[1].match.kind, .normalizedUnique)
        XCTAssertEqual(snapshot.rows[2].state, .unmatched)
        guard case .xmltv(let token) = snapshot.coherence else {
            return XCTFail("expected XMLTV coherence")
        }
        XCTAssertEqual(token.dataVersion, status.summary?.dataVersion)
        XCTAssertEqual(token.demandRevision, demandRevision)
        XCTAssertTrue(snapshot.rows.compactMap(\.token).allSatisfy { $0 == token })
        let closed = await repository.close()
        XCTAssertTrue(closed)
    }

    func testLegalEmptyGenerationProducesSuccessfulZeroProgrammeSnapshot() async throws {
        let directory = cacheDirectory()
        let server = try EPGImportTestServer(xml: Data("<tv/>".utf8), gzip: Data())
        let repository = EPGProductionRepository(cacheDirectory: directory)
        defer {
            server.close()
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let source = LiveSourceID.imported(UUID())
        let revision = String(repeating: "e", count: 64)
        let key = EPGRequestKey(source: source, revision: revision, resource: "xmltv")
        let status = try await repository.refreshXMLTV(
            key: key, url: server.url("fixture.xml"), force: true
        )
        XCTAssertEqual(status.availability, .empty)
        let start = Date(timeIntervalSince1970: 1_789_862_400)
        let channel = LiveChannel(groupName: "", name: "Alpha", streams: [])
        let demand = try EPGGuideDemand(
            source: EPGSourceKey(source), revision: revision,
            demandRevision: UUID(), capability: .xmltv,
            channels: [channel], visibleRange: 0..<1,
            slices: [try EPGGuideTimeSlice(start: start,
                end: start.addingTimeInterval(12 * 3_600))]
        )

        let snapshot = try await EPGGuideXMLTVLoader.load(
            repository: repository, key: key, demand: demand,
            availability: status.availability
        )
        XCTAssertEqual(snapshot.rows.count, 1)
        XCTAssertTrue(snapshot.rows[0].programmes.isEmpty)
        XCTAssertEqual(snapshot.rows[0].state, .unmatched)
        let closed = await repository.close()
        XCTAssertTrue(closed)
    }

    func testFailedRefreshKeepsStaleActiveGenerationQueryable() async throws {
        let directory = cacheDirectory()
        let server = try EPGImportTestServer(xml: Data("""
        <tv><channel id="a"><display-name>Alpha</display-name></channel>
        <programme channel="a" start="20260920000000 +0000" stop="20260920010000 +0000"><title>Kept</title></programme></tv>
        """.utf8), gzip: Data())
        let repository = EPGProductionRepository(cacheDirectory: directory)
        defer {
            server.close()
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let source = LiveSourceID.imported(UUID())
        let revision = String(repeating: "f", count: 64)
        let key = EPGRequestKey(source: source, revision: revision, resource: "xmltv")
        _ = try await repository.refreshXMLTV(key: key, url: server.url("fixture.xml"), force: true)
        let failed = try await repository.refreshXMLTV(
            key: key, url: server.url("missing.xml"), force: true
        )
        XCTAssertEqual(failed.availability, .stale)
        let start = Date(timeIntervalSince1970: 1_789_862_400)
        let channel = LiveChannel(groupName: "", name: "Alpha", streams: [])
        let demand = try EPGGuideDemand(
            source: EPGSourceKey(source), revision: revision,
            demandRevision: UUID(), capability: .xmltv,
            channels: [channel], visibleRange: 0..<1,
            slices: [try EPGGuideTimeSlice(start: start,
                end: start.addingTimeInterval(12 * 3_600))]
        )
        let snapshot = try await EPGGuideXMLTVLoader.load(
            repository: repository, key: key, demand: demand,
            availability: failed.availability
        )
        XCTAssertEqual(snapshot.rows[0].programmes.map(\.title), ["Kept"])
        XCTAssertEqual(snapshot.rows[0].availability, .stale)
        let closed = await repository.close()
        XCTAssertTrue(closed)
    }
}
