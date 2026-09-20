import XCTest
import Darwin
import OKVideoCore
@testable import OKVideoPersistence

final class EPGCacheQueryTests: XCTestCase {
    private var directory: URL!
    private var store: EPGCacheStore!
    private var key: EPGRequestKey!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/private/tmp/EPGCache-query-" + UUID().uuidString)
        store = try EPGCacheStore(directory: directory)
        key = EPGRequestKey(source: .imported(UUID()), revision: String(repeating: "c", count: 64),
                            resource: "xmltv")
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func live(_ name: String, id: String? = nil, tvgName: String? = nil) -> LiveChannel {
        LiveChannel(groupName: "Fixture", name: name, tvgID: id, tvgName: tvgName, streams: [])
    }

    private func record(_ ordinal: Int, channel: String, title: String,
                        start: TimeInterval, end: TimeInterval) -> EPGCacheRecord {
        EPGCacheRecord(ordinal: ordinal, programme: EPGProgramme(channelID: channel, title: title,
            start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end)))
    }

    @discardableResult
    private func publish(channels: [EPGChannel], records: [EPGCacheRecord]) throws -> EPGCacheImportHandle {
        let handle = try store.begin(key)
        if !channels.isEmpty { try store.appendChannels(channels, to: handle) }
        if !records.isEmpty { try store.append(records, to: handle) }
        try store.validate(handle, summary: EPGCacheValidation(
            rawProgrammeCount: records.map(\.ordinal).max().map { $0 + 1 } ?? 0,
            emittedProgrammeCount: records.count,
            minimumStart: records.map(\.programme.start).min(),
            maximumEnd: records.map(\.programme.end).max(),
            emittedChannelRecordCount: channels.count
        ))
        _ = try store.activate(handle)
        return handle
    }

    func testNoActiveGenerationIsDistinctFromEmptySchedule() throws {
        XCTAssertThrowsError(try store.queryNowNext([live("One")], for: key,
                                                    at: Date(timeIntervalSince1970: 100))) {
            XCTAssertEqual($0 as? EPGCacheQueryError, .noActiveGeneration)
        }
        _ = try publish(channels: [.init(id: "one", displayName: "One")], records: [])
        let result = try store.queryNowNext([live("One")], for: key,
                                            at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(result.entries.first?.match.kind, .normalizedUnique)
        XCTAssertNil(result.entries.first?.current)
        XCTAssertNil(result.entries.first?.next)
    }

    func testSQLiteMatchingMatchesFrozenCoreSemantics() throws {
        _ = try publish(
            channels: [
                .init(id: "caf\u{00E9}", displayName: "Coffee"),
                .init(id: "one", displayName: "CCTV1"),
                .init(id: "two", displayName: "CCTV2")
            ],
            records: [record(0, channel: "CCTV-3", title: "Programme-only", start: 0, end: 200)]
        )
        let result = try store.matchChannels([
            live("ignored", id: "cafe\u{0301}"),
            live("CCTV1", id: "missing"),
            live("CCTV-1", tvgName: "CCTV2"),
            live("CCTV3")
        ], for: key)

        XCTAssertEqual(result.matches[0], EPGChannelMatch(kind: .exact, channelID: "cafe\u{0301}"))
        XCTAssertEqual(result.matches[1].kind, .unmatched)
        XCTAssertEqual(result.matches[2].kind, .ambiguous)
        XCTAssertEqual(result.matches[3], EPGChannelMatch(kind: .normalizedUnique, channelID: "CCTV-3"))
    }

    func testNowNextBoundariesOverlapAndOrdinalTieBreaks() throws {
        _ = try publish(channels: [.init(id: "one", displayName: "One")], records: [
            record(0, channel: "one", title: "Long", start: 0, end: 500),
            record(1, channel: "one", title: "Earlier", start: 100, end: 300),
            record(2, channel: "one", title: "Latest A", start: 150, end: 250),
            record(3, channel: "one", title: "Latest B", start: 150, end: 260),
            record(4, channel: "one", title: "Future", start: 300, end: 400)
        ])

        let at200 = try store.queryNowNext([live("One", id: "one")], for: key,
                                           at: Date(timeIntervalSince1970: 200)).entries[0]
        XCTAssertEqual(at200.current?.title, "Latest B")
        XCTAssertEqual(at200.current?.ordinal, 3)
        XCTAssertEqual(at200.next?.title, "Future")

        let at260 = try store.queryNowNext([live("One", id: "one")], for: key,
                                           at: Date(timeIntervalSince1970: 260)).entries[0]
        XCTAssertEqual(at260.current?.title, "Earlier")
        XCTAssertEqual(at260.next?.title, "Future")

        let at300 = try store.queryNowNext([live("One", id: "one")], for: key,
                                           at: Date(timeIntervalSince1970: 300)).entries[0]
        XCTAssertEqual(at300.current?.title, "Future")
        XCTAssertNil(at300.next)
    }

    func testReadTransactionKeepsOldGenerationCoherentDuringActivation() throws {
        let old = try publish(channels: [.init(id: "one", displayName: "One")], records: [
            record(0, channel: "one", title: "Old", start: 0, end: 200)
        ])
        let staged = try store.begin(key)
        try store.appendChannels([.init(id: "one", displayName: "One")], to: staged)
        try store.append([record(0, channel: "one", title: "New", start: 0, end: 200)], to: staged)
        try store.validate(staged, summary: EPGCacheValidation(rawProgrammeCount: 1,
            emittedProgrammeCount: 1, minimumStart: Date(timeIntervalSince1970: 0),
            maximumEnd: Date(timeIntervalSince1970: 200), emittedChannelRecordCount: 1))

        let snapshotReached = DispatchSemaphore(value: 0)
        let continueRead = DispatchSemaphore(value: 0)
        store.readerBoundaryForTesting = { name in
            guard name == "snapshotResolved" else { return }
            snapshotReached.signal()
            _ = continueRead.wait(timeout: .now() + 5)
        }
        final class ResultBox: @unchecked Sendable {
            var value: Result<EPGCacheNowNextResult, Error>?
        }
        let box = ResultBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [store, key] in
            defer { finished.signal() }
            box.value = Result {
                try store!.queryNowNext([self.live("One", id: "one")], for: key!,
                                        at: Date(timeIntervalSince1970: 100))
            }
        }
        XCTAssertEqual(snapshotReached.wait(timeout: .now() + 5), .success)
        _ = try store.activate(staged)
        continueRead.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        store.readerBoundaryForTesting = nil

        let oldResult = try box.value?.get()
        XCTAssertEqual(oldResult?.snapshotID.generationID, old.generation)
        XCTAssertEqual(oldResult?.entries.first?.current?.title, "Old")
        let newResult = try store.queryNowNext([live("One", id: "one")], for: key,
                                               at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(newResult.snapshotID.generationID, staged.generation)
        XCTAssertEqual(newResult.entries.first?.current?.title, "New")
    }

    func testNowNextInputAndResultBudgetsAreExplicit() throws {
        _ = try publish(channels: [], records: [])
        XCTAssertThrowsError(try store.matchChannels([], for: key)) {
            XCTAssertEqual($0 as? EPGCacheQueryError, .invalidRequest)
        }
        XCTAssertThrowsError(try store.matchChannels((0..<101).map { live("channel-\($0)") }, for: key)) {
            XCTAssertEqual($0 as? EPGCacheQueryError, .invalidRequest)
        }
    }

    func testWindowPaginationUsesOverlapBoundsAndKeysetCursor() throws {
        _ = try publish(channels: [.init(id: "one", displayName: "One")], records: [
            record(0, channel: "one", title: "Ends at lower bound", start: 0, end: 100),
            record(1, channel: "one", title: "Crosses lower bound", start: 0, end: 500),
            record(2, channel: "one", title: "Same start A", start: 100, end: 150),
            record(3, channel: "one", title: "Same start B", start: 100, end: 160),
            record(4, channel: "one", title: "Middle", start: 200, end: 250),
            record(5, channel: "one", title: "Crosses upper bound", start: 399, end: 450),
            record(6, channel: "one", title: "Starts at upper bound", start: 400, end: 500)
        ])
        let lower = Date(timeIntervalSince1970: 100), upper = Date(timeIntervalSince1970: 400)
        var cursor: EPGCacheWindowCursor?
        var ordinals: [Int] = []
        repeat {
            let page = try store.queryWindow(live("One", id: "one"), for: key,
                                             from: lower, to: upper, limit: 2, cursor: cursor)
            ordinals.append(contentsOf: page.programmes.map(\.ordinal))
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(ordinals, [1, 2, 3, 4, 5])
    }

    func testWindowCursorRejectsChangedSnapshotAndChangedWindow() throws {
        _ = try publish(channels: [.init(id: "one", displayName: "One")], records: [
            record(0, channel: "one", title: "A", start: 0, end: 100),
            record(1, channel: "one", title: "B", start: 100, end: 200)
        ])
        let lower = Date(timeIntervalSince1970: 0), upper = Date(timeIntervalSince1970: 300)
        let first = try store.queryWindow(live("One", id: "one"), for: key,
                                          from: lower, to: upper, limit: 1)
        let cursor = try XCTUnwrap(first.nextCursor)
        let forged = EPGCacheWindowCursor(version: cursor.version, snapshotID: cursor.snapshotID,
            channelKey: cursor.channelKey, windowStart: cursor.windowStart, windowEnd: cursor.windowEnd,
            lastStart: cursor.lastStart, lastOrdinal: cursor.lastOrdinal + 999)
        XCTAssertThrowsError(try store.queryWindow(live("One", id: "one"), for: key,
            from: lower, to: upper, limit: 1, cursor: forged)) {
            XCTAssertEqual($0 as? EPGCacheQueryError, .invalidCursor)
        }
        XCTAssertThrowsError(try store.queryWindow(live("One", id: "one"), for: key,
            from: lower, to: Date(timeIntervalSince1970: 301), limit: 1, cursor: cursor)) {
            XCTAssertEqual($0 as? EPGCacheQueryError, .invalidCursor)
        }

        _ = try publish(channels: [.init(id: "one", displayName: "One")], records: [
            record(0, channel: "one", title: "New", start: 0, end: 200)
        ])
        XCTAssertThrowsError(try store.queryWindow(live("One", id: "one"), for: key,
            from: lower, to: upper, limit: 1, cursor: cursor)) {
            XCTAssertEqual($0 as? EPGCacheQueryError, .snapshotChanged)
        }
    }

    func testCancellationIsDistinctAndReaderRecovers() throws {
        _ = try publish(channels: [.init(id: "one", displayName: "One")], records: [
            record(0, channel: "one", title: "A", start: 0, end: 200)
        ])
        let cancellation = EPGCacheQueryCancellation()
        let reached = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        store.readerBoundaryForTesting = { name in
            guard name == "snapshotResolved" else { return }
            reached.signal()
            _ = resume.wait(timeout: .now() + 5)
        }
        final class ErrorBox: @unchecked Sendable { var error: Error? }
        let box = ErrorBox(), finished = DispatchSemaphore(value: 0)
        let requested = live("One", id: "one"), store = self.store!, key = self.key!
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                _ = try store.queryNowNext([requested], for: key,
                                           at: Date(timeIntervalSince1970: 100),
                                           cancellation: cancellation)
            } catch { box.error = error }
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success)
        cancellation.cancel()
        resume.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        self.store.readerBoundaryForTesting = nil
        XCTAssertEqual(box.error as? EPGCacheQueryError, .cancelled)

        let recovered = try self.store.queryNowNext([requested], for: key,
            at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(recovered.entries.first?.current?.title, "A")
    }

    func testReaderQueueRejectsNinthOperationWithoutRunningIt() throws {
        _ = try publish(channels: [.init(id: "one", displayName: "One")], records: [])
        let reached = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let barrierLock = NSLock()
        var blockedOnce = false
        store.readerBoundaryForTesting = { name in
            guard name == "snapshotResolved" else { return }
            barrierLock.lock()
            let shouldBlock = !blockedOnce
            blockedOnce = true
            barrierLock.unlock()
            if shouldBlock {
                reached.signal()
                _ = resume.wait(timeout: .now() + 5)
            }
        }
        let requested = live("One"), store = self.store!, key = self.key!
        let group = DispatchGroup(), errorLock = NSLock()
        var errors: [EPGCacheQueryError] = []
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { _ = try store.matchChannels([requested], for: key) }
                catch {
                    errorLock.lock(); errors.append(error as? EPGCacheQueryError ?? .storeUnavailable); errorLock.unlock()
                }
            }
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success)
        let deadline = Date().addingTimeInterval(5)
        while store.queryOperationCountForTesting < 8, Date() < deadline { usleep(1_000) }
        XCTAssertEqual(store.queryOperationCountForTesting, 8)
        XCTAssertThrowsError(try store.matchChannels([requested], for: key)) {
            XCTAssertEqual($0 as? EPGCacheQueryError, .queueFull)
        }
        resume.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        self.store.readerBoundaryForTesting = nil
        XCTAssertTrue(errors.isEmpty)
    }

    func testVMWorkBudgetHasItsOwnError() throws {
        _ = try publish(channels: [.init(id: "one", displayName: "One")], records: [])
        store.close()
        store = try EPGCacheStore(directory: directory, queryVMInstructionBudget: 1,
                                  queryProgressStepInterval: 1)
        XCTAssertThrowsError(try store.matchChannels([live("One")], for: key)) {
            XCTAssertEqual($0 as? EPGCacheQueryError, .queryBudgetExceeded)
        }
    }

    func testWindowByteBudgetReturnsCursorWithoutDroppingUnreturnedRow() throws {
        let handle = try store.begin(key)
        try store.appendChannels([.init(id: "one", displayName: "One")], to: handle)
        let title = String(repeating: "x", count: 700_000)
        for ordinal in 0..<3 {
            try store.append([record(ordinal, channel: "one", title: title,
                                     start: Double(ordinal) * 100, end: Double(ordinal + 1) * 100)],
                             to: handle)
        }
        try store.validate(handle, summary: EPGCacheValidation(rawProgrammeCount: 3,
            emittedProgrammeCount: 3, minimumStart: Date(timeIntervalSince1970: 0),
            maximumEnd: Date(timeIntervalSince1970: 300), emittedChannelRecordCount: 1))
        _ = try store.activate(handle)

        let first = try store.queryWindow(live("One", id: "one"), for: key,
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 400), limit: 500)
        XCTAssertEqual(first.programmes.map(\.ordinal), [0, 1])
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try store.queryWindow(live("One", id: "one"), for: key,
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 400),
            limit: 500, cursor: cursor)
        XCTAssertEqual(second.programmes.map(\.ordinal), [2])
        XCTAssertNil(second.nextCursor)
    }

    func testCloseDrainsActiveAndQueuedQueriesBeforeClosingReader() throws {
        _ = try publish(channels: [.init(id: "one", displayName: "One")], records: [])
        let reached = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let barrierLock = NSLock()
        var blockedOnce = false
        store.readerBoundaryForTesting = { name in
            guard name == "snapshotResolved" else { return }
            barrierLock.lock()
            let shouldBlock = !blockedOnce
            blockedOnce = true
            barrierLock.unlock()
            if shouldBlock {
                reached.signal()
                _ = resume.wait(timeout: .now() + 5)
            }
        }
        final class ErrorsBox: @unchecked Sendable {
            let lock = NSLock()
            var values: [EPGCacheQueryError] = []
            func append(_ value: EPGCacheQueryError) { lock.lock(); values.append(value); lock.unlock() }
        }
        let errors = ErrorsBox(), queryGroup = DispatchGroup()
        let requested = live("One"), store = self.store!, key = self.key!
        for _ in 0..<2 {
            queryGroup.enter()
            DispatchQueue.global().async {
                defer { queryGroup.leave() }
                do { _ = try store.matchChannels([requested], for: key) }
                catch { errors.append(error as? EPGCacheQueryError ?? .storeUnavailable) }
            }
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success)
        let queuedDeadline = Date().addingTimeInterval(5)
        while store.queryOperationCountForTesting < 2, Date() < queuedDeadline { usleep(1_000) }
        XCTAssertEqual(store.queryOperationCountForTesting, 2)

        let closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { store.close(); closed.signal() }
        let closeDeadline = Date().addingTimeInterval(5)
        while !store.isClosingForTesting, Date() < closeDeadline { usleep(1_000) }
        XCTAssertTrue(store.isClosingForTesting)
        resume.signal()
        XCTAssertEqual(queryGroup.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(closed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(errors.values, [.storeUnavailable, .storeUnavailable])
    }
}
