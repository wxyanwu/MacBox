import Foundation
import Darwin

@_spi(XMLTVStreaming) public struct XMLTVRecoveryResult {
    public let scanned: Int
    public let removed: Int
    public let skipped: Int
    public let scanLimitReached: Bool
}

extension XMLTVStagingFile {
    /// Developer cache roots only. Reclaims exact, unlocked UUID children; never
    /// follows links, recursively deletes, or removes a caller-owned root.
    @_spi(XMLTVStreaming) public static func recoverStale(in root: String, limit: Int = 512) throws -> XMLTVRecoveryResult {
        let prefix = "/private/tmp/OKVideoMac-9B."
        guard limit > 0, limit <= 4096, root.hasPrefix(prefix),
              !root.dropFirst(prefix.count).isEmpty,
              root.dropFirst(prefix.count).utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              let path = realpath(root, nil) else { throw XMLTVFileError.unsafeRoot }
        defer { free(path) }
        guard String(cString: path) == root else { throw XMLTVFileError.unsafeRoot }
        let fd = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw XMLTVFileError.system(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw XMLTVFileError.unsafeRoot
        }
        for marker in [".git", "AGENTS.md", "Package.swift"] {
            guard fstatat(fd, marker, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw XMLTVFileError.unsafeRoot
            }
        }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw XMLTVFileError.system(errno) }
        guard let listing = fdopendir(duplicate) else { Darwin.close(duplicate); throw XMLTVFileError.system(errno) }
        defer { closedir(listing) }
        var scanned = 0, removed = 0, skipped = 0
        while scanned < limit, let item = readdir(listing) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            scanned += 1
            guard name.hasPrefix("xmltv-"), UUID(uuidString: String(name.dropFirst(6))) != nil else { skipped += 1; continue }
            if recoverChild(root: fd, name: name) { removed += 1 } else { skipped += 1 }
        }
        return XMLTVRecoveryResult(scanned: scanned, removed: removed, skipped: skipped, scanLimitReached: scanned == limit)
    }

    private static func recoverChild(root: Int32, name: String) -> Bool {
        let child = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { return false }
        defer { Darwin.close(child) }
        guard flock(child, LOCK_EX | LOCK_NB) == 0 else { return false }
        var opened = stat(), linked = stat()
        guard fstat(child, &opened) == 0, opened.st_uid == geteuid(), opened.st_mode & 0o777 == 0o700,
              fstatat(root, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              linked.st_ino == opened.st_ino, linked.st_dev == opened.st_dev else { return false }
        let duplicate = dup(child)
        guard duplicate >= 0 else { return false }
        guard let listing = fdopendir(duplicate) else { Darwin.close(duplicate); return false }
        defer { closedir(listing) }
        var payload = false
        while let entry = readdir(listing) {
            let item = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if item == "." || item == ".." { continue }
            guard item == "payload", !payload else { return false }
            payload = true
        }
        if payload {
            guard fstatat(child, "payload", &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  linked.st_mode & S_IFMT == S_IFREG, linked.st_mode & 0o777 == 0o600,
                  linked.st_uid == geteuid(), linked.st_nlink == 1 else { return false }
            guard unlinkat(child, "payload", 0) == 0 else { return false }
        }
        return unlinkat(root, name, AT_REMOVEDIR) == 0
    }
}
