import Foundation
import CSQLite
import OKVideoCore
import OKVideoPersistence

/// Developer-only projection of an EXISTING temporary snapshot. Never opens the
/// user DB, never initializes SQLiteStore, never upgrades even the temporary DB.
public enum ImportedAdmissionSnapshot {
    public static func read(temporaryDatabase: URL) throws -> ImportedAdmissionInput {
        let resolved = temporaryDatabase.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        guard resolved.lastPathComponent == "snapshot.sqlite3",
              resolved.deletingLastPathComponent().deletingLastPathComponent() == root,
              resolved.deletingLastPathComponent().lastPathComponent.hasPrefix("OKVideoMac-8B2-DryRun-") else {
            throw SnapshotError.unsafeFile
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(resolved.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            if let handle { sqlite3_close(handle) }; throw SnapshotError.sqliteFailure
        }
        defer { sqlite3_close(db) }
        func rows(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SnapshotError.sqliteFailure }
            defer { sqlite3_finalize(statement) }
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return }
                guard code == SQLITE_ROW else { throw SnapshotError.sqliteFailure }
                try body(statement)
            }
        }
        func text(_ row: OpaquePointer, _ column: Int32) -> String? {
            sqlite3_column_text(row, column).map { String(cString: $0) }
        }
        func required(_ row: OpaquePointer, _ column: Int32) throws -> String {
            guard let value = text(row, column) else { throw SnapshotError.invalidDatabase }; return value
        }
        func blob(_ row: OpaquePointer, _ column: Int32) throws -> Data {
            guard sqlite3_column_type(row, column) == SQLITE_BLOB else { throw SnapshotError.invalidDatabase }
            guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
        }
        // All tables and schema observed from ONE SQLite read transaction.
        try rows("BEGIN") { _ in }
        var schema = 0
        try rows("PRAGMA user_version") { schema = Int(sqlite3_column_int($0, 0)) }
        guard [9, 10].contains(schema) else { throw MigrationAdmissionError.unsupportedVersion }
        var sources: [StoredLiveSource] = []
        try rows("SELECT id,name,source_kind,source_value,base_url,raw_data,updated_at FROM live_sources ORDER BY id") { row in
            guard let id = UUID(uuidString: try required(row, 0)),
                  let kind = StoredLiveSourceKind(rawValue: try required(row, 2)) else { throw SnapshotError.invalidDatabase }
            let base = text(row, 4)
            guard base == nil || base.flatMap(URL.init(string:)) != nil else { throw SnapshotError.invalidDatabase }
            sources.append(StoredLiveSource(id: id, name: try required(row, 1), sourceKind: kind,
                sourceValue: text(row, 3), baseURL: base.flatMap(URL.init(string:)), rawData: try blob(row, 5),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 6))))
        }
        var favorites: [ImportedLegacyReference] = [], hidden: [ImportedLegacyReference] = []
        try rows("SELECT key,value FROM settings WHERE key IN ('live.favoriteChannels','live.deletedChannels')") { row in
            let refs = try ImportedMigrationDryRun.references(JSONDecoder().decode(JSONValue.self, from: blob(row, 1)))
            if text(row, 0) == "live.favoriteChannels" { favorites = refs } else { hidden = refs }
        }
        var registry: [ImportedChannelRegistryRecord] = []
        if schema == 10 {
            try rows("SELECT source_id,local_id,record_version,evidence_version,lifecycle,provenance,evidence,created_at,updated_at FROM imported_channel_identities") { row in
                guard let source = UUID(uuidString: try required(row, 0)), let local = UUID(uuidString: try required(row, 1)),
                      let lifecycle = ImportedChannelRegistryLifecycle(rawValue: try required(row, 4)),
                      let provenance = ImportedSourceProvenance(rawValue: try required(row, 5)) else { throw SnapshotError.invalidDatabase }
                let data = try blob(row, 6)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(object.keys).isSubset(of: ["upstream", "group", "name", "tvgID", "region", "language", "channelType"]) else {
                    throw MigrationAdmissionError.unsupportedVersion
                }
                if let upstream = object["upstream"] as? [String: Any],
                   !Set(upstream.keys).isSubset(of: ["namespace", "value", "formatSupportsStableID"]) { throw MigrationAdmissionError.unsupportedVersion }
                registry.append(ImportedChannelRegistryRecord(identity: try ImportedLiveChannelIdentity(source: .imported(source), localID: local),
                    evidence: try JSONDecoder().decode(ImportedChannelEvidence.self, from: data), provenance: provenance, lifecycle: lifecycle,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 7)), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 8)),
                    recordVersion: Int(sqlite3_column_int(row, 2)), evidenceVersion: Int(sqlite3_column_int(row, 3))))
            }
        }
        // Authority storage has NOT been integrated. Refuse snapshots that may
        // already contain it; do not project an unknown authority as empty.
        var knownTables = Set<String>()
        try rows("SELECT name FROM sqlite_master WHERE type='table'") { if let name = text($0, 0) { knownTables.insert(name) } }
        let supportedTables: Set<String> = ["configurations", "favorites", "history", "settings", "live_sources",
                                            "imported_channel_identities", "sqlite_sequence"]
        guard knownTables.isSubset(of: supportedTables) else {
            throw MigrationAdmissionError.unsupportedVersion
        }
        guard knownTables.contains("imported_channel_identities") == (schema == 10) else {
            throw SnapshotError.invalidDatabase
        }
        try rows("COMMIT") { _ in }
        return ImportedAdmissionInput(sources: sources, registry: registry, favorites: favorites, hidden: hidden, schemaVersion: schema)
    }
}
