import Foundation
import CSQLite
import OKVideoCore
@_spi(ImportedMigration) import OKVideoPersistence

/// Explicit commands on private temporary copies. Invoking each cycle in a new
/// CLI process proves restart behavior without persisting a plan or HMAC key.
public enum ImportedMigrationRehearsal {
    static func directory(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == root, resolved.lastPathComponent.hasPrefix("OKVideoMac-8B3A-"),
              (try FileManager.default.attributesOfItem(atPath: resolved.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw SnapshotError.unsafeFile }
        return resolved
    }
    public static func copy(snapshot: URL, into output: URL) throws {
        let source = snapshot.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        guard source.deletingLastPathComponent().deletingLastPathComponent() == root,
              source.deletingLastPathComponent().lastPathComponent.hasPrefix("OKVideoMac-8B2-DryRun-"),
              ["snapshot.sqlite3", "staged.sqlite3"].contains(source.lastPathComponent) else { throw SnapshotError.unsafeFile }
        let output = try directory(output)
        let baseline = output.appendingPathComponent("baseline.sqlite3"), work = output.appendingPathComponent("work.sqlite3")
        try backup(source: source, destination: baseline)
        try backup(source: baseline, destination: work)
        guard try businessContent(baseline) == businessContent(work) else { throw SnapshotError.invalidDatabase }
    }
    private static func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw SnapshotError.sqliteFailure
        }
        return db
    }
    static func backup(source: URL, destination: URL) throws {
        try QuiescentDatabaseSnapshot.writePrivate(Data(), to: destination) // O_EXCL + 0600
        let from = try open(source, flags: SQLITE_OPEN_READONLY); defer { sqlite3_close(from) }
        let to = try open(destination, flags: SQLITE_OPEN_READWRITE); defer { sqlite3_close(to) }
        guard let backup = sqlite3_backup_init(to, "main", from, "main") else { throw SnapshotError.sqliteFailure }
        let status = sqlite3_backup_step(backup, -1), finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finish == SQLITE_OK else { throw SnapshotError.sqliteFailure }
    }
    private static func schema(_ url: URL) throws -> Int {
        let db = try open(url, flags: SQLITE_OPEN_READONLY); defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, let statement else { throw SnapshotError.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SnapshotError.sqliteFailure }
        return Int(sqlite3_column_int(statement, 0))
    }
    /// Only compared in memory; never saved/logged. Covers every column and row,
    /// including original raw_data/settings/history, not merely counts.
    static func businessContent(_ url: URL) throws -> Data {
        let resolved = url.resolvingSymlinksInPath()
        _ = try directory(resolved.deletingLastPathComponent())
        guard ["baseline.sqlite3", "work.sqlite3"].contains(resolved.lastPathComponent) else { throw SnapshotError.unsafeFile }
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw SnapshotError.unsafeFile }
        let db = try open(resolved, flags: SQLITE_OPEN_READONLY); defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw SnapshotError.sqliteFailure }
        var tables: [String: [Data]] = [:]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        struct Field: Encodable { let type: Int32; let value: Data? }
        for table in ["configurations", "favorites", "history", "settings", "live_sources"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT * FROM \(table)", -1, &statement, nil) == SQLITE_OK, let statement else { throw SnapshotError.sqliteFailure }
            defer { sqlite3_finalize(statement) }
            var rows: [Data] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw SnapshotError.sqliteFailure }
                var fields: [Field] = []
                for column in 0..<sqlite3_column_count(statement) {
                    let type = sqlite3_column_type(statement, column)
                    let data = sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, column))) }
                    fields.append(Field(type: type, value: data))
                }
                rows.append(try encoder.encode(fields))
            }
            tables[table] = rows.sorted { $0.lexicographicallyPrecedes($1) }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw SnapshotError.sqliteFailure }
        return try encoder.encode(tables)
    }
    public static func cycle(in output: URL, label: String, unhide: Bool = false) throws {
        guard !label.isEmpty, label.utf8.count <= 40, label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw SnapshotError.unsafeFile }
        let output = try directory(output), work = output.appendingPathComponent("work.sqlite3"), baseline = output.appendingPathComponent("baseline.sqlite3")
        let beforeBusiness = try businessContent(baseline)
        guard try businessContent(work) == beforeBusiness else { throw SnapshotError.invalidDatabase }
        let workSchemaBefore = try schema(work)
        let store = try ImportedMigrationStore(temporaryWorkCopy: work); defer { store.close() }
        let session = ImportedMigrationExecutionSession()
        let before = try store.read(), plan = try session.prepare(before)
        try QuiescentDatabaseSnapshot.writePrivate(plan.json(), to: output.appendingPathComponent("\(label)-plan.json"))
        var result: ImportedExecutionResult?
        if unhide {
            var targets: [(UUID, LiveChannel)] = []
            for source in before.sources {
                for channel in try LiveSourceParser().parse(source.rawData, baseURL: source.baseURL).groups.flatMap(\.channels) {
                    if case .stable = session.authority(plan, sourceID: source.id, channel: channel, kind: .hidden),
                       session.value(plan, sourceID: source.id, channel: channel, kind: .hidden) == true { targets.append((source.id, channel)) }
                }
            }
            // Choose one already proven stable target to simulate a user action;
            // this sorting is NOT used to resolve identity ambiguity.
            targets.sort { [$0.0.uuidString, $0.1.groupName, $0.1.name].lexicographicallyPrecedes([$1.0.uuidString, $1.1.groupName, $1.1.name]) }
            guard let target = targets.first else { throw ImportedExecutionError.blocked }
            try session.write(plan, store: store, sourceID: target.0, channel: target.1, kind: .hidden, present: false)
        } else { result = try session.execute(plan, store: store) }
        let after = try store.read()
        guard try businessContent(work) == beforeBusiness else { throw SnapshotError.invalidDatabase }
        let replanned = try ImportedMigrationExecutionSession().prepare(after)
        try QuiescentDatabaseSnapshot.writePrivate(replanned.json(), to: output.appendingPathComponent("\(label)-after.json"))
        struct ClaimState: Encodable { let identity: ImportedLiveChannelIdentity; let kind: MigrationReferenceKind; let present: Bool }
        struct Report: Encodable {
            let processID: Int32; let label: String; let realDatabaseOpened = false
            let businessContentUnchanged = true; let baselineSchema: Int; let schemaBefore: Int; let schemaAfter = 11
            let execution: ImportedExecutionResult?; let simulatedUnhide: Bool
            let registryIdentities: [ImportedLiveChannelIdentity]; let claims: [ClaimState]; let batches: Int; let holds: Int
        }
        let report = Report(processID: ProcessInfo.processInfo.processIdentifier, label: label, baselineSchema: try schema(baseline), schemaBefore: workSchemaBefore,
            execution: result, simulatedUnhide: unhide,
            registryIdentities: after.registry.map(\.identity).sorted { $0.localID.uuidString < $1.localID.uuidString },
            claims: after.claims.map { claim in ClaimState(identity: claim.identity, kind: claim.kind,
                present: after.stable.contains { $0.identity == claim.identity && $0.kind == claim.kind }) },
            batches: after.batches.count, holds: after.holds.count)
        try ParserOutputEquivalence.write(report, to: output.appendingPathComponent("\(label)-result.json"))
        print("Temporary rehearsal \(label): Registry \(after.registry.count), claims \(after.claims.count), stable \(after.stable.count). Business content unchanged.")
    }
}
