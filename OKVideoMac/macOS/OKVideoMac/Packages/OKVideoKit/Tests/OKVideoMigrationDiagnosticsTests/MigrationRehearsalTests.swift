import Foundation
import XCTest
import OKVideoCore
@testable import OKVideoPersistence
@testable import OKVideoMigrationDiagnostics

final class MigrationRehearsalTests: XCTestCase {
    private func fixture() throws -> (URL, URL, SQLiteConnection) {
        let old = URL(fileURLWithPath: "/private/tmp/OKVideoMac-8B2-DryRun-RehearsalTest-\(UUID())")
        let target = URL(fileURLWithPath: "/private/tmp/OKVideoMac-8B3A-RehearsalTest-\(UUID())")
        for directory in [old, target] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        }
        let db = old.appendingPathComponent("snapshot.sqlite3")
        do { _ = try SQLiteStore(databaseURL: db) }
        let c = try SQLiteConnection(url: db)
        try c.execute("DROP TABLE imported_channel_identities"); try c.execute("PRAGMA user_version=9")
        try c.query("PRAGMA journal_mode=WAL") { _ in }; try c.query("PRAGMA wal_autocheckpoint=0") { _ in }
        let s = AdmissionFixture.source()
        try c.execute("INSERT INTO live_sources(id,name,source_kind,raw_data,updated_at) VALUES (?,?,?,?,?)",
            bindings: [.text(s.id.uuidString), .text(s.name), .text(s.sourceKind.rawValue), .blob(s.rawData), .double(0)])
        try c.execute("INSERT INTO settings(key,value) VALUES ('live.deletedChannels',?)", bindings: [.blob(try JSONEncoder().encode([AdmissionFixture.hidden]))])
        return (db, target, c)
    }
    func testOnlineBackupCapturesWALAndLeavesSourceMainAndWALUnchanged() throws {
        let (source, target, connection) = try fixture(); defer { connection.close() }
        let before = try QuiescentDatabaseSnapshot.audit(database: source)
        XCTAssertGreaterThan(before["wal"]?.bytes ?? 0, 0)
        try ImportedMigrationRehearsal.copy(snapshot: source, into: target)
        let after = try QuiescentDatabaseSnapshot.audit(database: source)
        XCTAssertEqual(before["main"], after["main"]); XCTAssertEqual(before["wal"], after["wal"])
        try ImportedMigrationRehearsal.cycle(in: target, label: "first")
        let result = try report(target, "first")
        XCTAssertEqual(result["schemaBefore"] as? Int, 9)
        XCTAssertEqual((result["registryIdentities"] as? [Any])?.count, 1)
        XCTAssertEqual(result["businessContentUnchanged"] as? Bool, true)
        XCTAssertEqual(try connection.scalarInt("PRAGMA user_version"), 9)
    }
    private func report(_ target: URL, _ label: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: target.appendingPathComponent("\(label)-result.json"))) as! [String: Any]
    }
    func testHarnessRepeatedCycleAndUnhideKeepUUIDAndClaim() throws {
        let (source, target, connection) = try fixture(); defer { connection.close() }
        try ImportedMigrationRehearsal.copy(snapshot: source, into: target)
        try ImportedMigrationRehearsal.cycle(in: target, label: "first")
        try ImportedMigrationRehearsal.cycle(in: target, label: "second")
        try ImportedMigrationRehearsal.cycle(in: target, label: "unhide", unhide: true)
        try ImportedMigrationRehearsal.cycle(in: target, label: "afterRestart")
        let first = try report(target, "first"), second = try report(target, "second"), last = try report(target, "afterRestart")
        XCTAssertEqual(second["schemaBefore"] as? Int, 11)
        XCTAssertEqual((second["execution"] as? [String: Any])?["allocated"] as? Int, 0)
        XCTAssertEqual((last["execution"] as? [String: Any])?["claimed"] as? Int, 0)
        XCTAssertEqual(first["registryIdentities"] as? NSArray, last["registryIdentities"] as? NSArray)
        XCTAssertEqual((last["claims"] as? [[String: Any]])?[0]["present"] as? Bool, false)
        let text = String(decoding: try Data(contentsOf: target.appendingPathComponent("afterRestart-result.json")), as: UTF8.self)
        XCTAssertFalse(text.contains("fixture.invalid")); XCTAssertFalse(text.contains(AdmissionFixture.hidden))
    }
    func testBackupDoesNotOverwritePriorCopies() throws {
        let (source, target, connection) = try fixture(); defer { connection.close() }
        try ImportedMigrationRehearsal.copy(snapshot: source, into: target)
        let before = try Data(contentsOf: target.appendingPathComponent("work.sqlite3"))
        XCTAssertThrowsError(try ImportedMigrationRehearsal.copy(snapshot: source, into: target))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("work.sqlite3")), before)
    }
    func testRehearsalRejectsUserDatabaseSource() throws {
        let (_, target, connection) = try fixture(); defer { connection.close() }
        XCTAssertThrowsError(try ImportedMigrationRehearsal.copy(snapshot: URL(fileURLWithPath: "/Users/fixture/Library/Database/snapshot.sqlite3"), into: target))
    }
    func testReportLabelsCannotEscapeOutputDirectory() throws {
        let (_, target, connection) = try fixture(); defer { connection.close() }
        XCTAssertThrowsError(try ImportedMigrationRehearsal.cycle(in: target, label: "../escape"))
    }
    func testDisasterRestoreOfSchema9BackupLosesPostBackupClaimAndUnhide() throws {
        let (source, target, connection) = try fixture(); defer { connection.close() }
        try ImportedMigrationRehearsal.copy(snapshot: source, into: target)
        try ImportedMigrationRehearsal.cycle(in: target, label: "migrate")
        try ImportedMigrationRehearsal.cycle(in: target, label: "unhide", unhide: true)
        let restore = URL(fileURLWithPath: "/private/tmp/OKVideoMac-8B3A-RestoreTest-\(UUID())")
        try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: restore) }
        // Restore the unchanged schema-9 backup into a NEW destination, never
        // overwrite an active work copy. This is not transaction rollback.
        try ImportedMigrationRehearsal.copy(snapshot: source, into: restore)
        let c = try SQLiteConnection(url: restore.appendingPathComponent("work.sqlite3")); defer { c.close() }
        XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 9)
        XCTAssertEqual(try c.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='imported_reference_claims'"), 0)
        var hidden: [String] = []
        try c.query("SELECT value FROM settings WHERE key='live.deletedChannels'") { hidden = try JSONDecoder().decode([String].self, from: c.data($0, 0)!) }
        // The old legacy Hidden is back: unhide AFTER backup is intentionally
        // lost by disaster restoration. Never claim lossless App downgrade.
        XCTAssertEqual(hidden, [AdmissionFixture.hidden])
        XCTAssertEqual(try ImportedMigrationRehearsal.businessContent(restore.appendingPathComponent("work.sqlite3")),
            try ImportedMigrationRehearsal.businessContent(target.appendingPathComponent("baseline.sqlite3")))
    }
    func testBusinessProjectionRejectsExternalSymlinkAndHardlinkBeforeOpen() throws {
        let (source, target, connection) = try fixture(); defer { connection.close() }
        let symlink = target.appendingPathComponent("work.sqlite3")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: URL(fileURLWithPath: "/Users/fixture/Library/Database/work.sqlite3"))
        XCTAssertThrowsError(try ImportedMigrationRehearsal.businessContent(symlink))
        let hardlink = target.appendingPathComponent("baseline.sqlite3")
        try FileManager.default.linkItem(at: source, to: hardlink)
        XCTAssertThrowsError(try ImportedMigrationRehearsal.businessContent(hardlink))
    }
}
