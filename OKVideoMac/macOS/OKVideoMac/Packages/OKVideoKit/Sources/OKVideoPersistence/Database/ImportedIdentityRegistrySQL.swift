import CSQLite
import Foundation
import OKVideoCore

/// SQL mapping on SQLiteStore's existing private connection, not another store,
/// actor or database. Callers must hold the store's transaction for mutations.
enum ImportedIdentityRegistrySQL {
    static func createSchema(_ connection: SQLiteConnection) throws {
        try connection.execute("""
            CREATE TABLE imported_channel_identities (
                source_id TEXT NOT NULL,
                local_id TEXT NOT NULL,
                record_version INTEGER NOT NULL CHECK(record_version > 0),
                evidence_version INTEGER NOT NULL CHECK(evidence_version > 0),
                lifecycle TEXT NOT NULL,
                provenance TEXT NOT NULL,
                evidence BLOB NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL CHECK(updated_at >= created_at),
                PRIMARY KEY(source_id, local_id)
            ) WITHOUT ROWID
            """)
        // No FK cascade: removed-source identities may need retention. Ownership
        // is still mandatory and typed in the API. No metadata UNIQUE constraint.
        try connection.execute("""
            CREATE INDEX imported_channel_identities_source_lifecycle
            ON imported_channel_identities(source_id, lifecycle, local_id)
            """)
    }

    static func sourceUUID(_ source: LiveSourceID) throws -> String {
        guard case .imported(let id) = source else { throw ImportedChannelRegistryError.unsupportedSource }
        return id.uuidString.lowercased()
    }

    private static let columns = "source_id, local_id, record_version, evidence_version, lifecycle, provenance, evidence, created_at, updated_at"

    static func fetch(_ identity: ImportedLiveChannelIdentity, connection: SQLiteConnection) throws -> ImportedChannelRegistryRecord? {
        var result: ImportedChannelRegistryRecord?
        try connection.query("SELECT \(columns) FROM imported_channel_identities WHERE source_id = ? AND local_id = ?",
                             bindings: [.text(try sourceUUID(identity.source)), .text(identity.localID.uuidString.lowercased())]) {
            result = try decode($0, connection: connection)
        }
        return result
    }

    static func list(_ source: LiveSourceID, lifecycle: ImportedChannelRegistryLifecycle?,
                     connection: SQLiteConnection) throws -> [ImportedChannelRegistryRecord] {
        var result: [ImportedChannelRegistryRecord] = []
        var bindings: [SQLiteBinding] = [.text(try sourceUUID(source))]
        if let lifecycle { bindings.append(.text(lifecycle.rawValue)) }
        try connection.query("SELECT \(columns) FROM imported_channel_identities WHERE source_id = ?"
            + (lifecycle == nil ? "" : " AND lifecycle = ?") + " ORDER BY local_id", bindings: bindings) {
            result.append(try decode($0, connection: connection))
        }
        return result
    }

    static func apply(_ mutation: ImportedChannelRegistryMutation, connection: SQLiteConnection) throws {
        switch mutation {
        case .upsert(let record):
            try validate(record)
            // Never blindly overwrite a row from a newer codec or one with unknown
            // fields. Reads fail closed, leaving bytes intact for a newer reader.
            if let previous = try fetch(record.identity, connection: connection) {
                guard previous.createdAt == record.createdAt,
                      previous.updatedAt <= record.updatedAt else { throw ImportedChannelRegistryError.staleUpdate }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record.evidence)
            guard data.count <= 32 * 1024 else { throw ImportedChannelRegistryError.invalidRecord }
            try connection.execute("""
                INSERT INTO imported_channel_identities (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id, local_id) DO UPDATE SET
                    record_version = excluded.record_version,
                    evidence_version = excluded.evidence_version,
                    lifecycle = excluded.lifecycle,
                    provenance = excluded.provenance,
                    evidence = excluded.evidence,
                    updated_at = excluded.updated_at
                """, bindings: [.text(try sourceUUID(record.identity.source)), .text(record.identity.localID.uuidString.lowercased()),
                    .integer(Int64(record.recordVersion)), .integer(Int64(record.evidenceVersion)),
                    .text(record.lifecycle.rawValue), .text(record.provenance.rawValue), .blob(data),
                    .double(record.createdAt.timeIntervalSince1970), .double(record.updatedAt.timeIntervalSince1970)])
        case .remove(let identity):
            try connection.execute("DELETE FROM imported_channel_identities WHERE source_id = ? AND local_id = ?",
                bindings: [.text(try sourceUUID(identity.source)), .text(identity.localID.uuidString.lowercased())])
        case .removeAll(let source):
            try connection.execute("DELETE FROM imported_channel_identities WHERE source_id = ?",
                                   bindings: [.text(try sourceUUID(source))])
        }
    }

    private static func decode(_ statement: OpaquePointer, connection: SQLiteConnection) throws -> ImportedChannelRegistryRecord {
        guard let sourceText = connection.text(statement, 0), let source = UUID(uuidString: sourceText),
              let localText = connection.text(statement, 1), let local = UUID(uuidString: localText),
              sourceText == source.uuidString.lowercased(), localText == local.uuidString.lowercased(),
              let data = connection.data(statement, 6), data.count <= 32 * 1024 else {
            throw ImportedChannelRegistryError.invalidRecord
        }
        let recordVersion = Int(sqlite3_column_int64(statement, 2))
        let evidenceVersion = Int(sqlite3_column_int64(statement, 3))
        guard recordVersion == ImportedChannelRegistryRecord.currentRecordVersion,
              evidenceVersion == ImportedChannelRegistryRecord.currentEvidenceVersion else {
            throw ImportedChannelRegistryError.unsupportedVersion
        }
        guard let lifecycleText = connection.text(statement, 4),
              let lifecycle = ImportedChannelRegistryLifecycle(rawValue: lifecycleText),
              let provenanceText = connection.text(statement, 5),
              let provenance = ImportedSourceProvenance(rawValue: provenanceText) else {
            throw ImportedChannelRegistryError.unsupportedFields
        }
        let evidence = try decodeEvidence(data)
        let record = ImportedChannelRegistryRecord(
            identity: try ImportedLiveChannelIdentity(source: .imported(source), localID: local), evidence: evidence,
            provenance: provenance, lifecycle: lifecycle,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            recordVersion: recordVersion, evidenceVersion: evidenceVersion)
        try validate(record)
        return record
    }

    private static func decodeEvidence(_ data: Data) throws -> ImportedChannelEvidence {
        // Optional known fields may be absent. Unknown fields/versions are not
        // silently discarded by synthesized Codable and then lost on an upsert.
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ImportedChannelRegistryError.invalidRecord
        }
        let allowed: Set<String> = ["group", "name", "upstream", "tvgID", "region", "language", "channelType"]
        guard Set(object.keys).isSubset(of: allowed) else { throw ImportedChannelRegistryError.unsupportedFields }
        if let upstream = object["upstream"] as? [String: Any],
           !Set(upstream.keys).isSubset(of: ["namespace", "value", "formatSupportsStableID"]) {
            throw ImportedChannelRegistryError.unsupportedFields
        }
        do { return try JSONDecoder().decode(ImportedChannelEvidence.self, from: data) }
        catch { throw ImportedChannelRegistryError.invalidRecord }
    }

    private static func validate(_ record: ImportedChannelRegistryRecord) throws {
        guard record.recordVersion == ImportedChannelRegistryRecord.currentRecordVersion,
              record.evidenceVersion == ImportedChannelRegistryRecord.currentEvidenceVersion else {
            throw ImportedChannelRegistryError.unsupportedVersion
        }
        let created = record.createdAt.timeIntervalSince1970
        let updated = record.updatedAt.timeIntervalSince1970
        guard created.isFinite, updated.isFinite, updated >= created else { throw ImportedChannelRegistryError.invalidTimestamp }
        let evidence = record.evidence
        let fields = [evidence.group, evidence.name, evidence.tvgID, evidence.region, evidence.language,
                      evidence.channelType, evidence.upstream?.namespace, evidence.upstream?.value].compactMap { $0 }
        // Defense in depth for accidentally misrouted endpoints/auth material.
        // This is NOT an arbitrary-secret classifier: callers must only supply
        // public metadata; no URL/header/raw response field exists in this API.
        for field in fields {
            guard field.utf8.count <= 2048, !field.contains("://"),
                  !field.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  LogRedactor.text(field) == field,
                  !field.lowercased().hasPrefix("bearer "), !field.lowercased().hasPrefix("basic ") else {
                throw ImportedChannelRegistryError.unsafeEvidence
            }
        }
    }
}
