import Foundation
import OKVideoCore
import OKVideoPersistence

public enum ImportedMigrationDryRun {
    /// This API accepts a snapshot capability, not an arbitrary database URL.
    /// Its only writable SQLiteStore connection is the temporary snapshot.
    public static func run(snapshot: DryRunDatabaseSnapshot) async throws -> ImportedChannelMigrationPlan {
        let store = try SQLiteStore(databaseURL: snapshot.database)
        let stored = try await store.liveSources()
        guard stored.count == snapshot.tableCounts["live_sources"] else { throw SnapshotError.invalidDatabase }
        let favorites = try references(try await store.setting(forKey: "live.favoriteChannels"))
        let hidden = try references(try await store.setting(forKey: "live.deletedChannels"))
        var sources: [MigrationSourceSnapshot] = []
        for source in stored {
            let records = try await store.importedChannelIdentities(for: .imported(source.id))
            let existing = records.map { ImportedExistingChannel(identity: $0.identity, evidence: $0.evidence) }
            // Do not trust retired/unknown ownership as active channel evidence.
            let registryUsable = records.allSatisfy { $0.provenance == .verified && $0.lifecycle == .active }
            do {
                let parsed = try ImportedPreMergeEvidence.parse(source.rawData, baseURL: source.baseURL)
                let playlist = parsed.playlist
                let channels = playlist.groups.flatMap(\.channels).map {
                    MigrationChannel(legacyChannelID: $0.id, evidence: ImportedChannelEvidence(
                        group: $0.groupName, name: $0.name, tvgID: $0.tvgID))
                }
                // Same production parser pass, observing accepted records before
                // merge; no second parser and no reconstruction from surviving lines.
                sources.append(MigrationSourceSnapshot(id: source.id, name: source.name,
                    format: playlist.format.rawValue, channels: channels, existing: existing,
                    rawObservations: parsed.observations, catalogComplete: registryUsable))
            } catch {
                // Keep the source visible in the report. Never silently omit an
                // unparsable catalog, and never include decoder error payloads.
                sources.append(MigrationSourceSnapshot(id: source.id, name: source.name,
                    format: "parse unavailable", channels: [], existing: existing, catalogComplete: false))
            }
        }
        return try ImportedChannelMigrationPlanner.plan(sources: sources, favorites: favorites, hidden: hidden)
    }

    static func references(_ value: JSONValue?) throws -> [ImportedLegacyReference] {
        guard let value else { return [] }
        guard case .array(let members) = value else { throw SnapshotError.invalidSettings }
        return try members.map {
            guard case .string(let raw) = $0 else { throw SnapshotError.invalidSettings }
            return ImportedLegacyReference(raw)
        }
    }

    public static func writeReports(plan: ImportedChannelMigrationPlan, snapshot: DryRunDatabaseSnapshot,
                                    realDatabase: URL) throws {
        let after = try QuiescentDatabaseSnapshot.audit(database: realDatabase)
        let temp = try QuiescentDatabaseSnapshot.inspectTemporary(database: snapshot.database)
        struct Safety: Encodable {
            let realDBOpenedBySQLite = false
            let realDBOpenedWritable = false
            let realRegistryRowsWritten = 0
            let realFavoritesChangedByDryRun = false
            let realHiddenChangedByDryRun = false
            let consistentSnapshotMethod = "App quiescence + existing instance lease + verified main/WAL copy + SQLite backup on temporary copy"
            let schemaAtConsistentSnapshot: Int
            let realSchemaAfterIfBytesUnchanged: Int?
            let tempSchemaBefore: Int
            let tempSchemaAfter: Int
            let sourceFilesBefore: [String: SnapshotFileAudit]
            let sourceFilesAfter: [String: SnapshotFileAudit]
            let sourceFilesUnchanged: Bool
            let originalTableCounts: [String: Int]
            let tempTableCounts: [String: Int]
        }
        let same = after == snapshot.sourceFiles
        let safety = Safety(schemaAtConsistentSnapshot: snapshot.schemaVersion,
            realSchemaAfterIfBytesUnchanged: same ? snapshot.schemaVersion : nil,
            tempSchemaBefore: snapshot.schemaVersion, tempSchemaAfter: temp.schema,
            sourceFilesBefore: snapshot.sourceFiles, sourceFilesAfter: after, sourceFilesUnchanged: same,
            originalTableCounts: snapshot.tableCounts, tempTableCounts: temp.counts)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try QuiescentDatabaseSnapshot.writePrivate(encoder.encode(safety), to: snapshot.directory.appendingPathComponent("DatabaseSafety.json"))
        try QuiescentDatabaseSnapshot.writePrivate(plan.json(), to: snapshot.directory.appendingPathComponent("ImportedIdentityMigrationDryRun.json"))
        let appendix = """

        ## Database safety

        - Real SQLite connection: NONE (no writable or read-only SQLite connection).
        - Real schema at snapshot: \(snapshot.schemaVersion).
        - Real main/WAL/SHM byte digests unchanged after dry-run: \(same).
        - Temp schema: \(snapshot.schemaVersion) → \(temp.schema).
        - Registry/Favorite/Hidden user mutations: 0.

        ## Rollback Compatibility / 8B.3 gate

        Schema 10 is rejected by a schema 9 SQLiteStore (newer-version guard).
        Before any production 8B.3: verify a consistent backup including WAL,
        identify the compatible App build, test restoration on a copy, close all
        clients, and approve an atomic migration/rollback procedure separately.
        Never open the real DB with this developer build just to inspect it.

        Pre-merge observations count successfully parsed channel entries, not
        comments or rejected stream references. M3U/TXT/JSON share the production
        parser path. Unsupported or incomplete evidence still fails closed.
        Multiple records with identical metadata are not proof of one permanent
        channel identity. Favorite name-only ownership is not historical provenance.
        All unresolved/orphaned references remain intact. No 8B.3 authorization.

        """
        try QuiescentDatabaseSnapshot.writePrivate(Data((plan.markdown() + appendix).utf8),
            to: snapshot.directory.appendingPathComponent("ImportedIdentityMigrationDryRun.md"))
    }
}
