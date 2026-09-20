import XCTest
import Foundation
import OKVideoCore
@_spi(ImportedMigration) @testable import OKVideoPersistence

final class ImportedSourceRetirementTests: XCTestCase {
    private func workspace() throws -> ImportedAcceptanceWorkspace {
        let root = URL(fileURLWithPath: "/private/tmp/OKVideoMac-8B3B-RetirementTest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try ImportedAcceptanceWorkspace(root: root)
    }
    private func source(_ id: UUID = UUID(), name: String = "Same") -> StoredLiveSource {
        StoredLiveSource(id: id, name: name, sourceKind: .remote,
            sourceValue: "https://fixture.invalid/list?token=SECRET_TOKEN_DO_NOT_PERSIST",
            rawData: Data("#EXTM3U\n#EXTINF:-1 group-title=\"G\",X\nhttps://fixture.invalid/x\n".utf8), updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
    func testSchema12MigrationPreservesExistingBusinessRowsAndReopens() async throws {
        let w = try workspace(), old = try SQLiteStore(databaseURL: w.databaseURL), s = source()
        try await old.saveLiveSource(s)
        try await old.setSetting(.string("unchanged"), forKey: "fixture")
        let db = try SQLiteStore(importedAcceptance: w)
        let rows = try await db.liveSources(), value = try await db.setting(forKey: "fixture")
        XCTAssertEqual(rows, [s]); XCTAssertEqual(value, .string("unchanged"))
        let c = try SQLiteConnection(url: w.databaseURL); defer { c.close() }
        XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 12)
        XCTAssertEqual(try ImportedSourceLifecycleSQL.history(c), [.init(id: s.id, retiredAt: nil)])
        _ = try SQLiteStore(importedAcceptance: w)
        XCTAssertThrowsError(try SQLiteStore(databaseURL: w.databaseURL))
    }
    func testMigrationFailureRollsBackColumnAndVersion() throws {
        let w = try workspace()
        _ = try SQLiteStore(databaseURL: w.databaseURL)
        let c = try SQLiteConnection(url: w.databaseURL); defer { c.close() }
        try c.execute("PRAGMA user_version=11")
        try c.execute("CREATE INDEX live_sources_active ON live_sources(id)")
        XCTAssertThrowsError(try ImportedSourceLifecycleSQL.migrate(c))
        XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 11)
        XCTAssertThrowsError(try c.query("SELECT retired_at FROM live_sources") { _ in })
    }
    func testInvalidHistoricalOwnershipRollsBackSchema12Upgrade() throws {
        let w = try workspace()
        _ = try SQLiteStore(databaseURL: w.databaseURL)
        let c = try SQLiteConnection(url: w.databaseURL); defer { c.close() }
        try ImportedMigrationStore.createAuthoritySchema(c)
        try c.execute("PRAGMA user_version=11")
        let identity = try ImportedLiveChannelIdentity(source: .imported(UUID()), localID: UUID())
        try ImportedIdentityRegistrySQL.apply(.upsert(.init(identity: identity,
            evidence: ImportedChannelEvidence(group: "G", name: "X"), provenance: .verified, lifecycle: .active,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))), connection: c)
        XCTAssertThrowsError(try ImportedSourceLifecycleSQL.migrate(c))
        XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 11)
        XCTAssertThrowsError(try c.query("SELECT retired_at FROM live_sources") { _ in })
        XCTAssertEqual(try c.scalarInt("SELECT count(*) FROM imported_channel_identities"), 1)
    }

    private func channel(_ s: StoredLiveSource) throws -> LiveChannel {
        try XCTUnwrap(LiveSourceParser().parse(s.rawData).groups.first?.channels.first)
    }
    private func seed(_ w: ImportedAcceptanceWorkspace, kind: MigrationReferenceKind, tokens: [String]) throws {
        let c = try SQLiteConnection(url: w.databaseURL); defer { c.close() }
        try c.execute("INSERT OR REPLACE INTO settings(key,value) VALUES (?,?)",
            bindings: [.text(kind == .hidden ? "live.deletedChannels" : "live.favoriteChannels"), .blob(try JSONEncoder().encode(tokens))])
    }
    private func snapshot(_ w: ImportedAcceptanceWorkspace) throws -> ImportedMigrationStoreSnapshot {
        let c = try SQLiteConnection(url: w.databaseURL); defer { c.close() }
        let t = ImportedMigrationTransaction(c); defer { t.active = false }
        return try t.snapshot()
    }
    private func retire(_ db: SQLiteStore, id: UUID) async throws {
        let g = ImportedCatalogGeneration(sourceID: id); g.invalidate()
        try await db.retireImportedSource(id: id, revokedGeneration: g)
    }

    func testRetirementPreservesHistoryWipesPayloadAndExcludesReconciliation() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source(), ch = try channel(s)
        try await db.createLiveSource(s)
        let token = ImportedChannelMigrationPlanner.hiddenKey(sourceID: s.id, channelID: ch.id)
        try seed(w, kind: .hidden, tokens: [token])
        let g = ImportedCatalogGeneration(sourceID: s.id)
        let m = try await db.importedCatalogMapping(sourceID: s.id, generation: g)
        XCTAssertEqual(m.value(channel: ch, kind: .hidden), true)
        g.invalidate()
        try await db.retireImportedSource(id: s.id, revokedGeneration: g)
        XCTAssertNil(m.value(channel: ch, kind: .hidden))
        let h = try snapshot(w)
        XCTAssertTrue(h.sources.isEmpty); XCTAssertEqual(h.registry.count, 1)
        XCTAssertEqual(h.registry.first?.lifecycle, .retired)
        XCTAssertEqual(h.claims.count, 1); XCTAssertEqual(h.stable.count, 1)
        XCTAssertEqual(h.hidden.map(\.rawValue), [token])
        XCTAssertTrue(try ImportedMigrationExecutionSession().prepare(h).rows.isEmpty)
        let c = try SQLiteConnection(url: w.databaseURL); defer { c.close() }
        XCTAssertEqual(try c.scalarInt("SELECT count(*) FROM live_sources WHERE retired_at IS NOT NULL AND source_value IS NULL AND base_url IS NULL AND length(raw_data)=0 AND name='Retired source'"), 1)
        XCTAssertThrowsError(try c.execute("UPDATE live_sources SET retired_at=NULL"))
        XCTAssertThrowsError(try c.execute("DELETE FROM live_sources"))
        XCTAssertFalse(try JSONEncoder().encode(h.retirementBlocks).contains(Data("SECRET_TOKEN_DO_NOT_PERSIST".utf8)))
    }

    func testEmptyAndUnallocatedDeferredSourcesStillBecomeTombstones() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w)
        for raw in ["#EXTM3U\n", "#EXTM3U\n#EXTINF:-1 tvg-id=\"A\",X\nhttps://fixture.invalid/a\n#EXTINF:-1 tvg-id=\"B\",X\nhttps://fixture.invalid/b\n"] {
            var s = source(); s.rawData = Data(raw.utf8)
            try await db.createLiveSource(s)
            try await retire(db, id: s.id)
            do { _ = try await db.importedCatalogMapping(sourceID: s.id, generation: .init(sourceID: s.id)); XCTFail() } catch {}
        }
        let h = try snapshot(w)
        XCTAssertEqual(h.sourceHistory.filter { $0.retiredAt != nil }.count, 2)
        XCTAssertTrue(h.registry.isEmpty)
    }

    func testEveryPublicAuthorityWriteRejectsRetiredUUIDIncludingFreshCapability() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source(), ch = try channel(s)
        try await db.createLiveSource(s)
        let g = ImportedCatalogGeneration(sourceID: s.id)
        let m = try await db.importedCatalogMapping(sourceID: s.id, generation: g)
        try await retire(db, id: s.id)
        // Even a different still-live capability cannot bypass persisted retirement.
        let calls: [() async throws -> Void] = [
            { try await db.createLiveSource(s) }, { try await db.saveLiveSource(s) },
            { try await db.acceptImportedRefresh(s, generation: g) },
            { try await db.updateImportedLiveSource(s, generation: .init(sourceID: s.id)) },
            { _ = try await db.importedCatalogMapping(sourceID: s.id, generation: .init(sourceID: s.id)) },
            { _ = try await db.setImportedReferences(mapping: m, edits: [(ch, .hidden, true)]) },
            { _ = try await db.setImportedReferences(mapping: m, edits: [(ch, .favorite, true)]) },
            { try await db.applyImportedChannelIdentityMutations([.removeAll(source: .imported(s.id))]) },
            { try await db.setSetting(.array([]), forKey: "live.deletedChannels") },
            { try await db.setSetting(.array([]), forKey: "live.favoriteChannels") }
        ]
        for (index, call) in calls.enumerated() {
            do { try await call(); XCTFail("authority entry \(index) admitted") } catch {}
        }
        let h = try snapshot(w)
        XCTAssertEqual(h.registry.count, 1); XCTAssertTrue(h.sources.isEmpty)
    }

    func testRetirementFailureAtEachCheckpointRollsBackButCapabilityStaysDead() async throws {
        for failure in 1...3 {
            let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source()
            try await db.createLiveSource(s)
            let g = ImportedCatalogGeneration(sourceID: s.id)
            _ = try await db.importedCatalogMapping(sourceID: s.id, generation: g)
            let before = try snapshot(w)
            g.invalidate()
            do {
                try await db.retireImportedSource(id: s.id, revokedGeneration: g, checkpoint: { if $0 == failure { throw ImportedExecutionError.blocked } })
                XCTFail("injected failure did not abort")
            } catch {}
            let after = try snapshot(w)
            XCTAssertEqual(after.sources, before.sources); XCTAssertEqual(after.registry, before.registry)
            XCTAssertEqual(after.claims, before.claims); XCTAssertEqual(after.stable, before.stable)
            XCTAssertEqual(after.sourceHistory, before.sourceHistory); XCTAssertTrue(after.retirementBlocks.isEmpty)
            XCTAssertFalse(g.isCurrent)
            do { try await db.acceptImportedRefresh(s, generation: g); XCTFail() } catch {}
            _ = try await db.importedCatalogMapping(sourceID: s.id, generation: .init(sourceID: s.id))
            try await retire(db, id: s.id) // clean retry, no duplicated identity
        }
    }

    func testSameNameURLReaddAndRestartCannotReadAmbiguousLegacyFavorite() async throws {
        let w = try workspace(), s = source(), ch = try channel(s)
        var db: SQLiteStore? = try SQLiteStore(importedAcceptance: w)
        try await db!.createLiveSource(s)
        let favorite = ImportedChannelMigrationPlanner.favoriteKey(sourceName: s.name, channelID: ch.id)
        try seed(w, kind: .favorite, tokens: [favorite, "orphan::opaque::token"])
        try await retire(db!, id: s.id) // no Registry allocation is required
        db = nil
        db = try SQLiteStore(importedAcceptance: w)
        let added = source()
        XCTAssertNotEqual(added.id, s.id); XCTAssertEqual(added.sourceValue, s.sourceValue)
        try await db!.createLiveSource(added)
        let m = try await db!.importedCatalogMapping(sourceID: added.id, generation: .init(sourceID: added.id))
        XCTAssertEqual(m.authority(channel: ch, kind: .favorite), .blocked)
        XCTAssertNil(m.value(channel: ch, kind: .favorite))
        XCTAssertTrue(try snapshot(w).favorites.map(\.rawValue).contains(favorite))
    }

    func testExistingActiveSourceKeepsLegacyBehaviorButNewNamespaceDoesNot() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), a = source(), b = source(), ch = try channel(a)
        try await db.createLiveSource(a); try await db.createLiveSource(b)
        let token = ImportedChannelMigrationPlanner.favoriteKey(sourceName: a.name, channelID: ch.id)
        try seed(w, kind: .favorite, tokens: [token])
        try await retire(db, id: a.id)
        let m = try await db.importedCatalogMapping(sourceID: b.id, generation: .init(sourceID: b.id))
        XCTAssertEqual(m.authority(channel: ch, kind: .favorite), .legacy)
        XCTAssertEqual(m.value(channel: ch, kind: .favorite), true)
        XCTAssertTrue(try snapshot(w).claims.isEmpty) // no provenance elevation
    }

    func testUpdateRequiresExistingSourceAndCreateCannotOverwrite() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source()
        do { try await db.updateImportedLiveSource(s, generation: .init(sourceID: s.id)); XCTFail() } catch {}
        try await db.createLiveSource(s)
        do { try await db.createLiveSource(s); XCTFail() } catch {}
        var renamed = s; renamed.name = "Renamed"
        try await db.updateImportedLiveSource(renamed, generation: .init(sourceID: s.id))
        let rows = try await db.liveSources(); XCTAssertEqual(rows, [renamed])
    }

    private func claimBoth(_ w: ImportedAcceptanceWorkspace, source s: StoredLiveSource) throws {
        let c = try SQLiteConnection(url: w.databaseURL); defer { c.close() }
        try c.transaction {
            let t = ImportedMigrationTransaction(c); defer { t.active = false }
            let identity = try XCTUnwrap(t.snapshot().registry.first { $0.identity.source == .imported(s.id) }?.identity)
            let ch = try channel(s)
            for kind in [MigrationReferenceKind.hidden, .favorite] {
                let token = kind == .hidden ? ImportedChannelMigrationPlanner.hiddenKey(sourceID: s.id, channelID: ch.id) : ImportedChannelMigrationPlanner.favoriteKey(sourceName: s.name, channelID: ch.id)
                _ = try t.claim(.init(sourceID: s.id, kind: kind, legacyToken: token, identity: identity))
                try t.setStable(.init(identity: identity, kind: kind), present: true)
            }
        }
    }

    func testRenameKeepsProvenClaimedHiddenAndFavoriteAndUUID() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source(), ch = try channel(s)
        try await db.createLiveSource(s)
        _ = try await db.importedCatalogMapping(sourceID: s.id, generation: .init(sourceID: s.id))
        try claimBoth(w, source: s)
        let before = try snapshot(w)
        var renamed = s; renamed.name = "Renamed"
        try await db.updateImportedLiveSource(renamed, generation: .init(sourceID: s.id))
        let after = try await db.importedCatalogMapping(sourceID: s.id, generation: .init(sourceID: s.id))
        XCTAssertEqual(after.value(channel: ch, kind: .hidden), true)
        XCTAssertEqual(after.value(channel: ch, kind: .favorite), true)
        XCTAssertEqual(try snapshot(w).registry.map(\.identity), before.registry.map(\.identity))
        XCTAssertEqual(try snapshot(w).claims, before.claims)
    }

    func testClaimedStatesNeverTransferAfterRetirementAndReopen() async throws {
        let w = try workspace(), s = source(), ch = try channel(s)
        var db: SQLiteStore? = try SQLiteStore(importedAcceptance: w)
        try await db!.createLiveSource(s)
        _ = try await db!.importedCatalogMapping(sourceID: s.id, generation: .init(sourceID: s.id))
        try claimBoth(w, source: s)
        let before = try snapshot(w)
        try await retire(db!, id: s.id)
        db = nil; db = try SQLiteStore(importedAcceptance: w)
        let added = source()
        try await db!.createLiveSource(added)
        let m = try await db!.importedCatalogMapping(sourceID: added.id, generation: .init(sourceID: added.id))
        XCTAssertEqual(m.value(channel: ch, kind: .hidden), false)
        XCTAssertEqual(m.authority(channel: ch, kind: .favorite), .blocked)
        let after = try snapshot(w)
        XCTAssertEqual(after.claims, before.claims); XCTAssertEqual(after.stable, before.stable)
        XCTAssertEqual(after.registry.count, 2)
        XCTAssertNotEqual(after.registry[0].identity.localID, after.registry[1].identity.localID)
    }

    func testBorrowedTransactionWritersCannotBypassRetirement() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source()
        try await db.createLiveSource(s)
        _ = try await db.importedCatalogMapping(sourceID: s.id, generation: .init(sourceID: s.id))
        try claimBoth(w, source: s)
        let before = try snapshot(w), record = try XCTUnwrap(before.registry.first), claim = try XCTUnwrap(before.claims.first)
        try await retire(db, id: s.id)
        let c = try SQLiteConnection(url: w.databaseURL); defer { c.close() }
        let t = ImportedMigrationTransaction(c); defer { t.active = false }
        XCTAssertThrowsError(try t.insertIdentity(record))
        XCTAssertThrowsError(try t.claim(claim))
        XCTAssertThrowsError(try t.setStable(.init(identity: record.identity, kind: .hidden), present: false))
        XCTAssertThrowsError(try t.setLegacy(sourceID: s.id, kind: .favorite, token: "opaque", present: true))
        XCTAssertThrowsError(try t.preserveUnprovenReference(.init(kind: .favorite, legacyToken: "opaque"), sourceID: s.id))
        XCTAssertThrowsError(try t.recordBatch(.init(id: UUID(), identities: [record.identity], claims: [])))
    }

    func testOtherActiveProvenStableFavoriteSurvivesSameTokenRetirement() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), a = source(), b = source(), ch = try channel(a)
        try await db.createLiveSource(a); try await db.createLiveSource(b)
        for s in [a, b] {
            _ = try await db.importedCatalogMapping(sourceID: s.id, generation: .init(sourceID: s.id))
            try claimBoth(w, source: s)
        }
        try await retire(db, id: a.id)
        let m = try await db.importedCatalogMapping(sourceID: b.id, generation: .init(sourceID: b.id))
        XCTAssertEqual(m.value(channel: ch, kind: .favorite), true)
        let edited = try await db.setImportedReferences(mapping: m, edits: [(ch, .favorite, false)])
        XCTAssertEqual(edited.value(channel: ch, kind: .favorite), false)
    }
}
