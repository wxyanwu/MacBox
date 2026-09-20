import Foundation
import XCTest
import OKVideoCore
@testable import OKVideoPersistence
@testable import OKVideoMigrationDiagnostics

/// SYNTHETIC fixture only. This is an atomicity rehearsal, not a production
/// executor/schema. No UUID allocation: the sole destination is a fixed fixture ID.
private final class AdmissionTransactionFixture {
    let db: SQLiteConnection
    let url: URL
    let session = ImportedAdmissionSession()
    enum Failure: Error { case injected, invalidFixture, alreadyChanged }
    init(directory: URL) throws {
        url = directory.appendingPathComponent("transaction.sqlite3")
        do { _ = try SQLiteStore(databaseURL: url) }
        db = try SQLiteConnection(url: url)
        try db.execute("CREATE TABLE fixture_claims(source TEXT, kind TEXT, legacy TEXT, value BLOB, PRIMARY KEY(source,kind,legacy))")
        try db.execute("CREATE TABLE fixture_stable(source TEXT, local TEXT, kind TEXT, value BLOB, PRIMARY KEY(source,local,kind))")
        try db.execute("CREATE TABLE fixture_markers(plan TEXT PRIMARY KEY, receipt TEXT)")
        let s = AdmissionFixture.source()
        try db.execute("INSERT INTO live_sources(id,name,source_kind,raw_data,updated_at) VALUES (?,?,?,?,?)",
            bindings: [.text(s.id.uuidString), .text(s.name), .text(s.sourceKind.rawValue), .blob(s.rawData), .double(0)])
        for (key, refs) in [("live.favoriteChannels", [String]()), ("live.deletedChannels", [AdmissionFixture.hidden])] {
            try db.execute("INSERT INTO settings(key,value) VALUES (?,?)", bindings: [.text(key), .blob(try JSONEncoder().encode(refs))])
        }
    }
    deinit { db.close() }
    func input() throws -> ImportedAdmissionInput {
        var sources: [StoredLiveSource] = []
        try db.query("SELECT id,name,source_kind,source_value,base_url,raw_data,updated_at FROM live_sources") { row in
            guard let rawID = db.text(row, 0), let id = UUID(uuidString: rawID), let name = db.text(row, 1),
                  let rawKind = db.text(row, 2), let kind = StoredLiveSourceKind(rawValue: rawKind), let raw = db.data(row, 5) else { throw Failure.invalidFixture }
            sources.append(StoredLiveSource(id: id, name: name, sourceKind: kind, sourceValue: db.text(row, 3),
                baseURL: db.text(row, 4).flatMap(URL.init(string:)), rawData: raw, updatedAt: Date(timeIntervalSince1970: 0)))
        }
        func references(_ key: String) throws -> [ImportedLegacyReference] {
            var refs: [ImportedLegacyReference] = []
            try db.query("SELECT value FROM settings WHERE key=?", bindings: [.text(key)]) { row in
                guard let data = db.data(row, 0) else { throw Failure.invalidFixture }
                refs = try JSONDecoder().decode([String].self, from: data).map(ImportedLegacyReference.init)
            }
            return refs
        }
        var claims: [ImportedReferenceClaim] = [], stable: [ImportedStableReferenceState] = [], markers: [String] = []
        try db.query("SELECT value FROM fixture_claims") { claims.append(try JSONDecoder().decode(ImportedReferenceClaim.self, from: db.data($0, 0)!)) }
        try db.query("SELECT value FROM fixture_stable") { stable.append(try JSONDecoder().decode(ImportedStableReferenceState.self, from: db.data($0, 0)!)) }
        try db.query("SELECT plan FROM fixture_markers") { markers.append(db.text($0, 0)!) }
        let registry = try ImportedIdentityRegistrySQL.list(.imported(AdmissionFixture.a), lifecycle: nil, connection: db)
        return try ImportedAdmissionInput(sources: sources, registry: registry,
            favorites: references("live.favoriteChannels"), hidden: references("live.deletedChannels"),
            claims: claims, stable: stable, markers: markers, schemaVersion: db.scalarInt("PRAGMA user_version"))
    }
    @discardableResult
    func execute(_ plan: ImportedAdmissionPlan, failAfter: Int? = nil, afterBegin: (() throws -> Void)? = nil) throws -> Bool {
        try db.transaction {
            try afterBegin?()
            // SAME connection + SAME transaction for fingerprint reads and writes.
            let current = try input()
            var receipt: String?
            try db.query("SELECT receipt FROM fixture_markers WHERE plan=?", bindings: [.text(plan.planFingerprint)]) { receipt = db.text($0, 0) }
            if let receipt {
                guard receipt == (try session.prepare(current).planFingerprint) else { throw Failure.alreadyChanged }
                return false // Verified same-session retry; no UUID/write/re-hide.
            }
            try session.validate(plan, current: current)
            guard plan.rows.count == 1, plan.rows[0].admission == .eligible,
                  plan.fullPlan.references.count == 1,
                  plan.fullPlan.references[0].classification == .safeLegacyMigrationCandidate else { throw Failure.invalidFixture }
            func fail(_ step: Int) throws { if failAfter == step { throw Failure.injected } }
            let record = try AdmissionFixture.record()
            try ImportedIdentityRegistrySQL.apply(.upsert(record), connection: db)
            try fail(1)
            let claim = try AdmissionFixture.claim()
            try db.execute("INSERT INTO fixture_claims VALUES (?,?,?,?)", bindings: [.text(AdmissionFixture.a.uuidString),
                .text("hidden"), .text(AdmissionFixture.hidden), .blob(try JSONEncoder().encode(claim))])
            try fail(2)
            let state = ImportedStableReferenceState(identity: record.identity, kind: .hidden)
            try db.execute("INSERT INTO fixture_stable VALUES (?,?,?,?)", bindings: [.text(AdmissionFixture.a.uuidString),
                .text(record.identity.localID.uuidString), .text("hidden"), .blob(try JSONEncoder().encode(state))])
            try fail(3)
            try db.execute("INSERT INTO fixture_markers(plan) VALUES (?)", bindings: [.text(plan.planFingerprint)])
            // Receipt binds the post-state including claim + marker key. The
            // receipt itself is excluded to avoid a recursive fingerprint.
            let post = try session.prepare(input()).planFingerprint
            try db.execute("UPDATE fixture_markers SET receipt=? WHERE plan=?", bindings: [.text(post), .text(plan.planFingerprint)])
            try fail(4)
            return true
        }
    }
    func counts() throws -> [Int] {
        try ["imported_channel_identities", "fixture_claims", "fixture_stable", "fixture_markers"].map {
            try db.scalarInt("SELECT count(*) FROM \($0)")
        }
    }
}

final class AdmissionTransactionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("8B2b-Synthetic-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testRegistryClaimStateMarkerAtomicSuccess() throws {
        let f = try AdmissionTransactionFixture(directory: directory()); let input = try f.input()
        XCTAssertTrue(try f.execute(f.session.prepare(input)))
        XCTAssertEqual(try f.counts(), [1, 1, 1, 1])
        XCTAssertEqual(try f.input().hidden, input.hidden); XCTAssertEqual(try f.input().favorites, input.favorites)
        XCTAssertEqual(try f.input().sources, input.sources)
    }
    func testFailureAfterEachMutationRollsBackAllAndRetryWorks() throws {
        for step in 1...4 {
            let f = try AdmissionTransactionFixture(directory: directory()); let before = try f.input()
            let p = try f.session.prepare(before)
            XCTAssertThrowsError(try f.execute(p, failAfter: step))
            XCTAssertEqual(try f.counts(), [0, 0, 0, 0])
            XCTAssertNoThrow(try f.session.validate(p, current: f.input()))
            XCTAssertTrue(try f.execute(p)); XCTAssertEqual(try f.counts(), [1, 1, 1, 1])
        }
    }
    func testSQLiteTriggerFailureRollsBackRegistryAndClaim() throws {
        let f = try AdmissionTransactionFixture(directory: directory()); let p = try f.session.prepare(f.input())
        try f.db.execute("CREATE TRIGGER fixture_failure BEFORE INSERT ON fixture_stable BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        XCTAssertThrowsError(try f.execute(p)); XCTAssertEqual(try f.counts(), [0, 0, 0, 0])
        try f.db.execute("DROP TRIGGER fixture_failure")
        XCTAssertTrue(try f.execute(p))
    }
    func testRepeatedOperationUsesReceiptWithoutSecondIdentity() throws {
        let f = try AdmissionTransactionFixture(directory: directory()); let p = try f.session.prepare(f.input())
        XCTAssertTrue(try f.execute(p)); XCTAssertFalse(try f.execute(p))
        XCTAssertEqual(try f.counts(), [1, 1, 1, 1])
    }
    func testUnhideSurvivesRetryAndLegacyRemainsNonAuthoritative() throws {
        let f = try AdmissionTransactionFixture(directory: directory()); let p = try f.session.prepare(f.input())
        try f.execute(p); try f.db.execute("DELETE FROM fixture_stable")
        XCTAssertThrowsError(try f.execute(p)); XCTAssertEqual(try f.counts(), [1, 1, 0, 1])
        let current = try f.input()
        XCTAssertEqual(try ImportedClaimedAuthority.resolve(sourceID: AdmissionFixture.a, kind: .hidden,
            legacyToken: AdmissionFixture.hidden, legacyContains: true, claims: current.claims, stable: current.stable), .stable(false))
    }
    func testChangedCatalogBeforeTransactionRejectsOldPlan() throws {
        let f = try AdmissionTransactionFixture(directory: directory()); let p = try f.session.prepare(f.input())
        try f.db.execute("UPDATE live_sources SET name='changed'")
        XCTAssertThrowsError(try f.execute(p)); XCTAssertEqual(try f.counts(), [0, 0, 0, 0])
    }
    func testRecheckIsInsideTransactionNotCachedBeforeBegin() throws {
        let f = try AdmissionTransactionFixture(directory: directory()); let p = try f.session.prepare(f.input())
        XCTAssertThrowsError(try f.execute(p, afterBegin: {
            try f.db.execute("UPDATE settings SET value=? WHERE key='live.deletedChannels'", bindings: [.blob(Data("[]".utf8))])
        }))
        XCTAssertEqual(try f.counts(), [0, 0, 0, 0]); XCTAssertNoThrow(try f.session.validate(p, current: f.input()))
    }
    func testBeginImmediatePreventsCompetingWriterBetweenCheckAndCommit() throws {
        let f = try AdmissionTransactionFixture(directory: directory()); let p = try f.session.prepare(f.input())
        let other = try SQLiteConnection(url: f.url); defer { other.close() }
        try f.execute(p, afterBegin: {
            XCTAssertThrowsError(try other.execute("UPDATE live_sources SET name='race'"))
        })
        XCTAssertEqual(try f.counts(), [1, 1, 1, 1])
    }
    func testPersistedClaimAndFalseValueSurviveConnectionReopen() throws {
        let d = try directory(); let url = d.appendingPathComponent("transaction.sqlite3")
        do {
            let f = try AdmissionTransactionFixture(directory: d); try f.execute(f.session.prepare(f.input()))
            try f.db.execute("DELETE FROM fixture_stable")
        }
        let reopened = try SQLiteConnection(url: url); defer { reopened.close() }
        XCTAssertEqual(try reopened.scalarInt("SELECT count(*) FROM fixture_claims"), 1)
        XCTAssertEqual(try reopened.scalarInt("SELECT count(*) FROM fixture_stable"), 0)
        XCTAssertEqual(try reopened.scalarInt("SELECT count(*) FROM imported_channel_identities"), 1)
    }
    func testDisasterRestoreIsSeparateAndLosesPostBackupFixtureChanges() throws {
        let root = try directory(); let dbDir = root.appendingPathComponent("Database")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: false)
        let original = dbDir.appendingPathComponent("fixture.sqlite3")
        do { _ = try SQLiteStore(databaseURL: original) }
        do {
            let c = try SQLiteConnection(url: original); defer { c.close() }
            try c.execute("DROP TABLE imported_channel_identities"); try c.execute("PRAGMA user_version=9")
            try c.execute("INSERT INTO settings(key,value) VALUES ('backupValue',?)", bindings: [.blob(Data("\"before\"".utf8))])
        }
        let lock = root.appendingPathComponent(".instance.lock")
        try QuiescentDatabaseSnapshot.writePrivate(Data(), to: lock)
        let backup = try QuiescentDatabaseSnapshot.create(database: original, existingAppLock: lock)
        addTeardownBlock { try backup.removeTemporaryFiles() }
        let backupBytes = try Data(contentsOf: backup.database)
        XCTAssertEqual(backup.schemaVersion, 9)
        // Upgrade/mutate ONLY the disposable synthetic original, then stop all writers.
        do { _ = try SQLiteStore(databaseURL: original) }
        do {
            let c = try SQLiteConnection(url: original); defer { c.close() }
            try c.execute("INSERT INTO settings(key,value) VALUES ('postBackupChange',?)", bindings: [.blob(Data("true".utf8))])
            XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 10)
        }
        // Restore into a NEW temporary destination, never overwrite a user's DB.
        let restored = root.appendingPathComponent("restored-schema9.sqlite3")
        try QuiescentDatabaseSnapshot.writePrivate(backupBytes, to: restored)
        let c = try SQLiteConnection(url: restored); defer { c.close() }
        XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 9)
        XCTAssertEqual(try c.scalarInt("SELECT count(*) FROM settings WHERE key='backupValue'"), 1)
        XCTAssertEqual(try c.scalarInt("SELECT count(*) FROM settings WHERE key='postBackupChange'"), 0)
        XCTAssertEqual(try Data(contentsOf: backup.database), backupBytes)
    }
}
