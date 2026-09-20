import Foundation
import XCTest
import OKVideoCore
@_spi(ImportedMigration) @testable import OKVideoPersistence
@_spi(ImportedMigration) @testable import OKVideoMigrationDiagnostics

final class ImportedExecutorTests: XCTestCase {
    private struct Fixture {
        let url: URL
        let store: ImportedMigrationStore
        var source: UUID { AdmissionFixture.a }
        func sql(_ body: (SQLiteConnection) throws -> Void) throws {
            let c = try SQLiteConnection(url: url); defer { c.close() }; try body(c)
        }
        func sourceData(_ data: String) throws {
            try sql { try $0.execute("UPDATE live_sources SET raw_data=?", bindings: [.blob(Data(data.utf8))]) }
        }
        func channels() throws -> [LiveChannel] { try LiveSourceParser().parse(store.read().sources[0].rawData).groups.flatMap(\.channels) }
    }
    private func fixture(raw: String? = nil, hidden: Bool = true, schema: Int = 10) throws -> Fixture {
        let dir = URL(fileURLWithPath: "/private/tmp/OKVideoMac-8B3A-Test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("work.sqlite3")
        do { _ = try SQLiteStore(databaseURL: url) }
        do {
            let c = try SQLiteConnection(url: url); defer { c.close() }
            if schema == 9 { try c.execute("DROP TABLE imported_channel_identities"); try c.execute("PRAGMA user_version=9") }
            let s = AdmissionFixture.source(raw)
            try c.execute("INSERT INTO live_sources(id,name,source_kind,raw_data,updated_at) VALUES (?,?,?,?,?)",
                bindings: [.text(s.id.uuidString), .text(s.name), .text(s.sourceKind.rawValue), .blob(s.rawData), .double(0)])
            try c.execute("INSERT INTO settings(key,value) VALUES ('live.deletedChannels',?)",
                bindings: [.blob(try JSONEncoder().encode(hidden ? [AdmissionFixture.hidden] : []))])
        }
        return try Fixture(url: url, store: ImportedMigrationStore(temporaryWorkCopy: url))
    }
    private func run(_ f: Fixture) throws -> ImportedExecutionResult {
        let session = ImportedMigrationExecutionSession()
        return try session.execute(session.prepare(f.store.read()), store: f.store)
    }
    private func line(_ name: String, id: String = "", suffix: String = "") -> String {
        "#EXTINF:-1 tvg-id=\"\(id)\" group-title=\"G\",\(name)\nhttps://fixture.invalid/\(name)\(suffix)\n"
    }
    func testSchema9ExplicitWorkCopyMigratesAtomicallyTo11() throws {
        let f = try fixture(schema: 9); defer { f.store.close() }
        try f.sql { XCTAssertEqual(try $0.scalarInt("PRAGMA user_version"), 11) }
        XCTAssertEqual(try f.store.read().registry.count, 0)
    }
    func testFirstExecutionPersistsIdentityClaimStateProofWithoutLegacyDeletion() throws {
        let f = try fixture(); defer { f.store.close() }; let before = try f.store.read()
        let r = try run(f); XCTAssertEqual(r.allocated, 1); XCTAssertEqual(r.claimed, 1)
        let after = try f.store.read(); XCTAssertEqual(after.registry.count, 1); XCTAssertEqual(after.claims.count, 1)
        XCTAssertEqual(after.stable.count, 1); XCTAssertEqual(after.batches.count, 1)
        XCTAssertEqual(after.sources, before.sources); XCTAssertEqual(after.hidden, before.hidden)
        XCTAssertEqual(after.favorites, before.favorites)
    }
    func testNewSessionReopenReplansMatchedAndExecutesNoOp() throws {
        let f = try fixture(); _ = try run(f); let ids = try f.store.read().registry.map(\.identity); f.store.close()
        let reopened = try ImportedMigrationStore(temporaryWorkCopy: f.url); defer { reopened.close() }
        let session = ImportedMigrationExecutionSession(); let plan = try session.prepare(reopened.read())
        XCTAssertEqual(plan.counts["matched"], 1); XCTAssertEqual(plan.claimsRequired, 0)
        let r = try session.execute(plan, store: reopened)
        XCTAssertEqual(r.allocated, 0); XCTAssertEqual(r.claimed, 0); XCTAssertFalse(r.batchRecorded)
        XCTAssertEqual(try reopened.read().registry.map(\.identity), ids)
    }
    func testOldSessionFingerprintNeverWorksInNewSession() throws {
        let f = try fixture(); defer { f.store.close() }
        let p = try ImportedMigrationExecutionSession().prepare(f.store.read())
        XCTAssertThrowsError(try ImportedMigrationExecutionSession().execute(p, store: f.store))
        XCTAssertEqual(try f.store.read().registry.count, 0)
    }
    func testInputChangeBetweenPrepareAndBeginRejected() throws {
        let f = try fixture(); defer { f.store.close() }; let s = ImportedMigrationExecutionSession()
        let p = try s.prepare(f.store.read()); try f.sourceData("#EXTM3U\n" + line("Changed"))
        XCTAssertThrowsError(try s.execute(p, store: f.store)); XCTAssertEqual(try f.store.read().registry.count, 0)
    }
    func testFailureAtEveryStageRollsBackAndRetrySucceeds() throws {
        for stage in 1...4 {
            let f = try fixture(); defer { f.store.close() }; let s = ImportedMigrationExecutionSession()
            let p = try s.prepare(f.store.read())
            XCTAssertThrowsError(try s.execute(p, store: f.store, checkpoint: { if $0 == stage { throw ImportedExecutionError.blocked } }))
            let empty = try f.store.read()
            XCTAssertTrue(empty.registry.isEmpty && empty.claims.isEmpty && empty.stable.isEmpty && empty.batches.isEmpty)
            XCTAssertEqual(try s.execute(p, store: f.store).allocated, 1)
        }
    }
    func testSQLiteTriggerFailureRollsBackAll() throws {
        let f = try fixture(); defer { f.store.close() }
        try f.sql { try $0.execute("CREATE TRIGGER injected BEFORE INSERT ON imported_stable_references BEGIN SELECT RAISE(ABORT,'injected'); END") }
        XCTAssertThrowsError(try run(f)); XCTAssertTrue(try f.store.read().registry.isEmpty)
    }
    func testStableUnhideNewSessionDoesNotReviveLegacy() throws {
        let f = try fixture(); _ = try run(f)
        let ids = try f.store.read().registry.map(\.identity), channel = try f.channels()[0]
        let s = ImportedMigrationExecutionSession(); let p = try s.prepare(f.store.read())
        try s.write(p, store: f.store, sourceID: f.source, channel: channel, kind: .hidden, present: false)
        XCTAssertEqual(try f.store.read().hidden.map(\.rawValue), [AdmissionFixture.hidden]); f.store.close()
        let db = try ImportedMigrationStore(temporaryWorkCopy: f.url); defer { db.close() }
        let next = ImportedMigrationExecutionSession(); let plan = try next.prepare(db.read())
        XCTAssertEqual(next.value(plan, sourceID: f.source, channel: channel, kind: .hidden), false)
        XCTAssertEqual(try next.execute(plan, store: db).allocated, 0)
        XCTAssertEqual(try db.read().registry.map(\.identity), ids); XCTAssertEqual(try db.read().claims.count, 1)
        XCTAssertTrue(try db.read().stable.isEmpty)
    }
    func testUnclaimedWritesOnlyLegacy() throws {
        let f = try fixture(hidden: false); defer { f.store.close() }; let s = ImportedMigrationExecutionSession()
        let p = try s.prepare(f.store.read()), channel = try f.channels()[0]
        XCTAssertEqual(s.authority(p, sourceID: f.source, channel: channel, kind: .hidden), .legacy)
        try s.write(p, store: f.store, sourceID: f.source, channel: channel, kind: .hidden, present: true)
        let snapshot = try f.store.read(); XCTAssertEqual(snapshot.hidden.map(\.rawValue), [AdmissionFixture.hidden])
        XCTAssertTrue(snapshot.registry.isEmpty && snapshot.claims.isEmpty && snapshot.stable.isEmpty)
    }
    func testStaleAdapterWriteIsRejected() throws {
        let f = try fixture(); defer { f.store.close() }; let s = ImportedMigrationExecutionSession()
        let p = try s.prepare(f.store.read()), channel = try f.channels()[0]; _ = try s.execute(p, store: f.store)
        XCTAssertThrowsError(try s.write(p, store: f.store, sourceID: f.source, channel: channel, kind: .hidden, present: false))
    }
    func testAlreadyClaimedBecomesDeferredNeverFallsBackToLegacy() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        try f.sourceData("#EXTM3U\n" + line("One", suffix: "a") + line("One", suffix: "b"))
        let s = ImportedMigrationExecutionSession(); let p = try s.prepare(f.store.read()), channel = try f.channels()[0]
        XCTAssertEqual(p.counts["deferred"], 1)
        XCTAssertEqual(s.authority(p, sourceID: f.source, channel: channel, kind: .hidden), .blocked)
        XCTAssertNil(s.value(p, sourceID: f.source, channel: channel, kind: .hidden))
        XCTAssertThrowsError(try s.write(p, store: f.store, sourceID: f.source, channel: channel, kind: .hidden, present: false))
    }
    func testFullChannelObjectRequiredNotOnlyRuntimeID() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        let s = ImportedMigrationExecutionSession(); let p = try s.prepare(f.store.read())
        var channel = try f.channels()[0]; channel.tvgID = "not-the-current-input"
        XCTAssertEqual(channel.id, "G::One")
        XCTAssertEqual(s.authority(p, sourceID: f.source, channel: channel, kind: .hidden), .blocked)
        XCTAssertEqual(s.authority(p, sourceID: AdmissionFixture.b, channel: channel, kind: .hidden), .blocked)
    }
    func testIncrementalThreeChannelsKeepsExistingUUIDAndClaim() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        let id = try f.store.read().registry[0].identity
        try f.sourceData("#EXTM3U\n" + line("One") + line("Two") + line("Three") + line("Four"))
        let result = try run(f); XCTAssertEqual(result.allocated, 3); XCTAssertEqual(result.claimed, 0)
        XCTAssertTrue(try f.store.read().registry.contains { $0.identity == id })
        XCTAssertEqual(try f.store.read().registry.count, 4)
        XCTAssertEqual(try run(f).allocated, 0)
    }
    func testDeferredBecomesEligibleWithoutNameBlacklist() throws {
        let f = try fixture(raw: "#EXTM3U\n" + line("UnknownStation", suffix: "a") + line("UnknownStation", suffix: "b"), hidden: false)
        defer { f.store.close() }
        XCTAssertEqual(try run(f).allocated, 0)
        try f.sourceData("#EXTM3U\n" + line("UnknownStation", id: "now-unique"))
        XCTAssertEqual(try run(f).allocated, 1)
    }
    func testImprovedDeferredCannotAutoInheritPreviouslyUnprovenHidden() throws {
        let f = try fixture(raw: "#EXTM3U\n" + line("One", suffix: "a") + line("One", suffix: "b"))
        defer { f.store.close() }
        XCTAssertEqual(try run(f).allocated, 0); XCTAssertEqual(try f.store.read().holds.count, 1)
        try f.sourceData("#EXTM3U\n" + line("One", id: "improved"))
        let r = try run(f); XCTAssertEqual(r.allocated, 1); XCTAssertEqual(r.claimed, 0)
        XCTAssertEqual(try f.store.read().hidden.map(\.rawValue), [AdmissionFixture.hidden])
        XCTAssertTrue(try f.store.read().stable.isEmpty)
    }
    func testNewConflictingChannelDoesNotStealOldIdentity() throws {
        let f = try fixture(raw: "#EXTM3U\n" + line("One", id: "shared")); defer { f.store.close() }
        _ = try run(f); let ids = try f.store.read().registry.map(\.identity)
        try f.sourceData("#EXTM3U\n" + line("One", id: "shared") + line("Two", id: "shared"))
        let r = try run(f); XCTAssertEqual(r.allocated, 0); XCTAssertEqual(r.claimed, 0)
        XCTAssertEqual(try f.store.read().registry.map(\.identity), ids)
    }
    func testMarkerDoesNotSealEntireSource() throws {
        let f = try fixture(hidden: false); defer { f.store.close() }; _ = try run(f)
        XCTAssertEqual(try f.store.read().batches.count, 1)
        try f.sourceData("#EXTM3U\n" + line("One") + line("New"))
        XCTAssertEqual(try run(f).allocated, 1); XCTAssertEqual(try f.store.read().batches.count, 2)
    }
    func testMissingMarkerDoesNotEraseRegistryAuthority() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        try f.sql { try $0.execute("DELETE FROM imported_migration_batches") }
        XCTAssertEqual(try run(f).allocated, 0); XCTAssertEqual(try f.store.read().registry.count, 1)
    }
    func testClaimMissingRegistryIsCorruptionNotRepair() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        try f.sql { try $0.execute("PRAGMA foreign_keys=OFF"); try $0.execute("DELETE FROM imported_channel_identities") }
        XCTAssertThrowsError(try f.store.read()); XCTAssertThrowsError(try run(f))
    }
    func testMarkerMissingCoreClaimIsCorruption() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        try f.sql { try $0.execute("DELETE FROM imported_reference_claims"); try $0.execute("DELETE FROM imported_stable_references") }
        XCTAssertThrowsError(try f.store.read())
    }
    func testMarkerDoesNotRequireStableHiddenToRemainTrue() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        try f.sql { try $0.execute("DELETE FROM imported_stable_references") }
        XCTAssertNoThrow(try f.store.read()); XCTAssertEqual(try run(f).claimed, 0)
    }
    func testExactClaimIsIdempotentDifferentIdentityRejected() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        let claim = try f.store.read().claims[0]
        try f.store.transaction { t in
            XCTAssertFalse(try t.claim(claim))
            let other = try ImportedReferenceClaim(sourceID: f.source, kind: .hidden, legacyToken: claim.legacyToken,
                identity: ImportedLiveChannelIdentity(source: .imported(f.source), localID: AdmissionFixture.local))
            XCTAssertThrowsError(try t.claim(other))
        }
    }
    func testDatabaseUniqueConstraintRejectsSecondClaimEvenByRawSQL() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        try f.sql { c in
            XCTAssertThrowsError(try c.execute("INSERT INTO imported_reference_claims SELECT source_id,kind,legacy_reference,? FROM imported_reference_claims",
                bindings: [.text(AdmissionFixture.local.uuidString.lowercased())]))
            XCTAssertThrowsError(try c.execute("UPDATE imported_reference_claims SET local_id=?", bindings: [.text(AdmissionFixture.local.uuidString.lowercased())]))
        }
    }
    func testSameTokenOtherSourceAndKindHaveSeparateNamespaces() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        let first = try f.store.read().claims[0]
        try f.store.transaction { t in
            let otherRecord = try AdmissionFixture.record(source: AdmissionFixture.b)
            try t.insertIdentity(otherRecord)
            XCTAssertTrue(try t.claim(ImportedReferenceClaim(sourceID: AdmissionFixture.b, kind: .hidden, legacyToken: first.legacyToken, identity: otherRecord.identity)))
            XCTAssertTrue(try t.claim(ImportedReferenceClaim(sourceID: f.source, kind: .favorite, legacyToken: first.legacyToken, identity: first.identity)))
        }
        XCTAssertEqual(try f.store.read().claims.count, 3)
    }
    func testCompositeForeignKeyRejectsMissingIdentityAndDelete() throws {
        let f = try fixture(); defer { f.store.close() }
        try f.store.transaction { t in XCTAssertThrowsError(try t.claim(AdmissionFixture.claim())) }
        _ = try run(f)
        try f.sql { c in try c.execute("PRAGMA foreign_keys=ON"); XCTAssertThrowsError(try c.execute("DELETE FROM imported_channel_identities")) }
    }
    func testEscapedTransactionCannotWrite() throws {
        let f = try fixture(); defer { f.store.close() }; var escaped: ImportedMigrationTransaction?
        try f.store.transaction { escaped = $0 }
        XCTAssertThrowsError(try escaped?.insertIdentity(AdmissionFixture.record()))
    }
    func testFavoriteUnknownProvenancePreservedNotClaimed() throws {
        let f = try fixture(hidden: false); defer { f.store.close() }
        try f.sql { try $0.execute("INSERT INTO settings(key,value) VALUES ('live.favoriteChannels',?)", bindings: [.blob(try JSONEncoder().encode([AdmissionFixture.favorite]))]) }
        XCTAssertEqual(try run(f).claimed, 0); XCTAssertTrue(try f.store.read().claims.isEmpty)
        XCTAssertEqual(try f.store.read().favorites.map(\.rawValue), [AdmissionFixture.favorite])
    }
    func testDeferredStillParticipatesInFullCatalogUniqueness() throws {
        let f = try fixture(raw: "#EXTM3U\n" + line("One", id: "shared")); defer { f.store.close() }; _ = try run(f)
        try f.sourceData("#EXTM3U\n" + line("One", id: "shared") + line("Two", id: "shared", suffix: "a") + line("Two", id: "shared", suffix: "b"))
        let s = ImportedMigrationExecutionSession(); let p = try s.prepare(f.store.read())
        XCTAssertEqual(p.rows.first { $0.name == "One" }?.disposition, .blocked)
        XCTAssertEqual(try s.execute(p, store: f.store).allocated, 0)
    }
    func testReportDoesNotDiscloseLocatorsHeadersOrLegacyTokens() throws {
        let f = try fixture(raw: ParserOutputEquivalence.fixtures["headers"]!, hidden: false); defer { f.store.close() }
        let p = try ImportedMigrationExecutionSession().prepare(f.store.read())
        let output = String(decoding: try p.json(), as: UTF8.self) + String(reflecting: p)
        for value in ["SECRET_TOKEN_DO_NOT_PERSIST", "CANARY", "fixture.invalid", "Cookie", "Authorization", AdmissionFixture.hidden] {
            XCTAssertFalse(output.contains(value))
        }
    }
    func testUserDatabasePathRejectedBeforeWritableOpen() throws {
        XCTAssertThrowsError(try ImportedMigrationStore(temporaryWorkCopy: URL(fileURLWithPath: "/Users/fixture/Library/Database/OKVideoMac.sqlite3")))
    }
    func testSchemaFailureRollsBackTablesAndVersion() throws {
        let f = try fixture(); f.store.close()
        try f.sql { c in
            for table in ["imported_migration_batches", "imported_reference_claims", "imported_stable_references", "imported_reference_holds"] {
                try c.execute("DROP TABLE \(table)")
            }
            try c.execute("PRAGMA user_version=10")
            try c.execute("CREATE TABLE imported_stable_references(injected TEXT)")
        }
        XCTAssertThrowsError(try ImportedMigrationStore(temporaryWorkCopy: f.url))
        try f.sql { c in
            XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 10)
            XCTAssertEqual(try c.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='imported_reference_claims'"), 0)
            XCTAssertEqual(try c.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='imported_migration_batches'"), 0)
        }
    }
    func testInvalidExistingDataRollsBackSchemaUpgrade() throws {
        let f = try fixture(); f.store.close()
        try f.sql { c in
            for table in ["imported_migration_batches", "imported_reference_claims", "imported_stable_references", "imported_reference_holds"] { try c.execute("DROP TABLE \(table)") }
            try c.execute("PRAGMA user_version=10")
            try c.execute("UPDATE settings SET value=?", bindings: [.blob(Data("invalid".utf8))])
        }
        XCTAssertThrowsError(try ImportedMigrationStore(temporaryWorkCopy: f.url))
        try f.sql { XCTAssertEqual(try $0.scalarInt("PRAGMA user_version"), 10) }
    }
    func testClaimPointingAtDifferentValidIdentityDetectedByProof() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        try f.store.transaction { try $0.insertIdentity(AdmissionFixture.record()) }
        try f.sql { c in
            try c.execute("DROP TRIGGER imported_claim_immutable")
            try c.execute("UPDATE imported_reference_claims SET local_id=?", bindings: [.text(AdmissionFixture.local.uuidString.lowercased())])
            try c.execute("DELETE FROM imported_stable_references")
        }
        XCTAssertThrowsError(try f.store.read())
    }
    func testMarkerUnknownFieldsFailClosed() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        try f.sql { try $0.execute("UPDATE imported_migration_batches SET proof=?", bindings: [.blob(Data("{\"future\":true}".utf8))]) }
        XCTAssertThrowsError(try f.store.read())
    }
    func testNewSourceAfterExistingBatchIsNotSkipped() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        let s = AdmissionFixture.source(id: AdmissionFixture.b)
        try f.sql { try $0.execute("INSERT INTO live_sources(id,name,source_kind,raw_data,updated_at) VALUES (?,?,?,?,?)",
            bindings: [.text(s.id.uuidString), .text(s.name), .text(s.sourceKind.rawValue), .blob(s.rawData), .double(0)]) }
        XCTAssertEqual(try run(f).allocated, 1)
        XCTAssertEqual(try f.store.read().claims.count, 1)
    }
    func testDeletedReaddedSourceDoesNotInheritUUIDOrHidden() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        try f.sql { try $0.execute("UPDATE live_sources SET id=?", bindings: [.text(AdmissionFixture.b.uuidString)]) }
        // Orphan ownership requires explicit lifecycle policy, not automatic repair.
        XCTAssertThrowsError(try run(f)); XCTAssertEqual(try f.store.read().claims.count, 1)
    }
    func testPrivateDirectoryAndDatabasePermissions() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: f.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: f.url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testBorrowedTransactionHoldsWriteLockForFingerprintAndWrites() throws {
        let f = try fixture(); defer { f.store.close() }; let s = ImportedMigrationExecutionSession()
        let plan = try s.prepare(f.store.read()); var attempted = false
        _ = try s.execute(plan, store: f.store, checkpoint: { step in
            if step == 1 && !attempted {
                attempted = true
                try f.sql { c in XCTAssertThrowsError(try c.execute("UPDATE live_sources SET name='racing writer'")) }
            }
        })
        XCTAssertTrue(attempted)
    }
    func testNewLegacyAliasCannotRehideAlreadyClaimedFalseState() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        let session = ImportedMigrationExecutionSession(), channel = try f.channels()[0]
        try session.write(session.prepare(f.store.read()), store: f.store, sourceID: f.source, channel: channel, kind: .hidden, present: false)
        let oldID = try f.store.read().registry[0].identity
        try f.sourceData("#EXTM3U\n" + line("ONE"))
        let alias = ImportedChannelMigrationPlanner.hiddenKey(sourceID: f.source, channelID: "G::ONE")
        try f.sql { try $0.execute("UPDATE settings SET value=? WHERE key='live.deletedChannels'",
            bindings: [.blob(try JSONEncoder().encode([AdmissionFixture.hidden, alias]))]) }
        let result = try run(f)
        XCTAssertEqual(result.allocated, 0); XCTAssertEqual(result.claimed, 1)
        XCTAssertEqual(try f.store.read().registry[0].identity, oldID)
        XCTAssertEqual(try f.store.read().claims.count, 2); XCTAssertTrue(try f.store.read().stable.isEmpty)
    }
    func testRemovingRecordedHoldIsCorruptionNotNewInheritancePermission() throws {
        let f = try fixture(raw: "#EXTM3U\n" + line("One", suffix: "a") + line("One", suffix: "b")); defer { f.store.close() }
        _ = try run(f)
        try f.sql { try $0.execute("DELETE FROM imported_reference_holds") }
        XCTAssertThrowsError(try f.store.read())
    }
    func testClaimDisagreementWithoutMarkerStillBlocksAgainstReconciliation() throws {
        let f = try fixture(); defer { f.store.close() }; _ = try run(f)
        try f.store.transaction { try $0.insertIdentity(AdmissionFixture.record(name: "Other")) }
        try f.sql { c in
            try c.execute("DELETE FROM imported_migration_batches")
            try c.execute("DROP TRIGGER imported_claim_immutable")
            try c.execute("UPDATE imported_reference_claims SET local_id=?", bindings: [.text(AdmissionFixture.local.uuidString.lowercased())])
            try c.execute("DELETE FROM imported_stable_references")
        }
        XCTAssertThrowsError(try run(f))
    }
}
