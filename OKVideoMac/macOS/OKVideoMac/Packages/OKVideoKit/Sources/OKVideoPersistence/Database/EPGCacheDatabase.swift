import Foundation
import CSQLite

// Private to the independent EPG cache. Do not expose SQL text, paths, or bound
// values in errors, and do not change the user-data SQLiteConnection contract.
enum EPGCacheError: Error, Equatable {
    case closed, unsafeDirectory, alreadyOpen, incompatibleVersion(Int)
    case foreignDatabase, invalidInput, budgetExceeded, invalidHandle
    case superseded, invalidState, validationFailed, importInProgress, sqlite(Int32), io(Int32)
}

enum EPGCacheDatabaseAccess {
    case writer
    case existingReadWrite
}

private final class EPGCacheProgressBox {
    let callback: () -> Bool
    init(_ callback: @escaping () -> Bool) { self.callback = callback }
}

final class EPGCacheDatabase {
    private var handle: OpaquePointer?
    private var progressBox: EPGCacheProgressBox?

    init(url: URL, access: EPGCacheDatabaseAccess = .writer) throws {
        let flags: Int32
        switch access {
        case .writer: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        case .existingReadWrite: flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        }
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw EPGCacheError.sqlite(code)
        }
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 250)
    }

    deinit { close() }
    func close() {
        clearProgressHandler()
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    func statement(_ sql: String) throws -> EPGCacheStatement {
        guard let handle else { throw EPGCacheError.closed }
        return try EPGCacheStatement(database: handle, sql: sql)
    }

    func execute(_ sql: String, _ values: [SQLiteBinding] = []) throws {
        let statement = try self.statement(sql)
        try statement.bind(values)
        while try statement.step() {} // PRAGMA setters can also return rows.
    }

    func integer(_ sql: String, _ values: [SQLiteBinding] = []) throws -> Int64 {
        let statement = try self.statement(sql)
        try statement.bind(values)
        return try statement.step() ? statement.integer(0) : 0
    }

    func string(_ sql: String, _ values: [SQLiteBinding] = []) throws -> String? {
        let statement = try self.statement(sql)
        try statement.bind(values)
        return try statement.step() ? statement.text(0) : nil
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }

    func installProgressHandler(stepInterval: Int32, callback: @escaping () -> Bool) throws {
        guard let handle else { throw EPGCacheError.closed }
        let box = EPGCacheProgressBox(callback)
        progressBox = box
        sqlite3_progress_handler(handle, stepInterval, { context in
            guard let context else { return 0 }
            let box = Unmanaged<EPGCacheProgressBox>.fromOpaque(context).takeUnretainedValue()
            return box.callback() ? 1 : 0
        }, Unmanaged.passUnretained(box).toOpaque())
    }

    func clearProgressHandler() {
        if let handle { sqlite3_progress_handler(handle, 0, nil, nil) }
        progressBox = nil
    }

    func interrupt() {
        if let handle { sqlite3_interrupt(handle) }
    }

    func checkpoint() throws {
        guard let handle else { throw EPGCacheError.closed }
        let code = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
        guard code == SQLITE_OK else { throw EPGCacheError.sqlite(code) }
    }
}

final class EPGCacheStatement {
    private let statement: OpaquePointer
    init(database: OpaquePointer, sql: String) throws {
        var pointer: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &pointer, nil)
        guard code == SQLITE_OK, let pointer else { throw EPGCacheError.sqlite(code) }
        statement = pointer
    }
    deinit { sqlite3_finalize(statement) }
    func reset() throws {
        let reset = sqlite3_reset(statement)
        let clear = sqlite3_clear_bindings(statement)
        guard reset == SQLITE_OK else { throw EPGCacheError.sqlite(reset) }
        guard clear == SQLITE_OK else { throw EPGCacheError.sqlite(clear) }
    }
    func bind(_ values: [SQLiteBinding]) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .integer(let v): code = sqlite3_bind_int64(statement, index, v)
            case .double(let v): code = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                // Explicit UTF-8 length preserves embedded NUL rather than
                // silently truncating stored text and breaking byte accounting.
                code = v.withCString { sqlite3_bind_text(statement, index, $0, Int32(v.utf8.count), transient) }
            case .blob(let v):
                code = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), transient) }
            }
            guard code == SQLITE_OK else { throw EPGCacheError.sqlite(code) }
        }
    }
    func step() throws -> Bool {
        let code = sqlite3_step(statement)
        if code == SQLITE_ROW { return true }
        guard code == SQLITE_DONE else { throw EPGCacheError.sqlite(code) }
        return false
    }
    func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func number(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes,
            count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    func status(_ operation: Int32, reset: Bool = false) -> Int32 {
        sqlite3_stmt_status(statement, operation, reset ? 1 : 0)
    }
}
