import XCTest
import OKVideoCore
@testable import OKVideoPersistence

final class FavoriteMigrationTests: XCTestCase {
    private func path() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Favorites121-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("store.sqlite3")
    }
    private func oldDatabase() throws -> URL {
        let url = try path()
        do { _ = try SQLiteStore(databaseURL: url) }
        let c = try SQLiteConnection(url: url)
        try c.execute("DROP TABLE favorites")
        try c.execute("CREATE TABLE favorites(site_key TEXT NOT NULL, video_id TEXT NOT NULL, title TEXT NOT NULL, poster_url TEXT, synopsis TEXT, created_at REAL NOT NULL, PRIMARY KEY(site_key,video_id))")
        try c.execute("PRAGMA user_version=10")
        return url
    }
    func testLegacyMigrationKeepsEveryFieldStableIDAndVerifiedBackup() async throws {
        let url = try oldDatabase()
        let c = try SQLiteConnection(url: url)
        try c.query("PRAGMA journal_mode=WAL") { _ in }
        try c.execute("INSERT INTO favorites VALUES('site','id','原标题','https://example.org/poster','原简介',1234)")
        let store = try SQLiteStore(databaseURL: url)
        let values = try await store.favorites()
        let item = try XCTUnwrap(values.first)
        XCTAssertNil(item.configurationID); XCTAssertEqual(item.title, "原标题")
        XCTAssertEqual(item.synopsis, "原简介"); XCTAssertEqual(item.createdAt.timeIntervalSince1970, 1234)
        XCTAssertEqual(item.posterURL?.absoluteString, "https://example.org/poster")
        let reopened = try SQLiteStore(databaseURL: url)
        let again = try await reopened.favorites()
        XCTAssertEqual(again, values)
        let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent().appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let backup = try SQLiteConnection(url: backups[0])
        XCTAssertEqual(try backup.scalarInt("PRAGMA user_version"), 10)
        XCTAssertEqual(try backup.scalarInt("SELECT count(*) FROM favorites"), 1)
        XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 13)
    }
    func testNamespacesAndIdempotenceAndLegacyDeleteCannotCrossSources() async throws {
        let store = try SQLiteStore(databaseURL: path())
        let a = FavoriteRecord(siteKey: "same", videoID: "same", title: "A", configurationID: UUID(), sourceFingerprint: "one")
        var b = a; b.favoriteID = UUID(); b.configurationID = UUID(); b.title = "B"
        _ = try await store.setFavorite(a, isFavorite: true)
        _ = try await store.setFavorite(a, isFavorite: true)
        _ = try await store.setFavorite(b, isFavorite: true)
        try await store.deleteFavorite(siteKey: "same", videoID: "same")
        let initial = try await store.favorites()
        XCTAssertEqual(initial.count, 2)
        let result = try await store.setFavorite(a, isFavorite: false)
        XCTAssertEqual(result.map(\.id), [b.id])
    }
    func testBatchFailureRollsBackAllAndCanRetry() async throws {
        let url = try path(), store = try SQLiteStore(databaseURL: url)
        let a = FavoriteRecord(siteKey: "s", videoID: "a", title: "A")
        let b = FavoriteRecord(siteKey: "s", videoID: "b", title: "B")
        try await store.saveFavorite(a); try await store.saveFavorite(b)
        let c = try SQLiteConnection(url: url)
        try c.execute("CREATE TRIGGER fail_delete BEFORE DELETE ON favorites WHEN OLD.video_id='b' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        do { _ = try await store.deleteFavorites(ids: [a.id,b.id]); XCTFail("must fail") } catch {}
        let remaining = try await store.favorites(); XCTAssertEqual(remaining.count, 2)
        try c.execute("DROP TRIGGER fail_delete")
        let deleted = try await store.deleteFavorites(ids: [a.id,b.id]); XCTAssertTrue(deleted.isEmpty)
    }
    func testLateMetadataCannotResurrectAndBindingMergesWithoutChangingRowID() async throws {
        let store = try SQLiteStore(databaseURL: path())
        let legacy = FavoriteRecord(siteKey: "s", videoID: "a", title: "Old", createdAt: Date(timeIntervalSince1970: 1))
        var scoped = legacy; scoped.favoriteID = UUID(); scoped.configurationID = UUID(); scoped.createdAt = Date(timeIntervalSince1970: 2)
        try await store.saveFavorite(legacy); try await store.saveFavorite(scoped)
        let bound = try await store.bindFavorite(legacy, to: scoped)
        XCTAssertEqual(bound.count, 1); XCTAssertEqual(bound[0].id, legacy.id)
        XCTAssertEqual(bound[0].createdAt, legacy.createdAt)
        _ = try await store.deleteFavorites(ids: [legacy.id])
        let refreshed = try await store.refreshFavorite(bound[0], with: scoped)
        XCTAssertTrue(refreshed.isEmpty)
    }
    func testMigrationFailureLeavesLegacyDataAndDoesNotQuarantine() throws {
        let url = try oldDatabase(), c = try SQLiteConnection(url: url)
        try c.execute("INSERT INTO favorites VALUES('s','a','Original',NULL,NULL,1)")
        try c.execute("CREATE TABLE favorites_legacy(blocked TEXT)")
        XCTAssertThrowsError(try SQLiteStore.openRecovering(databaseURL: url))
        XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), 10)
        XCTAssertEqual(try c.scalarInt("SELECT count(*) FROM favorites"), 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertFalse(files.contains { $0.hasPrefix("Corrupt-") })
    }
    func testProductionRejectsIsolatedSchemasEvenWhenVersionIsRelabeled() throws {
        for version in [11, 12, 13] {
            let url = try path(); do { _ = try SQLiteStore(databaseURL: url) }
            let c = try SQLiteConnection(url: url)
            try c.execute("CREATE TABLE imported_reference_claims(fixture TEXT)")
            try c.execute("PRAGMA user_version=\(version)")
            XCTAssertThrowsError(try SQLiteStore.openRecovering(databaseURL: url))
            XCTAssertEqual(try c.scalarInt("PRAGMA user_version"), version)
        }
    }
    func testImportRemapsIdentityAndOlderPayloadDoesNotClearFavorites() async throws {
        let store = try SQLiteStore(databaseURL: path())
        let local = StoredConfiguration(name: "Local", sourceKind: .pasted, rawData: Data("{}".utf8))
        try await store.saveConfiguration(local)
        let favorite = FavoriteRecord(siteKey: "s", videoID: "a", title: "A", configurationID: local.id)
        try await store.saveFavorite(favorite)
        var external = local; external.id = UUID()
        var imported = favorite; imported.configurationID = external.id
        let restored = try await store.restoreConfigurationAndHistory(configuration: external, history: [], favorites: [imported])
        XCTAssertEqual(restored.configuration.id, local.id)
        _ = try await store.restoreConfigurationAndHistory(configuration: external, history: [])
        let values = try await store.favorites()
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values[0].favoriteID, favorite.favoriteID)
    }
}
