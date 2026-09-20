import Darwin
import Foundation
import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class EPGCacheQueryResourceTests: XCTestCase {
    private func directory(_ label: String) -> URL {
        URL(fileURLWithPath: "/private/tmp/EPGCache-9C2-\(label)-" + UUID().uuidString)
    }

    private func key(_ marker: Character = "d") -> EPGRequestKey {
        EPGRequestKey(source: .imported(UUID()), revision: String(repeating: String(marker), count: 64),
                      resource: "xmltv")
    }

    private func live(_ id: String) -> LiveChannel {
        LiveChannel(groupName: "Resource", name: id, tvgID: id, streams: [])
    }

    private func publishRegular(count: Int, store: EPGCacheStore,
                                key: EPGRequestKey) throws -> EPGCacheImportHandle {
        let handle = try store.begin(key)
        let channels = (0..<100).map { EPGChannel(id: "channel-\($0)", displayName: "Channel \($0)") }
        try store.appendChannels(channels, to: handle)
        for base in stride(from: 0, to: count, by: 512) {
            let upper = min(base + 512, count)
            let batch = (base..<upper).map { ordinal -> EPGCacheRecord in
                let channel = ordinal % 100
                let slot = ordinal / 100
                return EPGCacheRecord(ordinal: ordinal, programme: EPGProgramme(
                    channelID: "channel-\(channel)", title: "Programme \(ordinal)",
                    start: Date(timeIntervalSince1970: Double(slot * 60)),
                    end: Date(timeIntervalSince1970: Double((slot + 1) * 60))))
            }
            try store.append(batch, to: handle)
        }
        let slots = (count + 99) / 100
        try store.validate(handle, summary: EPGCacheValidation(rawProgrammeCount: count,
            emittedProgrammeCount: count, minimumStart: Date(timeIntervalSince1970: 0),
            maximumEnd: Date(timeIntervalSince1970: Double(slots * 60)),
            emittedChannelRecordCount: channels.count))
        _ = try store.activate(handle)
        return handle
    }

    private func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }

    private func milliseconds(_ operation: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try operation()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS)
        return info.phys_footprint
    }

    func testQueryPlansUsePersistentIndexes() throws {
        let root = directory("plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EPGCacheStore(directory: root)
        defer { store.close() }
        let request = key()
        let active = try publishRegular(count: 1_000, store: store, key: request)
        let db = try EPGCacheDatabase(url: root.appendingPathComponent("EPGCache.sqlite"),
                                      access: .existingReadWrite)
        defer { db.close() }
        try db.execute("PRAGMA query_only=ON")
        let plan = try db.statement("""
            EXPLAIN QUERY PLAN SELECT ordinal,channel_reference,title,start,end FROM programmes
            WHERE generation_id=? AND channel_key=? AND start<=? AND end>?
            ORDER BY start DESC,ordinal DESC LIMIT 1
            """)
        try plan.bind([.text(active.generation), .text("channel-0"), .double(300), .double(300)])
        var details: [String] = []
        while try plan.step() { if let detail = plan.text(3) { details.append(detail) } }
        XCTAssertTrue(details.contains { $0.contains("programme_time") }, details.joined(separator: " | "))

        _ = try store.queryNowNext([live("channel-0")], for: request,
                                   at: Date(timeIntervalSince1970: 300))
        let metrics = store.lastQueryDiagnosticsForTesting
        XCTAssertEqual(metrics.fullScanSteps, 0)
        XCTAssertEqual(metrics.sortOperations, 0)
        XCTAssertEqual(metrics.automaticIndexRows, 0)
        XCTAssertGreaterThan(metrics.virtualMachineSteps, 0)
    }

    func testTenThousandToTwoHundredThousandQueryMatrix() throws {
        guard ProcessInfo.processInfo.environment["OKVIDEO_EPG_9C2_RESOURCE"] == "1" else {
            throw XCTSkip("Explicit 9C.2 resource gate")
        }
        for size in [10_000, 50_000, 100_000, 200_000] {
            let root = directory("matrix-\(size)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try EPGCacheStore(directory: root)
            let request = key()
            _ = try publishRegular(count: size, store: store, key: request)
            let channels = (0..<100).map { live("channel-\($0)") }
            let slot = max(0, size / 100 / 2)
            let queryDate = Date(timeIntervalSince1970: Double(slot * 60 + 30))
            _ = try store.queryNowNext(channels, for: request, at: queryDate)
            _ = try store.queryWindow(channels[0], for: request,
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 24 * 60 * 60),
                limit: 500)
            let before = footprint()
            var nowDurations: [Double] = [], windowDurations: [Double] = []
            for _ in 0..<20 {
                nowDurations.append(try milliseconds {
                    let result = try store.queryNowNext(channels, for: request, at: queryDate)
                    XCTAssertEqual(result.entries.count, 100)
                })
                windowDurations.append(try milliseconds {
                    let page = try store.queryWindow(channels[0], for: request,
                        from: Date(timeIntervalSince1970: 0),
                        to: Date(timeIntervalSince1970: 24 * 60 * 60), limit: 500)
                    XCTAssertLessThanOrEqual(page.programmes.count, 500)
                })
            }
            let after = footprint()
            let nowP95 = percentile95(nowDurations), windowP95 = percentile95(windowDurations)
            let growth = after > before ? after - before : 0
            let metrics = store.lastQueryDiagnosticsForTesting
            print("9C2_RESOURCE size=\(size) now_p95_ms=\(nowP95) window_p95_ms=\(windowP95) footprint_growth=\(growth) vm_steps=\(metrics.virtualMachineSteps)")
            XCTAssertLessThanOrEqual(nowP95, 50)
            XCTAssertLessThanOrEqual(windowP95, 100)
            XCTAssertLessThan(growth, 64 * 1_024 * 1_024)
            XCTAssertEqual(metrics.fullScanSteps, 0)
            XCTAssertEqual(metrics.sortOperations, 0)
            XCTAssertEqual(metrics.automaticIndexRows, 0)
            XCTAssertLessThan(metrics.virtualMachineSteps, 500_000)
            store.close()
        }
    }

    func testPathologicalDistributionsAreCorrectOrExplicitlyBudgeted() throws {
        guard ProcessInfo.processInfo.environment["OKVIDEO_EPG_9C2_RESOURCE"] == "1" else {
            throw XCTSkip("Explicit 9C.2 resource gate")
        }
        let root = directory("pathological")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EPGCacheStore(directory: root, queryVMInstructionBudget: 200_000,
                                      queryProgressStepInterval: 100)
        defer { store.close() }
        let request = key()
        let handle = try store.begin(request)
        let ids = ["expired", "future", "overlap", "long-short"]
        try store.appendChannels(ids.map { EPGChannel(id: $0, displayName: $0) }, to: handle)
        let total = 200_000
        for base in stride(from: 0, to: total, by: 512) {
            let upper = min(base + 512, total)
            var batch: [EPGCacheRecord] = []
            batch.reserveCapacity(upper - base)
            for ordinal in base..<upper {
                let group = ordinal / 50_000, local = ordinal % 50_000
                let id = ids[group]
                let start: Double, end: Double
                switch group {
                case 0: start = Double(local); end = start + 1
                case 1: start = Double(100_000 + local); end = start + 1
                case 2: start = Double(local); end = 100_000
                default:
                    start = Double(local)
                    end = local == 0 ? 100_000 : start + 1
                }
                batch.append(EPGCacheRecord(ordinal: ordinal, programme: EPGProgramme(
                    channelID: id, title: "P\(ordinal)",
                    start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))))
            }
            try store.append(batch, to: handle)
        }
        try store.validate(handle, summary: EPGCacheValidation(rawProgrammeCount: total,
            emittedProgrammeCount: total, minimumStart: Date(timeIntervalSince1970: 0),
            maximumEnd: Date(timeIntervalSince1970: 150_000),
            emittedChannelRecordCount: ids.count))
        _ = try store.activate(handle)

        for id in ["expired", "long-short"] {
            XCTAssertThrowsError(try store.queryNowNext([live(id)], for: request,
                at: Date(timeIntervalSince1970: 60_000)), id) {
                XCTAssertEqual($0 as? EPGCacheQueryError, .queryBudgetExceeded, id)
            }
        }
        let future = try store.queryNowNext([live("future")], for: request,
                                            at: Date(timeIntervalSince1970: 0)).entries[0]
        XCTAssertNil(future.current)
        XCTAssertEqual(future.next?.ordinal, 50_000)
        let overlap = try store.queryNowNext([live("overlap")], for: request,
                                             at: Date(timeIntervalSince1970: 60_000)).entries[0]
        XCTAssertEqual(overlap.current?.ordinal, 149_999)
        XCTAssertNil(overlap.next)
    }
}
