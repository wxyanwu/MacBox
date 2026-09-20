import XCTest
@testable import OKVideoCore

final class EPGRepositoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EPG-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func key(_ source: LiveSourceID = .imported(UUID()), revision: String = "1") -> EPGRequestKey {
        EPGRequestKey(source: source, revision: revision, resource: "xmltv")
    }
    private func payload() -> EPGPayload {
        EPGPayload(guide: XMLTVGuide(channels: [], programmes: [
            EPGProgramme(channelID: "one", title: "News", start: Date(timeIntervalSince1970: 100),
                         end: Date(timeIntervalSince1970: 1000))
        ]))
    }

    func testDiskRestartAndFailureRetainSchedule() async throws {
        let directory = try directory(), key = key(), payload = payload()
        let first = try EPGRepository(cacheDirectory: directory, now: { Date(timeIntervalSince1970: 200) })
        _ = try await first.load(key, ttl: 60) { payload }
        let second = try EPGRepository(cacheDirectory: directory, now: { Date(timeIntervalSince1970: 300) })
        let cached = await second.cached(key)
        XCTAssertEqual(cached?.availability, .stale)
        let value = try await second.load(key, ttl: 60) { throw EPGFetchError.unavailable }
        XCTAssertEqual(value.availability, .stale)
        XCTAssertEqual(value.nowNext(for: LiveChannel(groupName: "", name: "one", streams: []),
                                    at: Date(timeIntervalSince1970: 300)).current?.title, "News")
    }

    func testRequestsDeduplicateAndDeletionRejectsLateResults() async throws {
        let repository = try EPGRepository(cacheDirectory: directory())
        let key = key(), gate = EPGTestGate(), payload = payload()
        let first = Task { try await repository.load(key, ttl: 60) { await gate.wait(); return payload } }
        await gate.started()
        let second = Task { try await repository.load(key, ttl: 60) { XCTFail("Duplicate request"); return payload } }
        await Task.yield()
        await gate.release()
        _ = try await first.value
        _ = try await second.value
        let lateGate = EPGTestGate()
        let late = Task { try await repository.load(key, ttl: 60, force: true) { await lateGate.wait(); return payload } }
        await lateGate.started()
        await repository.invalidate(source: key.source)
        await lateGate.release()
        do { _ = try await late.value; XCTFail("Invalidated result published") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let cached = await repository.cached(key)
        XCTAssertNil(cached)
    }

    func testRevisionAndProviderIsolationAndCorruptCacheRecovery() async throws {
        let directory = try directory(), id = UUID(), payload = payload()
        let repository = try EPGRepository(cacheDirectory: directory)
        let original = key(.xtream(id))
        _ = try await repository.load(original, ttl: 60) { payload }
        let imported = await repository.cached(key(.imported(id)))
        let revision = await repository.cached(key(.xtream(id), revision: "2"))
        XCTAssertNil(imported)
        XCTAssertNil(revision)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: file)
        let restarted = try EPGRepository(cacheDirectory: directory)
        let recovered = try await restarted.load(original, ttl: 60) { payload }
        XCTAssertEqual(recovered.availability, .fresh)
    }

    func testSameURLReturningAfterConfigurationInvalidationRejectsOriginalFlight() async throws {
        let directory = try directory()
        let repository = try EPGRepository(cacheDirectory: directory)
        let source = LiveSourceID.imported(UUID()), originalGate = EPGTestGate()
        let originalKey = key(source, revision: "A"), otherKey = key(source, revision: "B")
        let original = Task { try await repository.load(originalKey, ttl: 60) {
            await originalGate.wait()
            return EPGPayload(guide: XMLTVGuide(channels: [], programmes: []), unsupported: true)
        } }
        await originalGate.started()
        await repository.invalidate(source: originalKey.source, removeCache: false)
        _ = try await repository.load(otherKey, ttl: 60) { EPGPayload(guide: XMLTVGuide(channels: [], programmes: [])) }
        await repository.invalidate(source: originalKey.source, removeCache: false)
        let latest = try await repository.load(originalKey, ttl: 60) { EPGPayload(guide: XMLTVGuide(channels: [], programmes: [])) }
        await originalGate.release()
        do { _ = try await original.value; XCTFail("First A must not publish") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        let cached = await repository.cached(originalKey)
        XCTAssertEqual(cached?.availability, latest.availability)
        XCTAssertEqual(cached?.availability, .empty)
        let restarted = try EPGRepository(cacheDirectory: directory)
        let persisted = await restarted.cached(originalKey)
        XCTAssertEqual(persisted?.availability, .empty)
    }

    func testMasterOffOnRejectsOldFlightWhileNewSameKeyFlightIsPending() async throws {
        let repository = try EPGRepository(cacheDirectory: directory())
        let key = key(), oldGate = EPGTestGate(), newGate = EPGTestGate()
        let old = Task { try await repository.load(key, ttl: 60) {
            await oldGate.wait()
            return EPGPayload(guide: XMLTVGuide(channels: [], programmes: []), unsupported: true)
        } }
        await oldGate.started()
        await repository.cancelRequests()
        let current = Task { try await repository.load(key, ttl: 60) {
            await newGate.wait()
            return EPGPayload(guide: XMLTVGuide(channels: [], programmes: []))
        } }
        await newGate.started()
        await oldGate.release()
        do { _ = try await old.value; XCTFail("Old enabled generation published") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        let stale = await repository.cached(key)
        XCTAssertNil(stale)
        await newGate.release()
        let result = try await current.value
        XCTAssertEqual(result.availability, .empty)
    }

    func testEmptyUnsupportedAndFailureAreDistinct() async throws {
        let repository = try EPGRepository(cacheDirectory: directory())
        let empty = try await repository.load(key(), ttl: 60) { EPGPayload(guide: XMLTVGuide(channels: [], programmes: [])) }
        let unsupported = try await repository.load(key(), ttl: 60) { EPGPayload(guide: XMLTVGuide(channels: [], programmes: []), unsupported: true) }
        let failure = try await repository.load(key(), ttl: 60) { throw EPGFetchError.unavailable }
        XCTAssertEqual(empty.availability, .empty)
        XCTAssertEqual(unsupported.availability, .unsupported)
        XCTAssertEqual(failure.availability, .failed)
    }

    func testLegacyXMLTVCacheSurvivesOfflineUpgradeAndStaysSourceScoped() async throws {
        struct Legacy: Encodable { let fetchedAt: Date; let guide: XMLTVGuide }
        let legacyDirectory = try directory()
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let revision = EPGRequestKey.revision(for: Data("https://fixture.invalid/epg.xml".utf8))
        let file = legacyDirectory.appendingPathComponent(revision + ".json")
        try JSONEncoder().encode(Legacy(fetchedAt: Date(timeIntervalSince1970: 100), guide: payload().guide)).write(to: file)
        let repository = try EPGRepository(cacheDirectory: directory(), now: { Date(timeIntervalSince1970: 30_000) })
        let imported = key(revision: revision)
        await repository.migrateLegacyXMLTV(imported, from: legacyDirectory)
        let cached = await repository.cached(imported)
        XCTAssertEqual(cached?.availability, .stale)
        let offline = try await repository.load(imported, ttl: 60) { throw EPGFetchError.unavailable }
        XCTAssertEqual(offline.programmeCount, 1)
        XCTAssertEqual(offline.availability, .stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let native = key(.xtream(imported.source.id), revision: revision)
        await repository.migrateLegacyXMLTV(native, from: legacyDirectory)
        let nativeCached = await repository.cached(native)
        XCTAssertNil(nativeCached)
    }
}

private actor EPGTestGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func started() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
