import Foundation
import Darwin

@_spi(XMLTVStreaming) public enum XMLTVFileError: Error, Equatable {
    case unsafeRoot, ownershipMismatch, inactiveOwner, invalidState, invalidBudget
    case byteLimit, noWriteProgress
    case setupCleanupIncomplete
    case system(Int32)
}

/// Developer-only file ownership boundary. No network, parser, database or GC.
/// Methods are serialized. Holding a reference is NOT authority after transfer.
@_spi(XMLTVStreaming) public final class XMLTVStagingFile: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let storage: XMLTVFileStorage
    private let token: UUID
    private let cancellation: XMLTVFileCancellation
    private init(storage: XMLTVFileStorage, token: UUID, cancellation: XMLTVFileCancellation) {
        self.storage = storage; self.token = token; self.cancellation = cancellation
    }

    /// The caller's existing root must be a private canonical 9B disposable root.
    /// Only a newly-created child directory/file is owned; never the caller root.
    public static func create(in rootPath: String, maximumBytes: Int = 32 * 1_024 * 1_024) throws -> XMLTVStagingFile {
        try create(in: rootPath, maximumBytes: maximumBytes, write: XMLTVFileStorage.systemWrite)
    }
    // Inject only the lowest write operation. Return the actual byte count or
    // throw POSIXError; the production loop handles partial progress and EINTR.
    static func create(in rootPath: String, maximumBytes: Int = 32 * 1_024 * 1_024,
                       directoryName: String = "xmltv-" + UUID().uuidString,
                       write: @escaping XMLTVWriteOperation) throws -> XMLTVStagingFile {
        let token = UUID(), cancellation = XMLTVFileCancellation()
        let storage = try XMLTVFileStorage(rootPath: rootPath, limit: maximumBytes, token: token,
            directoryName: directoryName, cancellation: cancellation, write: write)
        return XMLTVStagingFile(storage: storage, token: token, cancellation: cancellation)
    }
    public func write(_ data: Data) throws { try storage.append(data, owner: token) }
    /// Seals writing, opens and verifies a read-only descriptor, and atomically
    /// transfers logical authority. The old owner can no longer write/transfer/delete.
    public func finishAndTransfer() throws -> XMLTVStagedFile {
        let next = try storage.transfer(owner: token)
        return XMLTVStagedFile(storage: storage, token: next.0, cancellation: next.1)
    }
    /// Non-blocking cooperative cancellation, including non-Swift-Task callers.
    /// Explicit release is still required if there is no operation in flight.
    public func requestCancellation() { cancellation.request() }
    public func release() throws { try storage.release(owner: token) }
    /// A cleanup failure never masks the original write/cancellation failure.
    /// Explicit release rethrows this issue, with no repeated destructive action.
    public var cleanupIssue: XMLTVFileError? { storage.cleanupIssue }
    public var description: String { "XMLTVStagingFile" }
    public var debugDescription: String { description }
    deinit { try? storage.release(owner: token) } // fallback, NOT the normal lifecycle
    var testReceipt: XMLTVFileTestReceipt { storage.testReceipt }
}

@_spi(XMLTVStreaming) public final class XMLTVStagedFile: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let storage: XMLTVFileStorage
    private let token: UUID
    private let cancellation: XMLTVFileCancellation
    fileprivate init(storage: XMLTVFileStorage, token: UUID, cancellation: XMLTVFileCancellation) {
        self.storage = storage; self.token = token; self.cancellation = cancellation
    }
    /// Bounded read only. No bare URL/fd escapes; no parser wiring in Change A.
    public func read(maximumBytes: Int = 64 * 1_024) throws -> Data {
        try storage.read(maximumBytes: maximumBytes, owner: token)
    }
    public func release() throws { try storage.release(owner: token) }
    public func requestCancellation() { cancellation.request() }
    public var cleanupIssue: XMLTVFileError? { storage.cleanupIssue }
    public var description: String { "XMLTVStagedFile" }
    public var debugDescription: String { description }
    deinit { try? storage.release(owner: token) }
}

typealias XMLTVWriteOperation = (Int32, UnsafeRawPointer, Int) throws -> Int

/// Internal test inspection only; paths/descriptors never enter public diagnostics.
struct XMLTVFileTestReceipt {
    let rootFD: Int32, directoryFD: Int32, fileFD: Int32
    let directoryName: String
}

private struct XMLTVFileIdentity {
    let device: dev_t, inode: ino_t
    init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    func matches(_ info: stat) -> Bool { info.st_dev == device && info.st_ino == inode }
}

/// One flag per owner, not a shared flag carried across ownership transfer.
/// A separate lock lets cancellation be observed inside the serialized write
/// loop without waiting behind that loop. It cannot interrupt a blocked syscall.
private final class XMLTVFileCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func request() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        try Task.checkCancellation()
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

private final class XMLTVFileStorage {
    private enum Phase { case writing, reading, released }
    private let lock = NSLock()
    private var owner: UUID
    private var phase = Phase.writing
    private var rootFD: Int32 = -1, directoryFD: Int32 = -1, fileFD: Int32 = -1
    private var rootIdentity: XMLTVFileIdentity?, directoryIdentity: XMLTVFileIdentity?, fileIdentity: XMLTVFileIdentity?
    private let directoryName: String
    private static let fileName = "payload"
    private let limit: Int
    private let writeOperation: XMLTVWriteOperation
    private var byteCount = 0
    private var releaseError: XMLTVFileError?
    private var createdDirectory = false
    private var cancellation: XMLTVFileCancellation

    static func systemWrite(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) throws -> Int {
        let result = Darwin.write(fd, bytes, count)
        if result < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return result
    }

    init(rootPath: String, limit: Int, token: UUID, directoryName: String,
         cancellation: XMLTVFileCancellation, write: @escaping XMLTVWriteOperation) throws {
        self.limit = limit; self.owner = token; self.writeOperation = write
        self.directoryName = directoryName; self.cancellation = cancellation
        guard limit > 0, limit <= 32 * 1_024 * 1_024 else { throw XMLTVFileError.invalidBudget }
        guard directoryName.hasPrefix("xmltv-"), UUID(uuidString: String(directoryName.dropFirst(6))) != nil else {
            throw XMLTVFileError.unsafeRoot
        }
        // No arbitrary directory cleanup capability, path normalization fallback,
        // symlink alias, home, checkout or broad temporary root admission.
        let prefix = "/private/tmp/OKVideoMac-9B."
        guard rootPath.hasPrefix(prefix) else { throw XMLTVFileError.unsafeRoot }
        let suffix = rootPath.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }), let canonical = realpath(rootPath, nil) else { throw XMLTVFileError.unsafeRoot }
        let resolved = String(cString: canonical); free(canonical)
        guard resolved == rootPath else { throw XMLTVFileError.unsafeRoot }
        do {
            rootFD = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw XMLTVFileError.system(errno) }
            let root = try Self.inspect(rootFD, kind: S_IFDIR, mode: 0o700)
            rootIdentity = XMLTVFileIdentity(root)
            for marker in [".git", "AGENTS.md", "Package.swift"] {
                var info = stat()
                let found = fstatat(rootFD, marker, &info, AT_SYMLINK_NOFOLLOW)
                guard found != 0, errno == ENOENT else { throw XMLTVFileError.unsafeRoot }
            }
            try cancellation.check()
            guard mkdirat(rootFD, directoryName, 0o700) == 0 else { throw XMLTVFileError.system(errno) }
            createdDirectory = true
            directoryFD = openat(rootFD, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw XMLTVFileError.system(errno) }
            // Held across file ownership transfer. Recovery can only reclaim a
            // directory after its live owner has released this advisory lock.
            guard flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else { throw XMLTVFileError.system(errno) }
            // Tighten only a directory just created by this invocation (umask).
            guard fchmod(directoryFD, 0o700) == 0 else { throw XMLTVFileError.system(errno) }
            directoryIdentity = XMLTVFileIdentity(try Self.inspect(directoryFD, kind: S_IFDIR, mode: 0o700))
            fileFD = openat(directoryFD, Self.fileName, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fileFD >= 0 else { throw XMLTVFileError.system(errno) }
            guard fchmod(fileFD, 0o600) == 0 else { throw XMLTVFileError.system(errno) }
            fileIdentity = XMLTVFileIdentity(try Self.inspect(fileFD, kind: S_IFREG, mode: 0o600))
            try validateDirectory()
            try validateFile()
            try cancellation.check()
        } catch {
            // Never delete a path without a receipt. A setup failure before a
            // receipt exists can leave an empty scratch entry, not grant cleanup.
            cleanupLocked()
            if releaseError != nil { throw XMLTVFileError.setupCleanupIncomplete }
            throw error
        }
    }

    private static func inspect(_ fd: Int32, kind: mode_t, mode: mode_t) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw XMLTVFileError.system(errno) }
        guard info.st_mode & S_IFMT == kind, info.st_mode & 0o777 == mode,
              info.st_uid == geteuid(), kind != S_IFREG || info.st_nlink == 1 else {
            throw XMLTVFileError.ownershipMismatch
        }
        return info
    }
    private func validateDirectory() throws {
        guard let rootIdentity, let directoryIdentity,
              rootIdentity.matches(try Self.inspect(rootFD, kind: S_IFDIR, mode: 0o700)),
              directoryIdentity.matches(try Self.inspect(directoryFD, kind: S_IFDIR, mode: 0o700)) else {
            throw XMLTVFileError.ownershipMismatch
        }
        var entry = stat()
        guard fstatat(rootFD, directoryName, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              directoryIdentity.matches(entry), entry.st_mode & S_IFMT == S_IFDIR else {
            throw XMLTVFileError.ownershipMismatch
        }
    }
    private func validateFile() throws {
        guard let fileIdentity,
              fileIdentity.matches(try Self.inspect(fileFD, kind: S_IFREG, mode: 0o600)) else {
            throw XMLTVFileError.ownershipMismatch
        }
        var entry = stat()
        guard fstatat(directoryFD, Self.fileName, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              fileIdentity.matches(entry), entry.st_mode & S_IFMT == S_IFREG else {
            throw XMLTVFileError.ownershipMismatch
        }
    }
    private func requireOwner(_ token: UUID) throws {
        guard token == owner else { throw XMLTVFileError.inactiveOwner }
    }
    func append(_ data: Data, owner token: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try requireOwner(token)
        guard phase == .writing else { throw XMLTVFileError.invalidState }
        do {
            try cancellation.check()
            guard data.count <= limit - byteCount else { throw XMLTVFileError.byteLimit }
            try validateDirectory(); try validateFile()
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try cancellation.check()
                    let n: Int
                    do { n = try writeOperation(fileFD, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count-offset)) }
                    catch let e as POSIXError where e.code == .EINTR { continue }
                    guard n > 0 else { throw XMLTVFileError.noWriteProgress }
                    guard n <= min(65_536, bytes.count-offset) else { throw XMLTVFileError.system(EIO) }
                    offset += n; byteCount += n
                }
            }
            try cancellation.check()
        } catch { cleanupLocked(); throw error }
    }
    func transfer(owner token: UUID) throws -> (UUID, XMLTVFileCancellation) {
        lock.lock(); defer { lock.unlock() }
        try requireOwner(token)
        guard phase == .writing else { throw XMLTVFileError.invalidState }
        do {
            try cancellation.check()
            try validateDirectory(); try validateFile()
            guard try Self.inspect(fileFD, kind: S_IFREG, mode: 0o600).st_size == byteCount else {
                throw XMLTVFileError.ownershipMismatch
            }
            let readFD = openat(directoryFD, Self.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard readFD >= 0 else { throw XMLTVFileError.system(errno) }
            do {
                guard fileIdentity!.matches(try Self.inspect(readFD, kind: S_IFREG, mode: 0o600)) else {
                    throw XMLTVFileError.ownershipMismatch
                }
            } catch { Darwin.close(readFD); throw error }
            let oldFD = fileFD; fileFD = readFD
            // Never retry close by descriptor number: it may already be reused.
            guard Darwin.close(oldFD) == 0 else { throw XMLTVFileError.system(errno) }
            try cancellation.check()
            owner = UUID(); phase = .reading; cancellation = XMLTVFileCancellation()
            return (owner, cancellation)
        } catch { cleanupLocked(); throw error }
    }
    func read(maximumBytes: Int, owner token: UUID) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try requireOwner(token)
        guard phase == .reading else { throw XMLTVFileError.invalidState }
        guard maximumBytes > 0, maximumBytes <= 65_536 else { throw XMLTVFileError.invalidBudget }
        do {
            try cancellation.check()
            var bytes = [UInt8](repeating: 0, count: maximumBytes)
            while true {
                try cancellation.check()
                let n = bytes.withUnsafeMutableBytes { Darwin.read(fileFD, $0.baseAddress!, $0.count) }
                if n < 0 && errno == EINTR { continue }
                guard n >= 0 else { throw XMLTVFileError.system(errno) }
                try cancellation.check()
                return Data(bytes.prefix(n))
            }
        } catch { cleanupLocked(); throw error }
    }
    func release(owner token: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try requireOwner(token)
        if phase != .released { cleanupLocked() }
        if let releaseError { throw releaseError }
    }
    private func cleanupLocked() {
        guard phase != .released else { return }
        phase = .released
        do {
            if directoryIdentity != nil {
                try validateDirectory()
                if fileIdentity != nil {
                    // Keep the open file alive until unlink: do not permit inode
                    // recycling after closing it and then trust a stale receipt.
                    // fstatat + unlinkat are NOT an atomic compare-and-delete.
                    // This relies on the private namespace and serialized owner;
                    // it is not isolation from an adversarial same-UID process.
                    try validateFile()
                    guard unlinkat(directoryFD, Self.fileName, 0) == 0 else { throw XMLTVFileError.system(errno) }
                }
                try validateDirectory()
                // No recursion: strangers cause ENOTEMPTY, never their deletion.
                guard unlinkat(rootFD, directoryName, AT_REMOVEDIR) == 0 else { throw XMLTVFileError.system(errno) }
            } else if createdDirectory {
                throw XMLTVFileError.ownershipMismatch
            }
        } catch { releaseError = error as? XMLTVFileError ?? .ownershipMismatch }
        closeOnce(&fileFD); closeOnce(&directoryFD); closeOnce(&rootFD)
    }
    private func closeOnce(_ fd: inout Int32) {
        guard fd >= 0 else { return }
        let old = fd; fd = -1
        if Darwin.close(old) != 0, releaseError == nil { releaseError = .system(errno) }
    }
    var cleanupIssue: XMLTVFileError? { lock.lock(); defer { lock.unlock() }; return releaseError }
    var testReceipt: XMLTVFileTestReceipt {
        lock.lock(); defer { lock.unlock() }
        return XMLTVFileTestReceipt(rootFD: rootFD, directoryFD: directoryFD, fileFD: fileFD, directoryName: directoryName)
    }
    deinit { cleanupLocked() }
}
