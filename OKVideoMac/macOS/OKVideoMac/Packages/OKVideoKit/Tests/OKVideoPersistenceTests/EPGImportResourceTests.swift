import Foundation
import Darwin
import CryptoKit
import XCTest
@_spi(XMLTVStreaming) import OKVideoCore
@testable import OKVideoPersistence

final class EPGImportResourceTests: XCTestCase {
    final class Sampler: @unchecked Sendable {
        let lock = NSLock()
        var baseline: [UInt64] = [], peak: [UInt64] = []
        var samples = 0, diskPeak: UInt64 = 0, fdPeak = 0
        var foundationBytes: UInt64 = 0, foundationPeak: UInt64 = 0
        var timer: DispatchSourceTimer?
        let roots: [URL]
        init(roots: [URL]) { self.roots = roots }
        static func memory() -> [UInt64] {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            precondition(status == KERN_SUCCESS)
            return [info.resident_size, info.phys_footprint]
        }
        func start() {
            lock.lock(); baseline = Self.memory(); peak = baseline; lock.unlock()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "epg9c3.resource.sampler", qos: .utility))
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.sample() }; self.timer = timer; timer.resume()
        }
        func sample(forceDisk: Bool = false) {
            autoreleasepool {
                let memory = Self.memory()
                lock.lock(); defer { lock.unlock() }
                guard !baseline.isEmpty else { return }
                peak = zip(peak, memory).map(max); samples += 1
                if forceDisk || samples % 10 == 0 {
                    var bytes: UInt64 = 0
                    for root in roots {
                        if let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                            for case let url as URL in iterator {
                                if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                                    bytes += UInt64(values.fileSize ?? 0)
                                }
                            }
                        }
                    }
                    diskPeak = max(diskPeak, bytes + foundationBytes)
                    fdPeak = max(fdPeak, (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0)
                }
            }
        }
        func observeFoundation(_ bytes: Int64) {
            sample(forceDisk: true)
            lock.lock(); foundationBytes = UInt64(max(0, bytes)); foundationPeak = max(foundationPeak, foundationBytes); lock.unlock()
            sample(forceDisk: true)
        }
        func stop() -> [String: Any] {
            timer?.cancel(); sample(forceDisk: true)
            lock.lock(); defer { lock.unlock() }
            return ["rssBaseline": baseline[0], "footprintBaseline": baseline[1],
                    "rssPeak": peak[0], "footprintPeak": peak[1],
                    "rssDelta": peak[0] - baseline[0], "footprintDelta": peak[1] - baseline[1],
                    "samples": samples, "diskPeak": diskPeak, "foundationPeak": foundationPeak, "fdPeak": fdPeak]
        }
    }

    func testReleaseNetworkImportResourceGate() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["EPG9C3_URL"].flatMap(URL.init(string:)),
              let count = env["EPG9C3_COUNT"].flatMap(Int.init), let output = env["EPG9C3_OUTPUT"],
              let digest = env["EPG9C3_DIGEST"], let mode = env["EPG9C3_MODE"] else {
            throw XCTSkip("Explicit independent Release process resource gate")
        }
        let root = "/private/tmp/OKVideoMac-9B." + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let directory = URL(fileURLWithPath: "/private/tmp/EPGCache-resource-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(at: directory) }
        let sampler = Sampler(roots: [directory, URL(fileURLWithPath: root)])
        if mode == "cold" { sampler.start() }
        let store = try EPGCacheStore(directory: directory); defer { store.close() }
        let coordinator = EPGImportCoordinator(store: store, downloader: XMLTVDownloader(stagingRootPath: root,
                                                temporaryByteObserver: sampler.observeFoundation),
                                                phaseObserver: { _ in sampler.sample() })
        let key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "a", count: 64), resource: "xmltv")
        let request = XMLTVDownloadRequest(url: url)
        let importer = EPGXMLTVImporter(store: store)
        if mode == "warm" {
            _ = try await coordinator.load(key: key, request: request)
            while !importer.cleanup() {}
            sampler.start()
        }
        let channels = (0..<100).map { LiveChannel(groupName: "", name: "C\($0)", tvgID: "c\($0)", streams: []) }
        let queryTime = Date(timeIntervalSince1970: 1767225600 + Double(count / 200 * 60 + 30))
        let queryTask: Task<([Double], [Double]), Error>? = mode == "warm" ? Task.detached {
            var now: [Double] = [], window: [Double] = []
            for _ in 0..<2000 {
                if Task.isCancelled { break }
                do {
                var start = DispatchTime.now().uptimeNanoseconds
                _ = try store.queryNowNext(channels, for: key, at: queryTime)
                now.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                start = DispatchTime.now().uptimeNanoseconds
                _ = try store.queryWindow(channels[0], for: key, from: Date(timeIntervalSince1970: 1767225600),
                    to: Date(timeIntervalSince1970: 1767225600 + 86400), limit: 500)
                window.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                } catch { if Task.isCancelled { break }; throw error }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return (now, window)
        } : nil
        let began = DispatchTime.now().uptimeNanoseconds
        let receipt = try await coordinator.load(key: key, request: request)
        sampler.sample()
        var cleanupSteps = 0
        while !importer.cleanup() {
            cleanupSteps += 32
            guard cleanupSteps < 8192 else { XCTFail("cleanup did not converge"); throw EPGCacheError.importInProgress }
        }
        queryTask?.cancel()
        let durations = try await queryTask?.value ?? ([], [])
        await coordinator.close()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var metrics = sampler.stop()
        metrics["elapsedSeconds"] = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        metrics["count"] = count; metrics["mode"] = mode; metrics["gzip"] = receipt.wasGzip
        metrics["cleanupSteps"] = cleanupSteps; metrics["peakProgrammeBatch"] = receipt.peakProgrammeBatch
        metrics["peakChannelBatch"] = receipt.peakChannelBatch
        func p95(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[Int(ceil(Double(values.count)*0.95))-1] }
        metrics["concurrentNowP95"] = p95(durations.0); metrics["concurrentWindowP95"] = p95(durations.1)
        metrics["concurrentQueryCount"] = durations.0.count
        var nowTimes: [Double] = [], windowTimes: [Double] = []
        for _ in 0..<100 {
            var start = DispatchTime.now().uptimeNanoseconds
            _ = try store.queryNowNext(channels, for: key, at: queryTime)
            nowTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            start = DispatchTime.now().uptimeNanoseconds
            _ = try store.queryWindow(channels[0], for: key, from: Date(timeIntervalSince1970: 1767225600),
                to: Date(timeIntervalSince1970: 1767225600 + 86400), limit: 500)
            windowTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        metrics["nowP95"] = p95(nowTimes); metrics["windowP95"] = p95(windowTimes)
        XCTAssertLessThanOrEqual(p95(nowTimes), 50); XCTAssertLessThanOrEqual(p95(windowTimes), 50)
        // Verify every stored row using a streaming statement; the test never
        // constructs a complete guide or programme array for large fixtures.
        let db = try EPGCacheDatabase(url: directory.appendingPathComponent("EPGCache.sqlite"), access: .existingReadWrite)
        var hash = SHA256(), rowCount = 0
        do {
            let statement = try db.statement("SELECT ordinal,channel_reference,title,start,end FROM programmes WHERE generation_id=? ORDER BY ordinal")
            try statement.bind([.text(receipt.active.generation)])
            while try statement.step() {
                let line = "\(statement.integer(0))|\(statement.text(1)!)|\(statement.text(2)!)|\(Int64(statement.number(3)))|\(Int64(statement.number(4)))\n"
                hash.update(data: Data(line.utf8)); rowCount += 1
            }
        }
        db.close()
        metrics["programmeDigest"] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        metrics["storedRows"] = rowCount
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        XCTAssertEqual(metrics["programmeDigest"] as? String, digest)
        XCTAssertEqual(rowCount, count); XCTAssertEqual(receipt.active.programmeCount, count)
        XCTAssertLessThanOrEqual(receipt.peakProgrammeBatch, 512); XCTAssertLessThanOrEqual(receipt.peakChannelBatch, 512)
        XCTAssertLessThanOrEqual(receipt.peakProgrammeBytes, 1_048_576); XCTAssertLessThanOrEqual(receipt.peakChannelBytes, 1_048_576)
        XCTAssertLessThanOrEqual(metrics["rssDelta"] as! UInt64, 32 * 1024 * 1024)
        XCTAssertLessThanOrEqual(metrics["footprintDelta"] as! UInt64, 32 * 1024 * 1024)
        if mode == "warm" {
            XCTAssertGreaterThan(durations.0.count, 0)
            XCTAssertLessThanOrEqual(p95(durations.0), 50); XCTAssertLessThanOrEqual(p95(durations.1), 50)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
    }

    func testReleaseProductionResourceGate() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["EPG9C4_URL"].flatMap(URL.init(string:)),
              let count = env["EPG9C4_COUNT"].flatMap(Int.init),
              let output = env["EPG9C4_OUTPUT"],
              let fixtureDigest = env["EPG9C4_DIGEST"],
              let mode = env["EPG9C4_MODE"], ["cold", "warm"].contains(mode) else {
            throw XCTSkip("Explicit independent 9C.4 Release production resource gate")
        }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let root = "/private/tmp/OKVideoMac-9B." + suffix
        let directory = URL(fileURLWithPath: "/private/tmp/EPGCache-production-resource-" + UUID().uuidString)
        let sampler = Sampler(roots: [directory, URL(fileURLWithPath: root)])
        let service = try EPGProductionService(cacheDirectory: directory,
            stagingRootPathForTesting: root,
            temporaryByteObserverForTesting: sampler.observeFoundation,
            phaseObserverForTesting: { _ in sampler.sample() })
        let repository = EPGProductionRepository(service: service)
        let key = EPGRequestKey(source: .imported(UUID()),
            revision: String(repeating: "4", count: 64), resource: "xmltv")
        let channels = (0..<100).map {
            LiveChannel(groupName: "", name: "C\($0)", tvgID: "c\($0)", streams: [])
        }
        let anchor = Date(timeIntervalSince1970: 1_767_225_600)
        let queryTime = anchor.addingTimeInterval(Double(count / 200 * 60 + 30))
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(at: directory) }

        if mode == "warm" {
            let first = try await repository.refreshXMLTV(key: key, url: url, force: true)
            XCTAssertEqual(first.summary?.programmeCount, count)
            try await drainProductionMaintenance(repository)
        }
        sampler.start()

        let queryTask: Task<([Double], [Double], Int), Error>? = mode == "warm" ? Task {
            var nowDurations: [Double] = [], windowDurations: [Double] = []
            var invalidated = 0
            while !Task.isCancelled {
                do {
                    var began = DispatchTime.now().uptimeNanoseconds
                    _ = try await repository.queryXMLTVNowNext(channels, for: key,
                        at: queryTime, demandRevision: UUID())
                    nowDurations.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6)
                    began = DispatchTime.now().uptimeNanoseconds
                    _ = try await repository.queryXMLTVWindow(channels[0], for: key,
                        from: anchor, to: anchor.addingTimeInterval(86_400),
                        limit: 500, demandRevision: UUID())
                    windowDurations.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6)
                } catch {
                    if Task.isCancelled { break }
                    if [.invalidRequest, .snapshotChanged].contains(error as? EPGProductionServiceError) {
                        invalidated += 1
                        await Task.yield()
                        continue
                    }
                    throw error
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return (nowDurations, windowDurations, invalidated)
        } : nil

        let began = DispatchTime.now().uptimeNanoseconds
        let status = try await repository.refreshXMLTV(key: key, url: url, force: true)
        XCTAssertEqual(status.summary?.programmeCount, count)
        sampler.sample(forceDisk: true)
        try await drainProductionMaintenance(repository)
        let demand = UUID()
        let batch = try await repository.queryXMLTVNowNext(channels, for: key,
            at: queryTime, demandRevision: demand)
        let window = try await repository.queryXMLTVWindow(channels[0], for: key,
            from: anchor, to: anchor.addingTimeInterval(86_400), limit: 500,
            demandRevision: demand)
        queryTask?.cancel()
        let concurrent = try await queryTask?.value ?? ([], [], 0)

        let expectedBase = count / 200 * 100
        XCTAssertEqual(batch.items.count, 100)
        for channel in 0..<100 {
            XCTAssertEqual(batch.items[channel].current?.title, "T\(expectedBase + channel)")
            if expectedBase + 100 + channel < count {
                XCTAssertEqual(batch.items[channel].next?.title, "T\(expectedBase + 100 + channel)")
            }
        }
        XCTAssertEqual(window.page.programmes.first?.title, "T0")
        XCTAssertEqual(window.page.programmes.count, min(500, count / 100))
        XCTAssertLessThanOrEqual(window.page.programmes.count, 500)
        XCTAssertEqual(batch.token.dataVersion, status.summary?.dataVersion)
        XCTAssertEqual(window.page.token.dataVersion, status.summary?.dataVersion)
        XCTAssertEqual(batch.token.demandRevision, demand)

        let closeCompleted = await repository.close()
        XCTAssertTrue(closeCompleted)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var metrics = sampler.stop()
        metrics["elapsedSeconds"] = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        metrics["count"] = count
        metrics["mode"] = mode
        metrics["gzip"] = url.lastPathComponent.hasSuffix(".gz")
        metrics["fixtureDigest"] = fixtureDigest
        metrics["programmeCount"] = status.summary?.programmeCount ?? -1
        metrics["deliveredChannels"] = batch.items.count
        metrics["deliveredWindowRows"] = window.page.programmes.count
        metrics["concurrentNowP95"] = percentile95(concurrent.0)
        metrics["concurrentWindowP95"] = percentile95(concurrent.1)
        metrics["concurrentQueryCount"] = concurrent.0.count
        metrics["concurrentInvalidatedCount"] = concurrent.2
        withExtendedLifetime((batch, window)) {}
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let settled = Sampler.memory()
        metrics["rssSettled"] = settled[0]
        metrics["footprintSettled"] = settled[1]
        metrics["rssSettledDelta"] = Int64(settled[0]) - Int64(metrics["rssBaseline"] as! UInt64)
        metrics["footprintSettledDelta"] = Int64(settled[1]) - Int64(metrics["footprintBaseline"] as! UInt64)
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))

        XCTAssertLessThanOrEqual(metrics["rssDelta"] as! UInt64, 48 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(metrics["footprintDelta"] as! UInt64, 48 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(percentile95(concurrent.0), 50)
        XCTAssertLessThanOrEqual(percentile95(concurrent.1), 50)
        if mode == "warm" { XCTAssertGreaterThan(concurrent.0.count, 0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
    }

    private func drainProductionMaintenance(_ repository: EPGProductionRepository) async throws {
        for _ in 0..<2_048 {
            let result = try await repository.performMaintenance()
            if !result.hasWorkRemaining { return }
            await Task.yield()
        }
        XCTFail("production maintenance did not converge")
        throw EPGCacheError.budgetExceeded
    }

    private func percentile95(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1]
    }
}
