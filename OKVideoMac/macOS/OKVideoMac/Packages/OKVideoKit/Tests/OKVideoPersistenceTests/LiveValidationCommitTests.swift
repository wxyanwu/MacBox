import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class LiveValidationCommitTests: XCTestCase {
    private func fixture(acceptance: Bool = false) async throws -> (SQLiteStore, StoredLiveSource, LiveChannel) {
        let root = URL(fileURLWithPath: "/private/tmp/OKVideoMac-8B3B-ValidationTest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let w = try ImportedAcceptanceWorkspace(root: root)
        let db = try acceptance ? SQLiteStore(importedAcceptance: w) : SQLiteStore(databaseURL: w.databaseURL)
        let source = StoredLiveSource(name: "Fixture", sourceKind: .remote,
            rawData: Data("#EXTM3U\n#EXTINF:-1 group-title=\"G\",X\nhttps://fixture.invalid/x\n".utf8))
        if acceptance { try await db.createLiveSource(source) } else { try await db.saveLiveSource(source) }
        return (db, source, try XCTUnwrap(LiveSourceParser().parse(source.rawData).groups.first?.channels.first))
    }
    private func seed(_ db: SQLiteStore, _ source: StoredLiveSource, _ channel: LiveChannel) async throws {
        try await db.setSetting(.array([.string("unrelated-hidden")]), forKey: "live.deletedChannels")
        let favorite = ImportedChannelMigrationPlanner.favoriteKey(sourceName: source.name, channelID: channel.id)
        try await db.setSetting(.array([.string(favorite), .string("unrelated-favorite")]), forKey: "live.favoriteChannels")
    }
    func testLegacyBatchAtomicallyUpdatesBothSettingsAndPreservesUnrelatedTokens() async throws {
        let (db, s, c) = try await fixture()
        try await seed(db, s, c)
        let p = LiveValidationPermit(sourceID: s.id)
        let result = try await db.applyLegacyLiveValidation(source: s, channels: [c], permit: p)
        XCTAssertEqual(result.hidden, ["unrelated-hidden", ImportedChannelMigrationPlanner.hiddenKey(sourceID: s.id, channelID: c.id)])
        XCTAssertEqual(result.favorites, ["unrelated-favorite"])
        XCTAssertTrue(p.didCommit); XCTAssertFalse(p.cancel())
    }
    func testCancellationAfterSQLWritesRollsBackBothLegacySettings() async throws {
        let (db, s, c) = try await fixture()
        try await seed(db, s, c)
        let beforeH = try await db.setting(forKey: "live.deletedChannels")
        let beforeF = try await db.setting(forKey: "live.favoriteChannels")
        let p = LiveValidationPermit(sourceID: s.id)
        do {
            _ = try await db.applyLegacyLiveValidation(source: s, channels: [c], permit: p, beforeCommit: { p.cancel() })
            XCTFail("cancelled batch committed")
        } catch is CancellationError {} catch { XCTFail("\(error)") }
        let afterH = try await db.setting(forKey: "live.deletedChannels")
        let afterF = try await db.setting(forKey: "live.favoriteChannels")
        XCTAssertEqual(beforeH, afterH); XCTAssertEqual(beforeF, afterF); XCTAssertFalse(p.didCommit)
    }
    func testTransactionFailureDoesNotPartiallyHideOrRemoveFavorite() async throws {
        let (db, s, c) = try await fixture()
        try await seed(db, s, c)
        let beforeH = try await db.setting(forKey: "live.deletedChannels")
        let beforeF = try await db.setting(forKey: "live.favoriteChannels")
        do {
            _ = try await db.applyLegacyLiveValidation(source: s, channels: [c],
                permit: .init(sourceID: s.id), beforeCommit: { throw ImportedExecutionError.blocked })
            XCTFail()
        } catch {}
        let afterH = try await db.setting(forKey: "live.deletedChannels"), afterF = try await db.setting(forKey: "live.favoriteChannels")
        XCTAssertEqual(beforeH, afterH); XCTAssertEqual(beforeF, afterF)
        _ = try await db.applyLegacyLiveValidation(source: s, channels: [c], permit: .init(sourceID: s.id))
    }
    func testRevokedPermitRejectedBeforeLegacyTransaction() async throws {
        let (db, s, c) = try await fixture(), p = LiveValidationPermit(sourceID: s.id)
        p.cancel()
        do { _ = try await db.applyLegacyLiveValidation(source: s, channels: [c], permit: p); XCTFail() } catch {}
        let value = try await db.setting(forKey: "live.deletedChannels"); XCTAssertNil(value)
    }
    func testOtherSourcePermitCannotWrite() async throws {
        let (db, s, c) = try await fixture()
        do { _ = try await db.applyLegacyLiveValidation(source: s, channels: [c], permit: .init(sourceID: UUID())); XCTFail() } catch {}
        let value = try await db.setting(forKey: "live.deletedChannels"); XCTAssertNil(value)
    }
    func testChangedCatalogOrNameRejectsStaleLegacyInput() async throws {
        let (db, s, c) = try await fixture()
        var newer = s; newer.name = "Renamed"
        try await db.saveLiveSource(newer)
        do { _ = try await db.applyLegacyLiveValidation(source: s, channels: [c], permit: .init(sourceID: s.id)); XCTFail() } catch {}
        newer.name = s.name; newer.rawData.append(10)
        try await db.saveLiveSource(newer)
        do { _ = try await db.applyLegacyLiveValidation(source: s, channels: [c], permit: .init(sourceID: s.id)); XCTFail() } catch {}
        let value = try await db.setting(forKey: "live.deletedChannels"); XCTAssertNil(value)
    }
    func testLegacyPathCannotBypassAcceptanceAuthority() async throws {
        let (db, s, c) = try await fixture(acceptance: true)
        do { _ = try await db.applyLegacyLiveValidation(source: s, channels: [c], permit: .init(sourceID: s.id)); XCTFail() } catch {}
    }
    func testImportedReferenceCancellationRollsBackStableWrite() async throws {
        let (db, s, c) = try await fixture(acceptance: true)
        let g = ImportedCatalogGeneration(sourceID: s.id)
        let m = try await db.importedCatalogMapping(sourceID: s.id, generation: g)
        let p = LiveValidationPermit(sourceID: s.id)
        do {
            _ = try await db.setImportedReferences(mapping: m, edits: [(c, .hidden, true)], validationPermit: p,
                beforeCommit: { p.cancel() })
            XCTFail()
        } catch is CancellationError {} catch { XCTFail("\(error)") }
        let reloaded = try await db.importedCatalogMapping(sourceID: s.id, generation: g)
        XCTAssertEqual(reloaded.value(channel: c, kind: .hidden), false); XCTAssertFalse(p.didCommit)
    }
    func testImportedCommitWinsAndRetainsNormalAuthority() async throws {
        let (db, s, c) = try await fixture(acceptance: true)
        let g = ImportedCatalogGeneration(sourceID: s.id)
        let m = try await db.importedCatalogMapping(sourceID: s.id, generation: g), p = LiveValidationPermit(sourceID: s.id)
        let updated = try await db.setImportedReferences(mapping: m, edits: [(c, .hidden, true)], validationPermit: p)
        XCTAssertEqual(updated.value(channel: c, kind: .hidden), true); XCTAssertFalse(p.cancel())
    }
    func testValidationPermitCannotOverrideRevokedGenerationOrRetiredSource() async throws {
        let (db, s, c) = try await fixture(acceptance: true)
        let g = ImportedCatalogGeneration(sourceID: s.id)
        let m = try await db.importedCatalogMapping(sourceID: s.id, generation: g)
        g.invalidate()
        do { _ = try await db.setImportedReferences(mapping: m, edits: [(c, .hidden, true)], validationPermit: .init(sourceID: s.id)); XCTFail() } catch {}
        try await db.retireImportedSource(id: s.id, revokedGeneration: g)
        do { _ = try await db.setImportedReferences(mapping: m, edits: [(c, .hidden, true)], validationPermit: .init(sourceID: s.id)); XCTFail() } catch {}
        let sources = try await db.liveSources(); XCTAssertTrue(sources.isEmpty)
    }
}
