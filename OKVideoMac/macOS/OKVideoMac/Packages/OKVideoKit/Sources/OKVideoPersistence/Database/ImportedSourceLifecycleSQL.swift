import Foundation
import CSQLite
import OKVideoCore
import CryptoKit

/// Negative inheritance evidence, NEVER ownership or a channel identifier.
/// Hashes prevent adding another persistent copy of opaque user metadata.
struct ImportedRetirementReferenceBlock: Codable, Equatable {
    let retiredSourceID: UUID
    let kind: MigrationReferenceKind
    let tokenDigest: String
    let existingSources: [UUID]
    static func digest(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    func denies(_ source: UUID, kind: MigrationReferenceKind, token: String) -> Bool {
        self.kind == kind && tokenDigest == Self.digest(token) && !existingSources.contains(source)
    }
}

/// Historical source facts are not playable StoredLiveSource values. Tombstones
/// retain no locator or raw catalog, and have no ordinary restore operation.
struct ImportedSourceHistory: Equatable {
    let id: UUID
    let retiredAt: Date?
}

/// Shared by the App actor and the borrowed developer transaction. No network,
/// implicit allocation, or alternate source registry lives here.
enum ImportedSourceLifecycleSQL {
    static func migrate(_ c: SQLiteConnection) throws {
        guard try c.scalarInt("PRAGMA user_version") == 11 else { throw ImportedExecutionError.blocked }
        try c.transaction {
            try c.execute("ALTER TABLE live_sources ADD COLUMN retired_at REAL")
            try c.execute("CREATE INDEX live_sources_active ON live_sources(retired_at,id)")
            try c.execute("""
                CREATE TABLE imported_retirement_reference_blocks (
                    retired_source_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('favorite','hidden')),
                    token_digest TEXT NOT NULL CHECK(length(token_digest)=64), existing_sources BLOB NOT NULL,
                    PRIMARY KEY(retired_source_id,kind,token_digest)
                ) WITHOUT ROWID
                """)
            try c.execute("""
                CREATE TRIGGER imported_retirement_block_no_update BEFORE UPDATE ON imported_retirement_reference_blocks
                BEGIN SELECT RAISE(ABORT,'immutable retirement evidence'); END
                """)
            try c.execute("""
                CREATE TRIGGER imported_retirement_block_no_delete BEFORE DELETE ON imported_retirement_reference_blocks
                BEGIN SELECT RAISE(ABORT,'retirement evidence cannot be removed'); END
                """)
            try c.execute("""
                CREATE TRIGGER imported_source_tombstone_immutable BEFORE UPDATE ON live_sources
                WHEN OLD.retired_at IS NOT NULL
                BEGIN SELECT RAISE(ABORT,'retired source is immutable'); END
                """)
            try c.execute("""
                CREATE TRIGGER imported_source_no_physical_delete BEFORE DELETE ON live_sources
                BEGIN SELECT RAISE(ABORT,'source requires retirement'); END
                """)
            try c.execute("PRAGMA user_version=12")
            let validation = ImportedMigrationTransaction(c)
            defer { validation.active = false }
            _ = try validation.snapshot()
        }
    }

    static func history(_ c: SQLiteConnection) throws -> [ImportedSourceHistory] {
        let modern = try c.scalarInt("PRAGMA user_version") >= 12
        var result: [ImportedSourceHistory] = []
        try c.query("SELECT id, \(modern ? "retired_at" : "NULL") FROM live_sources ORDER BY id") { row in
            guard let id = c.text(row, 0).flatMap(UUID.init(uuidString:)) else { throw ImportedExecutionError.corruption }
            let date = sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(row, 1))
            guard date == nil || date!.timeIntervalSince1970.isFinite else { throw ImportedExecutionError.corruption }
            result.append(ImportedSourceHistory(id: id, retiredAt: date))
        }
        return result
    }

    static func requireActive(_ id: UUID, _ c: SQLiteConnection) throws {
        let modern = try c.scalarInt("PRAGMA user_version") >= 12
        // Frozen schema-11 developer fixtures predate source lifecycle; they
        // cannot open a schema-12 database. New acceptance writes all use 12.
        guard modern else { return }
        var found = false
        try c.query("SELECT 1 FROM live_sources WHERE lower(id)=?" + (modern ? " AND retired_at IS NULL" : ""),
            bindings: [.text(id.uuidString.lowercased())]) { _ in found = true }
        guard found else { throw ImportedExecutionError.blocked }
    }

    static func blocks(_ c: SQLiteConnection) throws -> [ImportedRetirementReferenceBlock] {
        guard try c.scalarInt("PRAGMA user_version") >= 12 else { return [] }
        let history = try history(c)
        var result: [ImportedRetirementReferenceBlock] = []
        try c.query("SELECT retired_source_id,kind,token_digest,existing_sources FROM imported_retirement_reference_blocks ORDER BY retired_source_id,kind,token_digest") { row in
            guard let id = c.text(row, 0).flatMap(UUID.init(uuidString:)),
                  history.contains(where: { $0.id == id && $0.retiredAt != nil }),
                  let kind = c.text(row, 1).flatMap(MigrationReferenceKind.init(rawValue:)),
                  let digest = c.text(row, 2), digest.count == 64,
                  digest.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let data = c.data(row, 3), data.count <= 8 * 1024 * 1024 else { throw ImportedExecutionError.corruption }
            let existing = try JSONDecoder().decode([UUID].self, from: data)
            guard Set(existing).count == existing.count, !existing.contains(id),
                  existing.allSatisfy({ other in history.contains { $0.id == other } }) else { throw ImportedExecutionError.corruption }
            result.append(.init(retiredSourceID: id, kind: kind, tokenDigest: digest, existingSources: existing))
        }
        return result
    }

    static func retire(_ id: UUID, snapshot: ImportedMigrationStoreSnapshot, connection c: SQLiteConnection,
                       checkpoint: (Int) throws -> Void) throws {
        try requireActive(id, c)
        let existing = snapshot.sources.map(\.id).filter { $0 != id }.sorted { $0.uuidString < $1.uuidString }
        // Preserve every pre-existing opaque reference as negative evidence.
        // We cannot split orphan Favorite strings to infer an old source name.
        // Existing namespaces retain their legacy behavior; new namespaces may
        // not acquire any of these historical tokens merely by coincidence.
        let encoder = JSONEncoder()
        for (kind, refs) in [(MigrationReferenceKind.favorite, snapshot.favorites), (.hidden, snapshot.hidden)] {
            let tokens = Set(refs.map(\.rawValue) + snapshot.claims.filter { $0.sourceID == id && $0.kind == kind }.map(\.legacyToken))
            for token in tokens.sorted() {
                try c.execute("INSERT INTO imported_retirement_reference_blocks VALUES (?,?,?,?)",
                    bindings: [.text(id.uuidString.lowercased()), .text(kind.rawValue),
                               .text(ImportedRetirementReferenceBlock.digest(token)), .blob(try encoder.encode(existing))])
            }
        }
        try checkpoint(1)
        let now = Date().timeIntervalSince1970
        try c.execute("UPDATE imported_channel_identities SET lifecycle='retired', updated_at=MAX(updated_at,?) WHERE source_id=?",
            bindings: [.double(now), .text(id.uuidString.lowercased())])
        try checkpoint(2)
        // Keep NOT NULL columns valid without retaining the playlist or its secrets.
        try c.execute("""
            UPDATE live_sources SET retired_at=?, name='Retired source', source_kind='pasted',
                source_value=NULL, base_url=NULL, raw_data=X'', updated_at=? WHERE lower(id)=?
            """, bindings: [.double(now), .double(now), .text(id.uuidString.lowercased())])
        guard c.lastChangedRowCount() == 1 else { throw ImportedExecutionError.blocked }
        try checkpoint(3)
    }
}
