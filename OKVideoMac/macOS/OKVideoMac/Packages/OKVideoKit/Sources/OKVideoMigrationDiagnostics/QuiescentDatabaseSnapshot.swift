import Foundation
import CryptoKit
import Darwin
import CSQLite

public enum SnapshotError: Error {
    case applicationInUse, unsafeFile, sourceChanged, sqliteFailure, invalidDatabase, invalidSettings
}

public struct SnapshotFileAudit: Codable, Equatable {
    public let exists: Bool
    public let bytes: Int
    public let sha256: String?
}

public struct DryRunDatabaseSnapshot {
    public let directory: URL
    public let database: URL
    public let schemaVersion: Int
    public let tableCounts: [String: Int]
    public let sourceFiles: [String: SnapshotFileAudit]
    let temporaryWorkspace: SnapshotTemporaryWorkspace

    // Internal, explicit cleanup for tests. The public path is not deletion authority.
    func removeTemporaryFiles() throws { try temporaryWorkspace.remove() }
}

/// Developer-only OFFLINE snapshot gate. No SQLite handle is ever opened on the
/// source. The existing App instance lock is opened O_RDONLY (no create/chmod),
/// held while copying and verifying ALL main/WAL/SHM bytes. A running App fails
/// closed. Caller must first check that no other database clients are running.
///
/// The staged main+WAL pair is recovered only in private temporary storage. SHM is
/// deliberately rebuilt there, never edited at the original path. SQLite's backup
/// API then produces the consistent standalone destination. This is not an online
/// backup of an active source and must never be advertised as one.
public enum QuiescentDatabaseSnapshot {
    public static func create(database: URL, existingAppLock: URL) throws -> DryRunDatabaseSnapshot {
        let databaseDirectory = database.deletingLastPathComponent()
        let expectedLock = databaseDirectory.deletingLastPathComponent().appendingPathComponent(".instance.lock")
        guard databaseDirectory.lastPathComponent == "Database",
              existingAppLock.standardizedFileURL == expectedLock.standardizedFileURL else { throw SnapshotError.unsafeFile }
        let fd = Darwin.open(existingAppLock.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SnapshotError.unsafeFile }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SnapshotError.unsafeFile }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SnapshotError.applicationInUse }
        defer { flock(fd, LOCK_UN) }

        let original = try images(database)
        guard let main = original["main"], main.count >= 100,
              main.prefix(16) == Data("SQLite format 3\0".utf8) else { throw SnapshotError.invalidDatabase }
        // Holding the App lease prevents startup/recovery, but we also reject any
        // externally modified bytes instead of trusting one file's mtime alone.
        guard try images(database) == original else { throw SnapshotError.sourceChanged }
        let workspace = try SnapshotTemporaryWorkspace.create()
        let directory = workspace.directory
        let staged = directory.appendingPathComponent("staged.sqlite3")
        try writePrivate(main, to: staged)
        if let wal = original["wal"] { try writePrivate(wal, to: URL(fileURLWithPath: staged.path + "-wal")) }
        guard try images(database) == original else { throw SnapshotError.sourceChanged }
        let destination = directory.appendingPathComponent("snapshot.sqlite3")
        try backup(staged: staged, destination: destination)
        let state = try inspectTemporary(database: destination)
        guard try images(database) == original else { throw SnapshotError.sourceChanged }
        return DryRunDatabaseSnapshot(directory: directory, database: destination,
            schemaVersion: state.schema, tableCounts: state.counts, sourceFiles: audits(original),
            temporaryWorkspace: workspace)
    }

    public static func audit(database: URL) throws -> [String: SnapshotFileAudit] { audits(try images(database)) }

    public static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SnapshotError.unsafeFile }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw SnapshotError.unsafeFile }
                offset += n
            }
        }
    }

    /// Only temporary paths produced by create() are accepted by the harness.
    /// This function is internal, so normal App code cannot use it as a DB reader.
    static func inspectTemporary(database: URL) throws -> (schema: Int, counts: [String: Int]) {
        let db = try open(database, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(db) }
        guard try scalarText(db, "PRAGMA quick_check") == "ok" else { throw SnapshotError.invalidDatabase }
        let version = Int(try scalarText(db, "PRAGMA user_version")) ?? -1
        var counts: [String: Int] = [:]
        for table in ["live_sources", "settings", "history", "favorites", "imported_channel_identities"] {
            let exists = try scalarText(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='\(table)'") == "1"
            if exists { counts[table] = Int(try scalarText(db, "SELECT count(*) FROM \(table)")) ?? -1 }
        }
        return (version, counts)
    }

    private static func images(_ database: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for (key, suffix) in [("main", ""), ("wal", "-wal"), ("shm", "-shm")] {
            let fd = Darwin.open(database.path + suffix, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 && errno == ENOENT && key != "main" { continue }
            guard fd >= 0 else { throw SnapshotError.unsafeFile }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, info.st_size <= 512 * 1024 * 1024 else { throw SnapshotError.unsafeFile }
            var data = Data(count: Int(info.st_size))
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw SnapshotError.sourceChanged }
                    offset += n
                }
            }
            var after = stat()
            guard fstat(fd, &after) == 0, after.st_size == info.st_size,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw SnapshotError.sourceChanged }
            result[key] = data
        }
        return result
    }

    private static func audits(_ images: [String: Data]) -> [String: SnapshotFileAudit] {
        Dictionary(uniqueKeysWithValues: ["main", "wal", "shm"].map { key in
            let value = images[key]
            return (key, SnapshotFileAudit(exists: value != nil, bytes: value?.count ?? 0,
                sha256: value.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }))
        })
    }

    private static func backup(staged: URL, destination: URL) throws {
        let source = try open(staged, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(source) }
        try writePrivate(Data(), to: destination)
        let target = try open(destination, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else { throw SnapshotError.sqliteFailure }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw SnapshotError.sqliteFailure }
    }
    private static func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close(db) }; throw SnapshotError.sqliteFailure
        }
        return handle
    }
    private static func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SnapshotError.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw SnapshotError.sqliteFailure }
        return String(cString: text)
    }
}
