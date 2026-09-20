import Foundation
import Darwin
import XCTest
import OKVideoCore
@testable import OKVideoPersistence
@testable import OKVideoMigrationDiagnostics

final class DatabaseSnapshotTests: XCTestCase {
    private func fixture() throws -> (db: URL, lock: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("8B2Fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseDirectory = directory.appendingPathComponent("Database")
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: false)
        let db = databaseDirectory.appendingPathComponent("original.sqlite3")
        do { _ = try SQLiteStore(databaseURL: db) }
        let connection = try SQLiteConnection(url: db)
        try connection.execute("DROP TABLE imported_channel_identities")
        try connection.execute("PRAGMA user_version=9")
        connection.close()
        let lock = directory.appendingPathComponent(".instance.lock")
        try QuiescentDatabaseSnapshot.writePrivate(Data(), to: lock)
        return (db, lock)
    }
    private func snapshot(_ fixture: (db: URL, lock: URL)) throws -> DryRunDatabaseSnapshot {
        let snapshot = try QuiescentDatabaseSnapshot.create(database: fixture.db, existingAppLock: fixture.lock)
        addTeardownBlock { try snapshot.removeTemporaryFiles() }
        return snapshot
    }
    func testSnapshotDoesNotWriteOriginalMainWALSHM() throws {
        let f = try fixture(); let before = try QuiescentDatabaseSnapshot.audit(database: f.db)
        _ = try snapshot(f)
        XCTAssertEqual(before, try QuiescentDatabaseSnapshot.audit(database: f.db))
    }
    func testTemporarySnapshotMigratesIndependently() async throws {
        let f = try fixture(); let s = try snapshot(f)
        XCTAssertEqual(s.schemaVersion, 9)
        _ = try await ImportedMigrationDryRun.run(snapshot: s)
        XCTAssertEqual(try QuiescentDatabaseSnapshot.inspectTemporary(database: s.database).schema, 10)
        XCTAssertEqual(s.sourceFiles, try QuiescentDatabaseSnapshot.audit(database: f.db))
    }
    func testWALCommittedSettingsEnterConsistentSnapshot() throws {
        let f = try fixture(); let writer = try SQLiteConnection(url: f.db)
        defer { writer.close() }
        try writer.query("PRAGMA journal_mode=WAL") { _ in }
        try writer.query("PRAGMA wal_autocheckpoint=0") { _ in }
        try writer.execute("INSERT INTO settings(key,value) VALUES (?,?)", bindings: [.text("WAL_ONLY"), .blob(Data("[1]".utf8))])
        let before = try QuiescentDatabaseSnapshot.audit(database: f.db)
        XCTAssertGreaterThan(before["wal"]?.bytes ?? 0, 0)
        let s = try snapshot(f)
        let copy = try SQLiteConnection(url: s.database)
        XCTAssertEqual(try copy.scalarInt("SELECT count(*) FROM settings WHERE key='WAL_ONLY'"), 1)
        copy.close()
        XCTAssertEqual(before, try QuiescentDatabaseSnapshot.audit(database: f.db))
    }
    func testSchemaVersionInWALIsNotTakenFromOldMainHeader() throws {
        let f = try fixture(); let writer = try SQLiteConnection(url: f.db)
        defer { writer.close() }
        try writer.query("PRAGMA journal_mode=WAL") { _ in }
        try writer.query("PRAGMA wal_autocheckpoint=0") { _ in }
        try writer.execute("PRAGMA user_version=8")
        XCTAssertEqual(try snapshot(f).schemaVersion, 8)
    }
    func testOriginalSchemaNotMigrated() async throws {
        let f = try fixture(); let s = try snapshot(f)
        _ = try await ImportedMigrationDryRun.run(snapshot: s)
        // Read-only byte equality proves original schema/content unchanged without
        // another SQLite connection to the source.
        XCTAssertEqual(s.sourceFiles, try QuiescentDatabaseSnapshot.audit(database: f.db))
        XCTAssertEqual(try snapshot(f).schemaVersion, 9)
    }
    func testActiveInstanceLeaseFailsClosed() throws {
        let f = try fixture(); let fd = Darwin.open(f.lock.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { flock(fd, LOCK_UN) }
        let before = try QuiescentDatabaseSnapshot.audit(database: f.db)
        XCTAssertThrowsError(try snapshot(f))
        XCTAssertEqual(before, try QuiescentDatabaseSnapshot.audit(database: f.db))
    }
    func testMissingLockIsNotCreated() throws {
        let f = try fixture(); let missing = f.lock.deletingLastPathComponent().appendingPathComponent("missing.lock")
        XCTAssertThrowsError(try snapshot((f.db, missing)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
    func testSymlinkDatabaseRejected() throws {
        let f = try fixture(); let link = f.db.deletingLastPathComponent().appendingPathComponent("link.sqlite3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.db)
        XCTAssertThrowsError(try snapshot((link, f.lock)))
    }
    func testSymlinkLockRejected() throws {
        let f = try fixture(); let link = f.lock.deletingLastPathComponent().appendingPathComponent("link.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.lock)
        XCTAssertThrowsError(try snapshot((f.db, link)))
    }
    func testSnapshotAndReportsPrivatePermissions() async throws {
        let f = try fixture(); let s = try snapshot(f)
        let p = try await ImportedMigrationDryRun.run(snapshot: s)
        try ImportedMigrationDryRun.writeReports(plan: p, snapshot: s, realDatabase: f.db)
        func permissions(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
        XCTAssertEqual(try permissions(s.directory), 0o700)
        for name in ["snapshot.sqlite3", "DatabaseSafety.json", "ImportedIdentityMigrationDryRun.json", "ImportedIdentityMigrationDryRun.md"] {
            XCTAssertEqual(try permissions(s.directory.appendingPathComponent(name)), 0o600)
        }
    }
    func testReportsDoNotOverwriteExistingFiles() throws {
        let f = try fixture(); let file = f.db.deletingLastPathComponent().appendingPathComponent("report")
        try QuiescentDatabaseSnapshot.writePrivate(Data("first".utf8), to: file)
        XCTAssertThrowsError(try QuiescentDatabaseSnapshot.writePrivate(Data("second".utf8), to: file))
        XCTAssertEqual(try Data(contentsOf: file), Data("first".utf8))
    }
    func testHarnessLeavesRealReferencesAndRegistryUntouched() async throws {
        let f = try fixture()
        do {
            let c = try SQLiteConnection(url: f.db)
            try c.execute("INSERT INTO settings(key,value) VALUES (?,?)", bindings: [.text("live.favoriteChannels"), .blob(Data("[\"source::group::name\"]".utf8))])
            try c.execute("INSERT INTO settings(key,value) VALUES (?,?)", bindings: [.text("live.deletedChannels"), .blob(Data("[\"opaqueHidden\"]".utf8))])
            c.close()
        }
        let s = try snapshot(f)
        let p = try await ImportedMigrationDryRun.run(snapshot: s)
        XCTAssertEqual(p.references.count, 2)
        XCTAssertTrue(p.references.allSatisfy { $0.action.hasPrefix("preserve") })
        let after = try QuiescentDatabaseSnapshot.inspectTemporary(database: s.database)
        XCTAssertEqual(after.counts["imported_channel_identities"], 0)
        XCTAssertEqual(after.counts["settings"], s.tableCounts["settings"])
        XCTAssertEqual(s.sourceFiles, try QuiescentDatabaseSnapshot.audit(database: f.db))
    }
    func testProductionParserUnchangedForMergedFixture() async throws {
        let f = try fixture()
        let payload = Data("#EXTM3U\n#EXTINF:-1 tvg-id=\"1\" group-title=\"G\",CCTV-1\nhttps://fixture.invalid/one\n#EXTINF:-1 tvg-id=\"2\" group-title=\"G\",CCTV-1\nhttps://fixture.invalid/two\n".utf8)
        let before = try LiveSourceParser().parse(payload)
        XCTAssertEqual(before.groups[0].channels.count, 1)
        do {
            let c = try SQLiteConnection(url: f.db)
            try c.execute("INSERT INTO live_sources(id,name,source_kind,raw_data,updated_at) VALUES (?,?,?,?,?)",
                bindings: [.text(UUID().uuidString), .text("Fixture"), .text("pasted"), .blob(payload), .double(0)])
            c.close()
        }
        let s = try snapshot(f); let p = try await ImportedMigrationDryRun.run(snapshot: s)
        XCTAssertEqual(p.channels.count, 1); XCTAssertEqual(p.sources[0].rawRecords, 2)
        XCTAssertEqual(p.channels[0].classification, .futureSplitRisk)
        XCTAssertEqual(try LiveSourceParser().parse(payload), before)
        XCTAssertEqual(s.sourceFiles, try QuiescentDatabaseSnapshot.audit(database: f.db))
    }
}
