import XCTest
import Foundation
import OKVideoCore
@testable import OKVideoPersistence

final class ImportedAppWiringTests: XCTestCase {
    private func workspace() throws -> ImportedAcceptanceWorkspace {
        let root = URL(fileURLWithPath: "/private/tmp/OKVideoMac-8B3B-Test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try ImportedAcceptanceWorkspace(root: root)
    }
    private func source(_ id: UUID, names: [String] = ["X", "Y"]) -> StoredLiveSource {
        let raw = "#EXTM3U\n" + names.map { "#EXTINF:-1 group-title=\"G\",\($0)\nhttps://fixture.invalid/\($0)\n" }.joined()
        return StoredLiveSource(id: id, name: "Fixture", sourceKind: .remote, sourceValue: "https://fixture.invalid/list", rawData: Data(raw.utf8))
    }
    private func channels(_ source: StoredLiveSource) throws -> [LiveChannel] {
        try LiveSourceParser().parse(source.rawData).groups.flatMap(\.channels)
    }
    private func count(_ w: ImportedAcceptanceWorkspace, _ table: String) throws -> Int {
        let c = try SQLiteConnection(url: w.databaseURL); defer { c.close() }
        return try c.scalarInt("SELECT count(*) FROM \(table)")
    }
    private func seedLegacy(_ w: ImportedAcceptanceWorkspace, token: String) throws {
        // Fixture-only SQL: generic runtime settings writes are denied.
        let c = try SQLiteConnection(url: w.databaseURL); defer { c.close() }
        try c.execute("INSERT INTO settings(key,value) VALUES ('live.deletedChannels',?)",
            bindings: [.blob(try JSONEncoder().encode([token]))])
    }
    func testNormalStoreStillRejectsSchema11() async throws {
        let w = try workspace()
        _ = try SQLiteStore(importedAcceptance: w)
        XCTAssertThrowsError(try SQLiteStore(databaseURL: w.databaseURL))
    }
    func testRefreshRaceOnlyBMayAllocate() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w)
        let a = source(UUID()), b = source(UUID())
        try await db.saveLiveSource(a); try await db.saveLiveSource(b)
        let first = ImportedCatalogGeneration(sourceID: a.id)
        first.invalidate()
        let second = ImportedCatalogGeneration(sourceID: a.id)
        second.invalidate()
        let current = ImportedCatalogGeneration(sourceID: b.id)
        let mapping = try await db.importedCatalogMapping(sourceID: b.id, generation: current)
        for old in [first, second] {
            do { try await db.acceptImportedRefresh(source(a.id, names: ["LATE"]), generation: old); XCTFail("late catalog admitted") } catch {}
            do { _ = try await db.importedCatalogMapping(sourceID: a.id, generation: old); XCTFail("late allocation admitted") } catch {}
        }
        let sources = try await db.liveSources()
        XCTAssertEqual(sources.first { $0.id == a.id }?.rawData, a.rawData)
        XCTAssertEqual(try count(w, "imported_channel_identities"), 2)
        XCTAssertEqual(mapping.sourceID, b.id)
        XCTAssertEqual(mapping.value(channel: try channels(b)[0], kind: .hidden), false)
    }
    func testClaimedDisappearsReappearsKeepsUUIDAndFalseValue() async throws {
        let w = try workspace(), id = UUID(), initial = source(id)
        var db: SQLiteStore? = try SQLiteStore(importedAcceptance: w)
        try await db!.saveLiveSource(initial)
        let x = try channels(initial)[0]
        let token = ImportedChannelMigrationPlanner.hiddenKey(sourceID: id, channelID: x.id)
        try seedLegacy(w, token: token)
        var generation = ImportedCatalogGeneration(sourceID: id)
        let first = try await db!.importedCatalogMapping(sourceID: id, generation: generation)
        let originalAuthority = first.authority(channel: x, kind: .hidden)
        let unhidden = try await db!.setImportedReferences(mapping: first, edits: [(x, .hidden, false)])
        XCTAssertEqual(unhidden.value(channel: x, kind: .hidden), false)
        generation.invalidate()
        generation = ImportedCatalogGeneration(sourceID: id)
        try await db!.acceptImportedRefresh(source(id, names: ["Y"]), generation: generation)
        let missing = try await db!.importedCatalogMapping(sourceID: id, generation: generation)
        XCTAssertEqual(missing.authority(channel: x, kind: .hidden), .blocked)
        XCTAssertEqual(try count(w, "imported_reference_claims"), 1)
        XCTAssertEqual(try count(w, "imported_channel_identities"), 2)
        db = nil
        db = try SQLiteStore(importedAcceptance: w)
        generation = ImportedCatalogGeneration(sourceID: id)
        try await db!.acceptImportedRefresh(initial, generation: generation)
        let returned = try await db!.importedCatalogMapping(sourceID: id, generation: generation)
        XCTAssertEqual(returned.authority(channel: x, kind: .hidden), originalAuthority)
        XCTAssertEqual(returned.value(channel: x, kind: .hidden), false)
        let legacy = try await db!.setting(forKey: "live.deletedChannels")
        XCTAssertEqual(legacy, .array([.string(token)]))
        XCTAssertEqual(try count(w, "imported_channel_identities"), 2)
    }
    func testRevokedMappingCannotWriteOrRead() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source(UUID())
        try await db.saveLiveSource(s)
        let g = ImportedCatalogGeneration(sourceID: s.id)
        let m = try await db.importedCatalogMapping(sourceID: s.id, generation: g)
        g.invalidate()
        XCTAssertNil(m.value(channel: try channels(s)[0], kind: .hidden))
        do { _ = try await db.setImportedReferences(mapping: m, edits: [(try channels(s)[0], .hidden, true)]); XCTFail() } catch {}
        XCTAssertEqual(try count(w, "imported_stable_references"), 0)
    }
    func testBatchWriteFailureRollsBackEarlierEdit() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source(UUID())
        try await db.saveLiveSource(s)
        let m = try await db.importedCatalogMapping(sourceID: s.id, generation: ImportedCatalogGeneration(sourceID: s.id))
        let unknown = try channels(source(UUID(), names: ["UNKNOWN"]))[0]
        do { _ = try await db.setImportedReferences(mapping: m, edits: [(try channels(s)[0], .hidden, true), (unknown, .hidden, true)]); XCTFail() } catch {}
        let setting = try await db.setting(forKey: "live.deletedChannels")
        XCTAssertNil(setting)
    }
    func testNewEligibleChannelsIncrementWithoutReallocating() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source(UUID())
        try await db.saveLiveSource(s)
        let g = ImportedCatalogGeneration(sourceID: s.id)
        _ = try await db.importedCatalogMapping(sourceID: s.id, generation: g)
        try await db.acceptImportedRefresh(source(s.id, names: ["Y", "X", "Z"]), generation: g)
        _ = try await db.importedCatalogMapping(sourceID: s.id, generation: g)
        XCTAssertEqual(try count(w, "imported_channel_identities"), 3)
    }
    func testWorkspaceRejectsLibraryAndMissingRoot() throws {
        XCTAssertThrowsError(try ImportedAcceptanceWorkspace(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OKVideoMac")))
        XCTAssertThrowsError(try ImportedAcceptanceWorkspace(root: URL(fileURLWithPath: "/private/tmp/OKVideoMac-8B3B-MISSING-\(UUID())")))
    }
    func testLegacySourceDeleteCannotOrphanAllocatedRegistry() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source(UUID())
        try await db.saveLiveSource(s)
        _ = try await db.importedCatalogMapping(sourceID: s.id, generation: ImportedCatalogGeneration(sourceID: s.id))
        do { try await db.deleteLiveSource(id: s.id); XCTFail("orphaned ownership") } catch {}
        let sources = try await db.liveSources()
        XCTAssertEqual(sources.map(\.id), [s.id])
        XCTAssertEqual(try count(w, "imported_channel_identities"), 2)
    }
    func testInvalidatedInsideTransactionRollsBackRegistryClaimAndMarker() async throws {
        let w = try workspace(), db = try SQLiteStore(importedAcceptance: w), s = source(UUID())
        try await db.saveLiveSource(s)
        let token = ImportedChannelMigrationPlanner.hiddenKey(sourceID: s.id, channelID: try channels(s)[0].id)
        try seedLegacy(w, token: token)
        let g = ImportedCatalogGeneration(sourceID: s.id)
        do {
            _ = try await db.importedCatalogMapping(sourceID: s.id, generation: g, beforeCommit: { g.invalidate() })
            XCTFail("revoked transaction committed")
        } catch {}
        for table in ["imported_channel_identities", "imported_reference_claims", "imported_stable_references", "imported_migration_batches"] {
            XCTAssertEqual(try count(w, table), 0)
        }
        let current = ImportedCatalogGeneration(sourceID: s.id)
        _ = try await db.importedCatalogMapping(sourceID: s.id, generation: current)
        XCTAssertEqual(try count(w, "imported_channel_identities"), 2)
        XCTAssertEqual(try count(w, "imported_reference_claims"), 1)
    }
    func testWorkspaceRejectsSymlinkBeforeSQLiteOpen() throws {
        let w = try workspace()
        try FileManager.default.createSymbolicLink(at: w.root.appendingPathComponent("Application Support"), withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OKVideoMac"))
        XCTAssertThrowsError(try SQLiteStore(importedAcceptance: w))
    }
    func testWorkspaceRejectsHardLinkedDatabase() throws {
        let w = try workspace()
        let file = w.root.appendingPathComponent("original")
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.linkItem(at: file, to: w.root.appendingPathComponent("linked"))
        XCTAssertThrowsError(try SQLiteStore(importedAcceptance: w))
    }
}
