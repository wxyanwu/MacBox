import Foundation
import Darwin

/// A creation receipt, not permission to delete an arbitrary caller-supplied URL.
/// Kept internal to the developer diagnostics target; normal App libraries do not
/// depend on this target. No automatic cleanup: developer reports remain available.
struct SnapshotTemporaryWorkspace {
    let directory: URL
    private let device: dev_t
    private let inode: ino_t
    private let ownerMarker: Data
    private static let prefix = "/private/tmp/OKVideoMac-8B2-DryRun-"
    static let markerName = ".okvideomac-snapshot-owner"

    private init(directory: URL, info: stat, ownerMarker: Data) {
        self.directory = directory
        device = info.st_dev
        inode = info.st_ino
        self.ownerMarker = ownerMarker
    }

    static func create() throws -> Self {
        var template = Array((prefix + "XXXXXX").utf8CString)
        // Both mkdtemp and the copy into an owned String must happen while the
        // Array's storage is pinned. Never return the borrowed C pointer.
        let path = try template.withUnsafeMutableBufferPointer { buffer -> String in
            guard let base = buffer.baseAddress, let result = mkdtemp(base) else {
                throw SnapshotError.unsafeFile
            }
            return String(cString: result)
        }
        let info = try checkedDirectory(path)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard directory.path == path else { throw SnapshotError.unsafeFile }
        // Ephemeral ownership only, never a channel identity or migration token.
        let marker = Data(UUID().uuidString.utf8)
        try QuiescentDatabaseSnapshot.writePrivate(marker, to: directory.appendingPathComponent(markerName))
        return Self(directory: directory, info: info, ownerMarker: marker)
    }

    /// Reject aliases, relative/empty paths, broad roots, cwd/its ancestors and
    /// symlinks before any write or cleanup. A matching name alone is NOT a receipt.
    static func checkedDirectory(
        _ path: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) throws -> stat {
        guard path.hasPrefix(prefix) else { throw SnapshotError.unsafeFile }
        let suffix = path.dropFirst(prefix.count)
        guard suffix.utf8.count == 6, suffix.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }), path != currentDirectory, !currentDirectory.hasPrefix(path + "/") else {
            throw SnapshotError.unsafeFile
        }
        guard let resolved = realpath(path, nil) else { throw SnapshotError.unsafeFile }
        defer { free(resolved) }
        guard String(cString: resolved) == path else { throw SnapshotError.unsafeFile }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw SnapshotError.unsafeFile
        }
        // Do not turn a scratch directory subsequently used as a checkout into
        // a recursive-delete target, even if its original receipt still exists.
        for marker in [".git", "Package.swift", "AGENTS.md"] {
            var markerInfo = stat()
            if lstat(path + "/" + marker, &markerInfo) == 0 { throw SnapshotError.unsafeFile }
            guard errno == ENOENT else { throw SnapshotError.unsafeFile }
        }
        return info
    }

    func validateForCleanup() throws {
        let info = try Self.checkedDirectory(directory.path)
        guard info.st_dev == device, info.st_ino == inode else { throw SnapshotError.unsafeFile }
        let fd = Darwin.open(directory.appendingPathComponent(Self.markerName).path,
                             O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SnapshotError.unsafeFile }
        defer { Darwin.close(fd) }
        var markerInfo = stat()
        guard fstat(fd, &markerInfo) == 0, markerInfo.st_mode & S_IFMT == S_IFREG,
              markerInfo.st_uid == geteuid(), markerInfo.st_mode & 0o777 == 0o600,
              markerInfo.st_nlink == 1, markerInfo.st_size == ownerMarker.count else {
            throw SnapshotError.unsafeFile
        }
        var bytes = [UInt8](repeating: 0, count: ownerMarker.count)
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SnapshotError.unsafeFile }
                offset += count
            }
        }
        guard Data(bytes) == ownerMarker else { throw SnapshotError.unsafeFile }
    }

    /// Only the exact still-owned directory can be removed. Tests must retain
    /// this receipt, never register removeItem(snapshot.directory) as teardown.
    func remove() throws {
        try validateForCleanup()
        try FileManager.default.removeItem(at: directory)
    }
}
