import Foundation
import XCTest
import OKVideoCore
@testable import OKVideoPersistence
@testable import OKVideoMigrationDiagnostics

final class AdmissionSnapshotTests: XCTestCase {
    private func fixture(schema: Int = 10) throws -> (URL, SQLiteConnection) {
        let directory = URL(fileURLWithPath: "/private/tmp/OKVideoMac-8B2-DryRun-Synthetic-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.sqlite3")
        do { _ = try SQLiteStore(databaseURL: url) }
        let c = try SQLiteConnection(url: url)
        if schema == 9 { try c.execute("DROP TABLE imported_channel_identities"); try c.execute("PRAGMA user_version=9") }
        let s = AdmissionFixture.source()
        try c.execute("INSERT INTO live_sources(id,name,source_kind,raw_data,updated_at) VALUES (?,?,?,?,?)",
            bindings: [.text(s.id.uuidString), .text(s.name), .text(s.sourceKind.rawValue), .blob(s.rawData), .double(0)])
        try c.execute("INSERT INTO settings(key,value) VALUES ('live.deletedChannels',?)", bindings: [.blob(try JSONEncoder().encode([AdmissionFixture.hidden]))])
        return (url, c)
    }
    func testSchema9ReadDoesNotInitializeOrMigrateStore() throws {
        let (url, c) = try fixture(schema: 9); defer { c.close() }
        let input = try ImportedAdmissionSnapshot.read(temporaryDatabase: url)
        XCTAssertEqual(input.schemaVersion, 9); XCTAssertEqual(input.sources.count, 1)
        XCTAssertEqual(input.hidden.map(\.rawValue), [AdmissionFixture.hidden])
        XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 9)
        XCTAssertEqual(try c.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='imported_channel_identities'"), 0)
    }
    func testWALSourceDataReadWithoutDatabaseMutation() throws {
        let (url, c) = try fixture(); defer { c.close() }
        try c.query("PRAGMA journal_mode=WAL") { _ in }
        try c.query("PRAGMA wal_autocheckpoint=0") { _ in }
        try c.execute("UPDATE live_sources SET name='CommittedInWAL'")
        let before = try QuiescentDatabaseSnapshot.audit(database: url)
        let input = try ImportedAdmissionSnapshot.read(temporaryDatabase: url)
        XCTAssertEqual(input.sources[0].name, "CommittedInWAL")
        let after = try QuiescentDatabaseSnapshot.audit(database: url)
        XCTAssertEqual(before["main"], after["main"]); XCTAssertEqual(before["wal"], after["wal"])
        XCTAssertEqual(try c.scalarInt("SELECT count(*) FROM imported_channel_identities"), 0)
    }
    func testRegistryProjectionIncludesForeignSourceAndAllMetadata() throws {
        let (url, c) = try fixture(); defer { c.close() }
        let record = try AdmissionFixture.record(source: AdmissionFixture.b, lifecycle: .missing)
        try ImportedIdentityRegistrySQL.apply(.upsert(record), connection: c)
        let input = try ImportedAdmissionSnapshot.read(temporaryDatabase: url)
        XCTAssertEqual(input.registry, [record])
        XCTAssertEqual(try ImportedAdmissionSession().prepare(input).rows[0].admission, .blocked)
    }
    func testRegistryUnknownFieldsFailClosed() throws {
        let (url, c) = try fixture(); defer { c.close() }
        try ImportedIdentityRegistrySQL.apply(.upsert(AdmissionFixture.record()), connection: c)
        try c.execute("UPDATE imported_channel_identities SET evidence=?", bindings: [.blob(Data("{\"group\":\"G\",\"name\":\"One\",\"future\":true}".utf8))])
        XCTAssertThrowsError(try ImportedAdmissionSnapshot.read(temporaryDatabase: url))
    }
    func testUnknownAuthorityTableNotProjectedAsEmpty() throws {
        let (url, c) = try fixture(); defer { c.close() }
        try c.execute("CREATE TABLE future_authority(value TEXT)")
        XCTAssertThrowsError(try ImportedAdmissionSnapshot.read(temporaryDatabase: url))
    }
    func testUnsupportedSchemaFailsClosed() throws {
        let (url, c) = try fixture(); defer { c.close() }
        try c.execute("PRAGMA user_version=11")
        XCTAssertThrowsError(try ImportedAdmissionSnapshot.read(temporaryDatabase: url))
        XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 11)
    }
    func testSchema9WithUnexpectedRegistryCannotPretendRegistryEmpty() throws {
        let (url, c) = try fixture(); defer { c.close() }
        try c.execute("PRAGMA user_version=9")
        XCTAssertThrowsError(try ImportedAdmissionSnapshot.read(temporaryDatabase: url))
    }
    func testInvalidLegacyShapeFailsClosed() throws {
        let (url, c) = try fixture(); defer { c.close() }
        try c.execute("UPDATE settings SET value=?", bindings: [.blob(Data("{\"not\":\"array\"}".utf8))])
        XCTAssertThrowsError(try ImportedAdmissionSnapshot.read(temporaryDatabase: url))
    }
    func testUserLibraryPathRejectedBeforeSQLiteOpen() throws {
        XCTAssertThrowsError(try ImportedAdmissionSnapshot.read(temporaryDatabase: URL(fileURLWithPath: "/Users/fixture/Library/Application Support/OKVideoMac/Database/OKVideoMac.sqlite3")))
    }
    func testSymlinkOutsideTemporarySnapshotRejected() throws {
        let (url, c) = try fixture(); defer { c.close() }
        let link = url.deletingLastPathComponent().appendingPathComponent("outside.sqlite3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Users/fixture/Library/Database/snapshot.sqlite3"))
        XCTAssertThrowsError(try ImportedAdmissionSnapshot.read(temporaryDatabase: link))
    }
    func testPlanCreationDoesNotWriteReferencesOrRegistry() throws {
        let (url, c) = try fixture(); defer { c.close() }
        let before = try ImportedAdmissionSnapshot.read(temporaryDatabase: url)
        let session = ImportedAdmissionSession(); let plan = try session.prepare(before)
        let after = try ImportedAdmissionSnapshot.read(temporaryDatabase: url)
        XCTAssertNoThrow(try session.validate(plan, current: after))
        XCTAssertEqual(before.sources, after.sources); XCTAssertEqual(before.registry, after.registry)
        XCTAssertEqual(before.favorites, after.favorites); XCTAssertEqual(before.hidden, after.hidden)
        XCTAssertEqual(after.registry.count, 0)
    }
}
