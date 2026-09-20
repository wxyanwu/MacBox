import Foundation
import XCTest
@testable import OKVideoCore
@testable import OKVideoPersistence

final class EPGProductionRepositoryTests: XCTestCase {
    private func cacheDirectory() -> URL {
        URL(fileURLWithPath: "/private/tmp/EPGCache-Repository-" + UUID().uuidString)
    }

    private func fixture() -> Data {
        Data("""
        <tv><channel id="a"><display-name>Alpha</display-name></channel>
        <programme channel="a" start="20260920000000 +0000" stop="20260920010000 +0000"><title>One</title></programme>
        <programme channel="a" start="20260920010000 +0000" stop="20260920020000 +0000"><title>Two</title></programme>
        </tv>
        """.utf8)
    }

    func testXMLTVStatusUsesCoverageAndFailurePreservesActive() async throws {
        let directory = cacheDirectory()
        let server = try EPGImportTestServer(xml: fixture(), gzip: Data())
        defer { server.close() }
        let repository = EPGProductionRepository(cacheDirectory: directory)
        let key = EPGRequestKey(source: .imported(UUID()),
            revision: String(repeating: "c", count: 64), resource: "xmltv")

        let loaded = try await repository.refreshXMLTV(key: key, url: server.url("fixture.xml"))
        let summary = try XCTUnwrap(loaded.summary)
        XCTAssertEqual(summary.programmeCount, 2)
        XCTAssertEqual(loaded.refreshDueAt,
            max(summary.publishedAt, summary.coverageEnd!.addingTimeInterval(-30 * 60)))

        let failed = try await repository.refreshXMLTV(key: key, url: server.url("missing"), force: true)
        XCTAssertEqual(failed.availability, .stale)
        XCTAssertEqual(failed.summary?.dataVersion, summary.dataVersion)
        XCTAssertEqual(failed.consecutiveFailures, 1)
        XCTAssertGreaterThan(failed.nextRetryAt, Date())

        let channel = LiveChannel(groupName: "", name: "Alpha", streams: [])
        let demand = UUID()
        let batch = try await repository.queryXMLTVNowNext([channel], for: key,
            at: Date(timeIntervalSince1970: 1_789_864_200), demandRevision: demand)
        XCTAssertEqual(batch.items.first?.current?.title, "One")
        XCTAssertEqual(batch.availability, .stale)
        XCTAssertEqual(batch.token.demandRevision, demand)

        let closed = await repository.close()
        XCTAssertTrue(closed)
        try FileManager.default.removeItem(at: directory)
    }

    func testXtreamCacheIdentityBudgetsAndStaleFallback() async throws {
        let directory = cacheDirectory()
        let clock = RepositoryClock(Date(timeIntervalSince1970: 100))
        let repository = EPGProductionRepository(cacheDirectory: directory, now: { clock.value })
        let source = LiveSourceID.xtream(UUID())
        let key = EPGRequestKey(source: source, revision: "configuration-r1", resource: "7")
        let counter = RepositoryCounter()
        let payload = EPGPayload(guide: XMLTVGuide(channels: [], programmes: [
            EPGProgramme(channelID: "7", title: "Current", start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 150)),
            EPGProgramme(channelID: "7", title: "Next", start: Date(timeIntervalSince1970: 160), end: Date(timeIntervalSince1970: 220))
        ]))
        let fetch: @Sendable () async throws -> EPGPayload = {
            await counter.increment()
            return payload
        }

        let first = try await repository.loadXtream(key: key, accountIdentity: "account-a",
            serverIdentity: "https://provider.invalid", configurationRevision: "r1",
            at: clock.value, demandRevision: UUID(), fetch: fetch)
        let secondDemand = UUID()
        let second = try await repository.loadXtream(key: key, accountIdentity: "account-a",
            serverIdentity: "https://provider.invalid", configurationRevision: "r1",
            at: clock.value, demandRevision: secondDemand, fetch: fetch)
        let firstFetchCount = await counter.value
        XCTAssertEqual(firstFetchCount, 1)
        XCTAssertEqual(first.items.first?.current?.title, "Current")
        XCTAssertEqual(second.token.dataVersion, first.token.dataVersion)
        XCTAssertEqual(second.token.demandRevision, secondDemand)

        _ = try await repository.loadXtream(key: key, accountIdentity: "account-b",
            serverIdentity: "https://provider.invalid", configurationRevision: "r1",
            at: clock.value, demandRevision: UUID(), fetch: fetch)
        let secondFetchCount = await counter.value
        XCTAssertEqual(secondFetchCount, 2)

        let stale = try await repository.loadXtream(key: key, accountIdentity: "account-a",
            serverIdentity: "https://provider.invalid", configurationRevision: "r1",
            at: clock.value, demandRevision: UUID(), force: true,
            fetch: { throw EPGFetchError.unavailable })
        XCTAssertEqual(stale.availability, .stale)
        XCTAssertEqual(stale.token.dataVersion, first.token.dataVersion)

        let oversized = EPGPayload(guide: XMLTVGuide(channels: [], programmes: [
            EPGProgramme(channelID: "8", title: String(repeating: "界", count: 1_366),
                         start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 150))
        ]))
        let oversizedKey = EPGRequestKey(source: source, revision: "configuration-r1", resource: "8")
        do {
            _ = try await repository.loadXtream(key: oversizedKey, accountIdentity: "account-a",
                serverIdentity: "https://provider.invalid", configurationRevision: "r1",
                at: clock.value, demandRevision: UUID(), fetch: { oversized })
            XCTFail("oversized UTF-8 title entered cache")
        } catch { XCTAssertEqual(error as? EPGProductionServiceError, .unavailable) }

        let closed = await repository.close()
        XCTAssertTrue(closed)
        try FileManager.default.removeItem(at: directory)
    }

    func testLegalEmptyPublishesButMalformedRefreshIsFailureAndKeepsEmptyActive() async throws {
        let directory = cacheDirectory()
        let fullServer = try EPGImportTestServer(xml: fixture(), gzip: Data())
        let emptyServer = try EPGImportTestServer(xml: Data("<tv/>".utf8), gzip: Data())
        let malformedServer = try EPGImportTestServer(
            xml: Data("<tv><programme channel='a'>".utf8), gzip: Data())
        defer { fullServer.close(); emptyServer.close(); malformedServer.close() }
        let repository = EPGProductionRepository(cacheDirectory: directory)
        let key = EPGRequestKey(source: .imported(UUID()),
            revision: String(repeating: "e", count: 64), resource: "xmltv")

        let full = try await repository.refreshXMLTV(
            key: key, url: fullServer.url("fixture.xml"), force: true)
        XCTAssertEqual(full.summary?.programmeCount, 2)

        let empty = try await repository.refreshXMLTV(
            key: key, url: emptyServer.url("fixture.xml"), force: true)
        XCTAssertEqual(empty.availability, .empty)
        XCTAssertEqual(empty.summary?.programmeCount, 0)
        let emptyVersion = try XCTUnwrap(empty.summary?.dataVersion)

        let failed = try await repository.refreshXMLTV(
            key: key, url: malformedServer.url("fixture.xml"), force: true)
        XCTAssertEqual(failed.availability, .stale)
        XCTAssertEqual(failed.consecutiveFailures, 1)
        XCTAssertEqual(failed.summary?.programmeCount, 0)
        XCTAssertEqual(failed.summary?.dataVersion, emptyVersion)

        let closed = await repository.close()
        XCTAssertTrue(closed)
        try FileManager.default.removeItem(at: directory)
    }

    func testUnavailableStoreFailsClosedWithoutReadingOrChangingLegacyJSON() async throws {
        let root = cacheDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let blockedCache = root.appendingPathComponent("EPGCache-v3")
        let legacy = root.appendingPathComponent("legacy-epg.json")
        let marker = Data("{ malformed legacy guide that must stay opaque".utf8)
        try marker.write(to: blockedCache)
        try marker.write(to: legacy)
        let repository = EPGProductionRepository(cacheDirectory: blockedCache)
        let key = EPGRequestKey(source: .imported(UUID()),
            revision: String(repeating: "f", count: 64), resource: "xmltv")

        let isAvailable = await repository.isAvailable
        XCTAssertFalse(isAvailable)
        let status = await repository.status(for: key)
        XCTAssertEqual(status.availability, .failed)
        XCTAssertNil(status.summary)
        do {
            _ = try await repository.refreshXMLTV(
                key: key, url: URL(string: "https://example.invalid/epg.xml")!)
            XCTFail("unavailable store accepted refresh")
        } catch { XCTAssertEqual(error as? EPGProductionServiceError, .unavailable) }
        XCTAssertEqual(try Data(contentsOf: blockedCache), marker)
        XCTAssertEqual(try Data(contentsOf: legacy), marker)
        let closed = await repository.close()
        XCTAssertTrue(closed)
        try FileManager.default.removeItem(at: root)
    }

    func testInvalidationCancelsLateXtreamFlightAndCannotPopulateReplacementCache() async throws {
        let directory = cacheDirectory()
        let repository = EPGProductionRepository(cacheDirectory: directory)
        let source = LiveSourceID.xtream(UUID())
        let key = EPGRequestKey(source: source, revision: "r1", resource: "7")
        let counter = RepositoryCounter()
        let payload = EPGPayload(guide: XMLTVGuide(channels: [], programmes: [
            EPGProgramme(channelID: "7", title: "Current",
                start: Date(timeIntervalSince1970: 50), end: Date(timeIntervalSince1970: 150))
        ]))
        let late = Task {
            try await repository.loadXtream(key: key, accountIdentity: "account",
                serverIdentity: "server", configurationRevision: "r1",
                at: Date(timeIntervalSince1970: 100), demandRevision: UUID(), fetch: {
                    await counter.increment()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return payload
                })
        }
        for _ in 0..<1_000 {
            if await counter.value == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let firstCount = await counter.value
        XCTAssertEqual(firstCount, 1)
        await repository.invalidate(EPGSourceKey(source))
        do { _ = try await late.value; XCTFail("invalidated flight published") }
        catch { XCTAssertEqual(error as? EPGProductionServiceError, .cancelled) }

        let replacement = try await repository.loadXtream(key: key,
            accountIdentity: "account", serverIdentity: "server",
            configurationRevision: "r1", at: Date(timeIntervalSince1970: 100),
            demandRevision: UUID(), fetch: {
                await counter.increment()
                return payload
            })
        XCTAssertEqual(replacement.items.first?.current?.title, "Current")
        let replacementCount = await counter.value
        XCTAssertEqual(replacementCount, 2)

        let closed = await repository.close()
        XCTAssertTrue(closed)
        try FileManager.default.removeItem(at: directory)
    }
}

private final class RepositoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ value: Date) { stored = value }
    var value: Date { lock.withLock { stored } }
}

private actor RepositoryCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
