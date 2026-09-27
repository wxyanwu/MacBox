import Foundation
import CSQLite
import OKVideoCore

@_spi(ImportedMigration) public enum ImportedMigrationStoreError: Error { case unsafePath, corruption, expiredTransaction, unsupportedVersion }

/// Process proof only. No fingerprint, no source-level "migrated" boolean, and
/// no assertion that a mutable stable value must remain true after user edits.
@_spi(ImportedMigration) public struct ImportedMigrationBatch: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let version: Int
    public let identities: [ImportedLiveChannelIdentity]
    public let claims: [ImportedReferenceClaim]
    public let holds: [ImportedReferenceHold]
    public init(id: UUID, identities: [ImportedLiveChannelIdentity], claims: [ImportedReferenceClaim], holds: [ImportedReferenceHold] = []) {
        self.id = id; self.version = 1; self.identities = identities; self.claims = claims; self.holds = holds
    }
    public var description: String { "ImportedMigrationBatch(<proof omitted>)" }
    public var debugDescription: String { description }
}
@_spi(ImportedMigration) public struct ImportedMigrationStoreSnapshot: CustomStringConvertible, CustomDebugStringConvertible {
    public let sources: [StoredLiveSource]
    public let registry: [ImportedChannelRegistryRecord]
    public let favorites: [ImportedLegacyReference]
    public let hidden: [ImportedLegacyReference]
    public let claims: [ImportedReferenceClaim]
    public let stable: [ImportedStableReferenceState]
    public let holds: [ImportedReferenceHold]
    public let batches: [ImportedMigrationBatch]
    var sourceHistory: [ImportedSourceHistory] = []
    var schemaVersion: Int = 11
    var retirementBlocks: [ImportedRetirementReferenceBlock] = []
    public var description: String { "ImportedMigrationStoreSnapshot(<private input>)" }
    public var debugDescription: String { description }
}

/// Restricted developer SPI. Not called by SQLiteStore/App initialization.
/// Schema 11 is enabled ONLY on an explicit temporary rehearsal work copy.
/// Production migration/startup wiring requires a separate 8B.3B review.
@_spi(ImportedMigration) public final class ImportedMigrationStore {
    private let connection: SQLiteConnection
    public init(temporaryWorkCopy url: URL) throws {
        let resolved = url.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        guard resolved.lastPathComponent == "work.sqlite3",
              resolved.deletingLastPathComponent().deletingLastPathComponent() == root,
              resolved.deletingLastPathComponent().lastPathComponent.hasPrefix("OKVideoMac-8B3A-"),
              FileManager.default.fileExists(atPath: resolved.path) else { throw ImportedMigrationStoreError.unsafePath }
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.deletingLastPathComponent().path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw ImportedMigrationStoreError.unsafePath }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: resolved.path + suffix) {
            let file = try FileManager.default.attributesOfItem(atPath: resolved.path + suffix)
            guard file[.type] as? FileAttributeType == .typeRegular,
                  (file[.referenceCount] as? NSNumber)?.intValue == 1 else { throw ImportedMigrationStoreError.unsafePath }
        }
        connection = try SQLiteConnection(url: resolved)
        do {
            // Protect all new sidecars as well as the main DB. No change to
            // production DB paths, secure_delete or SQLiteStore's schema guard.
            try connection.execute("PRAGMA foreign_keys=ON")
            try connection.query("PRAGMA secure_delete=ON") { _ in }
            guard try connection.scalarInt("PRAGMA foreign_keys") == 1 else { throw ImportedMigrationStoreError.corruption }
            let schema = try connection.scalarInt("PRAGMA user_version")
            guard [9, 10, 11, 13].contains(schema) else { throw ImportedMigrationStoreError.unsupportedVersion }
            if schema < 11 || schema == 13 {
                try connection.transaction {
                    if schema == 9 { try ImportedIdentityRegistrySQL.createSchema(connection) }
                    try Self.createAuthoritySchema(connection)
                    try connection.execute("PRAGMA user_version=11")
                    let validation = ImportedMigrationTransaction(connection)
                    defer { validation.active = false }
                    _ = try validation.snapshot()
                }
            }
            for suffix in ["", "-wal", "-shm"] {
                let path = resolved.path + suffix
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
            }
            _ = try read()
        } catch { connection.close(); throw error }
    }
    public func close() { connection.close() }
    public func read() throws -> ImportedMigrationStoreSnapshot { try transaction { try $0.snapshot() } }
    public func transaction<T>(_ body: (ImportedMigrationTransaction) throws -> T) throws -> T {
        try connection.transaction {
            let transaction = ImportedMigrationTransaction(connection)
            defer { transaction.active = false }
            return try body(transaction)
        }
    }
    static func createAuthoritySchema(_ c: SQLiteConnection) throws {
        try c.execute("""
            CREATE TABLE imported_reference_claims (
                source_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('favorite','hidden')),
                legacy_reference TEXT NOT NULL, local_id TEXT NOT NULL,
                PRIMARY KEY(source_id,kind,legacy_reference),
                FOREIGN KEY(source_id,local_id) REFERENCES imported_channel_identities(source_id,local_id) ON DELETE RESTRICT ON UPDATE RESTRICT
            ) WITHOUT ROWID
            """)
        try c.execute("CREATE INDEX imported_claim_identity ON imported_reference_claims(source_id,local_id,kind)")
        try c.execute("""
            CREATE TRIGGER imported_claim_immutable BEFORE UPDATE ON imported_reference_claims
            WHEN NEW.source_id != OLD.source_id OR NEW.kind != OLD.kind OR NEW.legacy_reference != OLD.legacy_reference OR NEW.local_id != OLD.local_id
            BEGIN SELECT RAISE(ABORT,'immutable claim'); END
            """)
        try c.execute("""
            CREATE TABLE imported_stable_references (
                source_id TEXT NOT NULL, local_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('favorite','hidden')),
                PRIMARY KEY(source_id,local_id,kind),
                FOREIGN KEY(source_id,local_id) REFERENCES imported_channel_identities(source_id,local_id) ON DELETE RESTRICT ON UPDATE RESTRICT
            ) WITHOUT ROWID
            """)
        try c.execute("CREATE TABLE imported_migration_batches(id TEXT PRIMARY KEY NOT NULL, version INTEGER NOT NULL CHECK(version=1), proof BLOB NOT NULL)")
        try c.execute("CREATE TABLE imported_reference_holds(kind TEXT NOT NULL CHECK(kind IN ('favorite','hidden')), legacy_reference TEXT NOT NULL, PRIMARY KEY(kind,legacy_reference)) WITHOUT ROWID")
    }
}

/// Borrowed transaction capability. Escaping the closure does not permit later
/// writes. The production Registry SQL and this authority SQL share ONE handle.
@_spi(ImportedMigration) public final class ImportedMigrationTransaction {
    var active = true
    private let c: SQLiteConnection
    init(_ connection: SQLiteConnection) { c = connection }
    private func check() throws { guard active else { throw ImportedMigrationStoreError.expiredTransaction } }
    public func snapshot() throws -> ImportedMigrationStoreSnapshot {
        try check()
        let schema = try c.scalarInt("PRAGMA user_version")
        guard [11, 12].contains(schema) else { throw ImportedMigrationStoreError.unsupportedVersion }
        let history = try ImportedSourceLifecycleSQL.history(c)
        var brokenFK = false
        try c.query("PRAGMA foreign_key_check") { _ in brokenFK = true }
        guard !brokenFK else { throw ImportedMigrationStoreError.corruption }
        var sources: [StoredLiveSource] = []
        try c.query("SELECT id,name,source_kind,source_value,base_url,raw_data,updated_at FROM live_sources" + (schema >= 12 ? " WHERE retired_at IS NULL" : "") + " ORDER BY id") { row in
            guard let id = c.text(row, 0).flatMap(UUID.init(uuidString:)), let name = c.text(row, 1),
                  let kind = c.text(row, 2).flatMap(StoredLiveSourceKind.init(rawValue:)), let data = c.data(row, 5) else { throw ImportedMigrationStoreError.corruption }
            let base = c.text(row, 4)
            guard base == nil || base.flatMap(URL.init(string:)) != nil else { throw ImportedMigrationStoreError.corruption }
            sources.append(StoredLiveSource(id: id, name: name, sourceKind: kind, sourceValue: c.text(row, 3),
                baseURL: base.flatMap(URL.init(string:)), rawData: data, updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 6))))
        }
        var registry: [ImportedChannelRegistryRecord] = []
        try c.query("SELECT DISTINCT source_id FROM imported_channel_identities ORDER BY source_id") { row in
            guard let id = c.text(row, 0).flatMap(UUID.init(uuidString:)) else { throw ImportedMigrationStoreError.corruption }
            registry += try ImportedIdentityRegistrySQL.list(.imported(id), lifecycle: nil, connection: c)
        }
        guard registry.count == (try c.scalarInt("SELECT count(*) FROM imported_channel_identities")) else { throw ImportedMigrationStoreError.corruption }
        // Validate the HISTORICAL universe before projecting active catalogs.
        // An absent parent is corruption; a retained retired parent is not.
        for record in registry where schema >= 12 {
            guard case .imported(let id) = record.identity.source,
                  let parent = history.first(where: { $0.id == id }),
                  parent.retiredAt == nil || record.lifecycle == .retired else { throw ImportedMigrationStoreError.corruption }
        }
        func refs(_ key: String) throws -> [ImportedLegacyReference] {
            var result: [ImportedLegacyReference] = []
            try c.query("SELECT value FROM settings WHERE key=?", bindings: [.text(key)]) { row in
                guard let data = c.data(row, 0) else { throw ImportedMigrationStoreError.corruption }
                result = try JSONDecoder().decode([String].self, from: data).map(ImportedLegacyReference.init)
            }
            return result
        }
        func identity(_ row: OpaquePointer, _ sourceColumn: Int32, _ localColumn: Int32) throws -> ImportedLiveChannelIdentity {
            guard let sourceText = c.text(row, sourceColumn), let source = UUID(uuidString: sourceText),
                  let localText = c.text(row, localColumn), let local = UUID(uuidString: localText),
                  sourceText == source.uuidString.lowercased(), localText == local.uuidString.lowercased() else { throw ImportedMigrationStoreError.corruption }
            return try ImportedLiveChannelIdentity(source: .imported(source), localID: local)
        }
        var claims: [ImportedReferenceClaim] = [], stable: [ImportedStableReferenceState] = [], batches: [ImportedMigrationBatch] = []
        try c.query("SELECT source_id,local_id,kind,legacy_reference FROM imported_reference_claims ORDER BY source_id,kind,legacy_reference") { row in
            let id = try identity(row, 0, 1)
            guard case .imported(let source) = id.source, let kind = c.text(row, 2).flatMap(MigrationReferenceKind.init(rawValue:)),
                  let token = c.text(row, 3) else { throw ImportedMigrationStoreError.corruption }
            claims.append(try ImportedReferenceClaim(sourceID: source, kind: kind, legacyToken: token, identity: id))
        }
        try c.query("SELECT source_id,local_id,kind FROM imported_stable_references ORDER BY source_id,local_id,kind") { row in
            guard let kind = c.text(row, 2).flatMap(MigrationReferenceKind.init(rawValue:)) else { throw ImportedMigrationStoreError.corruption }
            stable.append(ImportedStableReferenceState(identity: try identity(row, 0, 1), kind: kind))
        }
        let known = Set(registry.map(\.identity))
        guard claims.allSatisfy({ known.contains($0.identity) }),
              stable.allSatisfy({ state in claims.contains { $0.identity == state.identity && $0.kind == state.kind } }) else { throw ImportedMigrationStoreError.corruption }
        try c.query("SELECT id,version,proof FROM imported_migration_batches ORDER BY id") { row in
            guard sqlite3_column_int(row, 1) == 1, let data = c.data(row, 2), data.count <= 8 * 1024 * 1024,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["id", "version", "identities", "claims", "holds"] else { throw ImportedMigrationStoreError.corruption }
            let batch = try JSONDecoder().decode(ImportedMigrationBatch.self, from: data)
            guard batch.version == 1, batch.id.uuidString.lowercased() == c.text(row, 0),
                  batch.identities.allSatisfy({ known.contains($0) }), batch.claims.allSatisfy({ claims.contains($0) }),
                  Set(batch.identities).count == batch.identities.count else { throw ImportedMigrationStoreError.corruption }
            batches.append(batch)
        }
        var holds: [ImportedReferenceHold] = []
        try c.query("SELECT kind,legacy_reference FROM imported_reference_holds ORDER BY kind,legacy_reference") { row in
            guard let kind = c.text(row, 0).flatMap(MigrationReferenceKind.init(rawValue:)), let token = c.text(row, 1) else { throw ImportedMigrationStoreError.corruption }
            holds.append(ImportedReferenceHold(kind: kind, legacyToken: token))
        }
        guard !holds.contains(where: { hold in claims.contains { $0.kind == hold.kind && $0.legacyToken == hold.legacyToken } }) else { throw ImportedMigrationStoreError.corruption }
        guard batches.allSatisfy({ $0.holds.allSatisfy { holds.contains($0) } }) else { throw ImportedMigrationStoreError.corruption }
        var snapshot = try ImportedMigrationStoreSnapshot(sources: sources, registry: registry, favorites: refs("live.favoriteChannels"),
            hidden: refs("live.deletedChannels"), claims: claims, stable: stable, holds: holds, batches: batches)
        snapshot.sourceHistory = history; snapshot.schemaVersion = schema
        snapshot.retirementBlocks = try ImportedSourceLifecycleSQL.blocks(c)
        return snapshot
    }
    public func insertIdentity(_ record: ImportedChannelRegistryRecord) throws {
        try check()
        if case .imported(let id) = record.identity.source { try ImportedSourceLifecycleSQL.requireActive(id, c) }
        guard try ImportedIdentityRegistrySQL.fetch(record.identity, connection: c) == nil else { throw ImportedMigrationStoreError.corruption }
        try ImportedIdentityRegistrySQL.apply(.upsert(record), connection: c)
    }
    @discardableResult public func claim(_ claim: ImportedReferenceClaim) throws -> Bool {
        try check()
        try ImportedSourceLifecycleSQL.requireActive(claim.sourceID, c)
        guard claim.identity.source == .imported(claim.sourceID), claim.legacyToken.utf8.count <= 8192,
              !claim.legacyToken.contains("://"), LogRedactor.text(claim.legacyToken) == claim.legacyToken else { throw ImportedMigrationStoreError.corruption }
        let source = claim.sourceID.uuidString.lowercased(), local = claim.identity.localID.uuidString.lowercased()
        var existing: String?
        try c.query("SELECT local_id FROM imported_reference_claims WHERE source_id=? AND kind=? AND legacy_reference=?",
            bindings: [.text(source), .text(claim.kind.rawValue), .text(claim.legacyToken)]) { existing = c.text($0, 0) }
        if let existing {
            guard existing == local else { throw ImportedMigrationStoreError.corruption }; return false
        }
        guard !(try ImportedSourceLifecycleSQL.blocks(c)).contains(where: { $0.denies(claim.sourceID, kind: claim.kind, token: claim.legacyToken) }) else { throw ImportedExecutionError.blocked }
        try c.execute("INSERT INTO imported_reference_claims VALUES (?,?,?,?)", bindings: [.text(source), .text(claim.kind.rawValue), .text(claim.legacyToken), .text(local)])
        return true
    }
    public func setStable(_ state: ImportedStableReferenceState, present: Bool) throws {
        try check()
        guard case .imported(let id) = state.identity.source else { throw ImportedExecutionError.blocked }
        try ImportedSourceLifecycleSQL.requireActive(id, c)
        let source = try ImportedIdentityRegistrySQL.sourceUUID(state.identity.source), local = state.identity.localID.uuidString.lowercased()
        var claimed = false
        try c.query("SELECT 1 FROM imported_reference_claims WHERE source_id=? AND local_id=? AND kind=? LIMIT 1",
            bindings: [.text(source), .text(local), .text(state.kind.rawValue)]) { _ in claimed = true }
        guard claimed else { throw ImportedMigrationStoreError.corruption }
        if present {
            try c.execute("INSERT INTO imported_stable_references VALUES (?,?,?) ON CONFLICT DO NOTHING", bindings: [.text(source), .text(local), .text(state.kind.rawValue)])
        } else {
            try c.execute("DELETE FROM imported_stable_references WHERE source_id=? AND local_id=? AND kind=?", bindings: [.text(source), .text(local), .text(state.kind.rawValue)])
        }
    }
    public func recordBatch(_ batch: ImportedMigrationBatch) throws {
        try check()
        for identity in batch.identities + batch.claims.map(\.identity) {
            guard case .imported(let id) = identity.source else { throw ImportedExecutionError.blocked }
            try ImportedSourceLifecycleSQL.requireActive(id, c)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try c.execute("INSERT INTO imported_migration_batches VALUES (?,?,?)", bindings: [.text(batch.id.uuidString.lowercased()), .integer(1), .blob(try encoder.encode(batch))])
        _ = try snapshot() // Validate proof before COMMIT, never use it as identity authority.
    }
    public func preserveUnprovenReference(_ hold: ImportedReferenceHold, sourceID: UUID? = nil) throws {
        try check()
        if try c.scalarInt("PRAGMA user_version") >= 12 {
            guard let sourceID else { throw ImportedExecutionError.blocked }
            try ImportedSourceLifecycleSQL.requireActive(sourceID, c)
        }
        guard hold.legacyToken.utf8.count <= 8192, !hold.legacyToken.contains("://"),
              LogRedactor.text(hold.legacyToken) == hold.legacyToken else { throw ImportedMigrationStoreError.corruption }
        try c.execute("INSERT INTO imported_reference_holds VALUES (?,?) ON CONFLICT DO NOTHING",
            bindings: [.text(hold.kind.rawValue), .text(hold.legacyToken)])
    }
    public func setLegacy(sourceID: UUID, kind: MigrationReferenceKind, token: String, present: Bool) throws {
        try check()
        try ImportedSourceLifecycleSQL.requireActive(sourceID, c)
        let snapshot = try snapshot()
        guard !snapshot.retirementBlocks.contains(where: { $0.denies(sourceID, kind: kind, token: token) }) else { throw ImportedExecutionError.blocked }
        guard !snapshot.claims.contains(where: { $0.kind == kind && $0.legacyToken == token }) else { throw ImportedMigrationStoreError.corruption }
        let key = kind == .hidden ? "live.deletedChannels" : "live.favoriteChannels"
        var refs = Set((kind == .hidden ? snapshot.hidden : snapshot.favorites).map(\.rawValue))
        if present { refs.insert(token) } else { refs.remove(token) }
        try c.execute("INSERT INTO settings(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            bindings: [.text(key), .blob(try JSONEncoder().encode(refs.sorted()))])
    }
}
