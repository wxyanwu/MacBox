import Foundation
import XCTest
@_spi(XMLTVStreaming) import OKVideoCore
@testable import OKVideoPersistence

/// Opt-in acceptance inputs are private to the test, never the user's cache.
final class EPGImportAcceptanceTests: XCTestCase {
    private func copy(_ url: URL, root: String) throws -> XMLTVStagedFile {
        let owner = try XMLTVStagingFile.create(in: root)
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        while try autoreleasepool(invoking: { () throws -> Bool in
            let data = try input.read(upToCount: 65_536) ?? Data()
            if data.isEmpty { return false }; try owner.write(data); return true
        }) {}
        return try owner.finishAndTransfer()
    }
    private func drain(_ importer: EPGXMLTVImporter) throws {
        for _ in 0..<256 { if importer.cleanup() { return } }
        XCTFail("GC did not converge"); throw EPGCacheError.budgetExceeded
    }
    private func locations() throws -> (String, URL) {
        let root = "/private/tmp/OKVideoMac-9B." + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return (root, URL(fileURLWithPath: "/private/tmp/EPGCache-acceptance-" + UUID().uuidString))
    }
    func testPublicXMLTVMatchesLegacyOracle() async throws {
        guard let path = ProcessInfo.processInfo.environment["EPG9C3_PUBLIC_FILE"] else {
            throw XCTSkip("Requires a frozen public XMLTV sample")
        }
        let url = URL(fileURLWithPath: path)
        let payload = try Data(contentsOf: url)
        let guide = try XMLTVParser().parse(payload)
        XCTAssertFalse(guide.programmes.isEmpty)
        let (root, directory) = try locations()
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(at: directory) }
        let store = try EPGCacheStore(directory: directory); defer { store.close() }
        let key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "d", count: 64), resource: "xmltv")
        let server = try EPGImportTestServer(xml: payload, gzip: payload); defer { server.close() }
        let coordinator = EPGImportCoordinator(store: store, downloader: XMLTVDownloader(stagingRootPath: root))
        let receipt = try await coordinator.load(key: key, request: XMLTVDownloadRequest(url: server.url("fixture.xml")))
        await coordinator.close()
        XCTAssertEqual(receipt.active.programmeCount, guide.programmes.count)
        let db = try EPGCacheDatabase(url: directory.appendingPathComponent("EPGCache.sqlite"), access: .existingReadWrite)
        defer { db.close() }
        do {
            let statement = try db.statement("SELECT channel_reference,title,start,end FROM programmes WHERE generation_id=? ORDER BY ordinal")
            try statement.bind([.text(receipt.active.generation)])
            for expected in guide.programmes {
                XCTAssertTrue(try statement.step())
                XCTAssertEqual(statement.text(0), expected.channelID); XCTAssertEqual(statement.text(1), expected.title)
                XCTAssertEqual(statement.number(2), expected.start.timeIntervalSince1970)
                XCTAssertEqual(statement.number(3), expected.end.timeIntervalSince1970)
            }
            XCTAssertFalse(try statement.step())
        }
        let matcher = XMLTVChannelMatcher(guide: guide)
        let channels = guide.channels.flatMap { channel in
            [LiveChannel(groupName: "", name: channel.displayName, tvgID: channel.id, streams: []),
             LiveChannel(groupName: "", name: channel.displayName, streams: [])]
        }
        for offset in stride(from: 0, to: channels.count, by: 100) {
            let batch = Array(channels[offset..<min(offset + 100, channels.count)])
            XCTAssertEqual(try store.matchChannels(batch, for: key).matches, batch.map(matcher.match))
        }
        // Exercise 9C.2 queries using the frozen latest-start/last-ordinal rule.
        for programme in guide.programmes.prefix(30) {
            let channel = LiveChannel(groupName: "", name: "", tvgID: programme.channelID, streams: [])
            let at = programme.start.addingTimeInterval(1)
            let expected = guide.programmes.enumerated().filter {
                $0.element.channelID == programme.channelID && $0.element.start <= at && at < $0.element.end
            }.max { a, b in a.element.start == b.element.start ? a.offset < b.offset : a.element.start < b.element.start }
            let actual = try store.queryNowNext([channel], for: key, at: at).entries[0].current
            XCTAssertEqual(actual?.title, expected?.element.title)
        }
        print("9C.3 real sample: \(guide.channels.count) channels, \(guide.programmes.count) programmes; all rows and matching agree")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
    }

    func testProductionPublicXMLTVFiniteQueriesMatchLegacyOracle() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["EPG9C4_PUBLIC_FILE"] else {
            throw XCTSkip("Requires a frozen public XMLTV sample through the production repository")
        }
        let inputURL = URL(fileURLWithPath: path)
        let oracleURL = URL(fileURLWithPath: env["EPG9C4_PUBLIC_ORACLE"] ?? path)
        let input = try Data(contentsOf: inputURL)
        let oraclePayload = try Data(contentsOf: oracleURL)
        let guide = try XMLTVParser().parse(oraclePayload)
        XCTAssertFalse(guide.channels.isEmpty)
        XCTAssertFalse(guide.programmes.isEmpty)

        let isGzip = inputURL.pathExtension.lowercased() == "gz"
        let server = try EPGImportTestServer(
            xml: isGzip ? oraclePayload : input,
            gzip: isGzip ? input : Data())
        defer { server.close() }
        let directory = URL(fileURLWithPath: "/private/tmp/EPGCache-production-public-" + UUID().uuidString)
        let repository = EPGProductionRepository(cacheDirectory: directory)
        let key = EPGRequestKey(source: .imported(UUID()),
            revision: String(repeating: "9", count: 64), resource: "xmltv")
        defer { try? FileManager.default.removeItem(at: directory) }

        let status = try await repository.refreshXMLTV(
            key: key, url: server.url(isGzip ? "fixture.xml.gz" : "fixture.xml"), force: true)
        XCTAssertEqual(status.summary?.programmeCount, guide.programmes.count)

        // Every request remains finite. Sample points use the legacy parser only
        // as an acceptance oracle and never enter the production repository.
        for expected in guide.programmes.prefix(30) {
            let at = expected.start.addingTimeInterval(1)
            let candidates = guide.programmes.enumerated().filter {
                $0.element.channelID == expected.channelID
                    && $0.element.start <= at && at < $0.element.end
            }
            let current = candidates.max {
                $0.element.start == $1.element.start
                    ? $0.offset < $1.offset : $0.element.start < $1.element.start
            }?.element
            let channel = LiveChannel(groupName: "", name: "",
                tvgID: expected.channelID, streams: [])
            let batch = try await repository.queryXMLTVNowNext(
                [channel], for: key, at: at, demandRevision: UUID())
            XCTAssertEqual(batch.items.count, 1)
            XCTAssertEqual(batch.items[0].current?.title, current?.title)
            XCTAssertEqual(batch.items[0].current?.start, current?.start)
            XCTAssertEqual(batch.items[0].current?.end, current?.end)
        }

        let selectedID = try XCTUnwrap(Dictionary(grouping: guide.programmes, by: \.channelID)
            .max { $0.value.count < $1.value.count }?.key)
        let selectedProgrammes = guide.programmes.enumerated()
            .filter { $0.element.channelID == selectedID }
        let start = try XCTUnwrap(selectedProgrammes.map(\.element.start).min())
            .addingTimeInterval(-1)
        let end = start.addingTimeInterval(24 * 60 * 60)
        let expectedWindow = guide.programmes.enumerated()
            .filter {
                $0.element.channelID == selectedID
                    && $0.element.start < end && $0.element.end > start
            }
            .sorted {
                $0.element.start == $1.element.start
                    ? $0.offset < $1.offset : $0.element.start < $1.element.start
            }
            .map(\.element)
        XCTAssertFalse(expectedWindow.isEmpty)
        let channel = LiveChannel(groupName: "", name: "", tvgID: selectedID, streams: [])
        let demand = UUID()
        var cursor: EPGProductionWindowCursor?
        var actualWindow: [EPGProgramme] = []
        repeat {
            let result = try await repository.queryXMLTVWindow(channel, for: key,
                from: start, to: end, limit: 17, cursor: cursor, demandRevision: demand)
            XCTAssertLessThanOrEqual(result.page.programmes.count, 17)
            actualWindow.append(contentsOf: result.page.programmes)
            cursor = result.nextCursor
        } while cursor != nil
        XCTAssertEqual(actualWindow.map(\.title), expectedWindow.map(\.title))
        XCTAssertEqual(actualWindow.map(\.start), expectedWindow.map(\.start))
        XCTAssertEqual(actualWindow.map(\.end), expectedWindow.map(\.end))

        let closed = await repository.close()
        XCTAssertTrue(closed)
        print("9C.4 production public sample: \(guide.channels.count) channels, "
            + "\(guide.programmes.count) programmes, \(isGzip ? "gzip" : "plain")")
    }

    func testReleaseRepeatedLifecycleAndChannelMetadataGate() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["EPG9C3_LIFECYCLE_FIXTURE"], let output = env["EPG9C3_LIFECYCLE_OUTPUT"] else {
            throw XCTSkip("Requires independent Release lifecycle process")
        }
        let (root, directory) = try locations()
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(at: directory) }
        let store = try EPGCacheStore(directory: directory); defer { store.close() }
        let importer = EPGXMLTVImporter(store: store)
        let key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "e", count: 64), resource: "xmltv")
        let fixture = URL(fileURLWithPath: path)
        let repeatCount = env["EPG9C3_LIFECYCLE_ROUNDS"].flatMap(Int.init) ?? 12
        guard (12...60).contains(repeatCount) else { throw EPGCacheError.invalidInput }
        var rounds: [[String: Any]] = []
        for round in 0..<repeatCount {
            let file = try copy(fixture, root: root)
            let active = try await Task.detached { try importer.importLocal(file, key: key) }.value.active
            try drain(importer)
            for cancellation in [false, true] {
                let next = try copy(fixture, root: root), control = EPGImportControl()
                let failing = EPGXMLTVImporter(store: store)
                var stoppedAt: UInt64 = 0
                failing.boundaryForTesting = { phase in
                    if phase == "programmeBatchCommitted" {
                        stoppedAt = DispatchTime.now().uptimeNanoseconds
                        if cancellation { control.stop() } else { throw EPGCacheError.budgetExceeded }
                    }
                }
                do {
                    _ = try await Task.detached { try failing.importLocal(next, key: key, control: control) }.value
                    XCTFail("fault must prevent publication")
                } catch {
                    let latency = Double(DispatchTime.now().uptimeNanoseconds - stoppedAt) / 1e6
                    XCTAssertGreaterThan(stoppedAt, 0); XCTAssertLessThan(latency, 1000)
                    rounds.append(["round": round, "kind": cancellation ? "cancel" : "sinkFailure", "stopToReturnMs": latency])
                }
                XCTAssertEqual(try store.activeIdentity(for: key), active)
                try drain(importer)
            }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            let bytes = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
            let memory = EPGImportResourceTests.Sampler.memory()
            rounds.append(["round": round, "kind": "settled", "rss": memory[0], "footprint": memory[1], "diskBytes": bytes,
                           "fd": try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
        }
        // Freeze a second distribution: 20K channel declarations and 20K aliases
        // of one channel. File construction is outside the measured import.
        let owner = try XMLTVStagingFile.create(in: root)
        try owner.write(Data("<tv>".utf8))
        for n in 0..<20_000 {
            try autoreleasepool {
                try owner.write(Data("<channel id='c\(n)'><display-name>C\(n)</display-name></channel><channel id='shared'><display-name>Alias\(n)</display-name></channel>".utf8))
            }
        }
        try owner.write(Data("</tv>".utf8)); let file = try owner.finishAndTransfer()
        let sampler = EPGImportResourceTests.Sampler(roots: [directory, URL(fileURLWithPath: root)])
        sampler.start()
        let receipt = try await Task.detached { try importer.importLocal(file, key: key) }.value
        try drain(importer)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let metadata = sampler.stop()
        let settled = rounds.filter { $0["kind"] as? String == "settled" }
        let first = settled[2], last = settled.last!
        let server = try EPGImportTestServer(xml: Data("<tv/>".utf8), gzip: Data()); defer { server.close() }
        let coordinator = EPGImportCoordinator(store: store, downloader: XMLTVDownloader(stagingRootPath: root))
        let network = Task { try await coordinator.load(key: key, request: XMLTVDownloadRequest(url: server.url("slow"))) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelledAt = DispatchTime.now().uptimeNanoseconds
        network.cancel()
        do { _ = try await network.value; XCTFail("slow download must cancel") } catch {}
        let networkStopMs = Double(DispatchTime.now().uptimeNanoseconds - cancelledAt) / 1e6
        await coordinator.close()
        XCTAssertLessThan(networkStopMs, 1000)
        XCTAssertEqual(try store.activeIdentity(for: key), receipt.active)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
        let result: [String: Any] = ["rounds": rounds, "metadata": metadata, "metadataFacts": receipt.channelFacts,
                                    "networkCancelToDrainedReturnMs": networkStopMs]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        for metric in ["rss", "footprint"] {
            XCTAssertLessThanOrEqual(Int64(last[metric] as! UInt64) - Int64(first[metric] as! UInt64), 8 * 1024 * 1024)
        }
        XCTAssertLessThanOrEqual((last["diskBytes"] as! Int) - (first["diskBytes"] as! Int), 8 * 1024 * 1024)
        XCTAssertLessThanOrEqual((last["fd"] as! Int) - (first["fd"] as! Int), 2)
        XCTAssertEqual(receipt.channelFacts, 40_000)
        XCTAssertEqual(receipt.active.programmeCount, 0)
        XCTAssertLessThanOrEqual(metadata["rssDelta"] as! UInt64, 32 * 1024 * 1024)
        XCTAssertLessThanOrEqual(metadata["footprintDelta"] as! UInt64, 32 * 1024 * 1024)
        let db = try EPGCacheDatabase(url: directory.appendingPathComponent("EPGCache.sqlite"), access: .existingReadWrite)
        XCTAssertEqual(try db.integer("SELECT COUNT(*) FROM channels WHERE generation_id=?", [.text(receipt.active.generation)]), 20_001)
        db.close()
    }
}
