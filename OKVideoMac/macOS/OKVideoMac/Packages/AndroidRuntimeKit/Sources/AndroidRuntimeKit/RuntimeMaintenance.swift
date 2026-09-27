import Foundation
import CryptoKit
import Darwin

public enum RuntimeMaintenanceError: String, Error, LocalizedError, Codable {
    case busy, unsafePath, changed, expiredPlan, pendingRecovery, corruptJournal
    case filesystem, nothingToRemove, sessionNotStopped

    public var errorDescription: String? { "Android maintenance: \(rawValue)" }
}

/// Cross-process exclusion. Shared leases protect installers; an exclusive
/// lease protects the entire stop/revalidation/uninstall transaction.
public final class RuntimeMaintenanceLease: @unchecked Sendable {
    private let descriptor: Int32
    public init(layout: AndroidRuntimeLayout, exclusive: Bool = false) throws {
        let parent = layout.root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let directory = try MaintenanceDirectory.support(layout)
        let fd = openat(directory.fd, ".android-runtime-maintenance.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimeMaintenanceError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            Darwin.close(fd)
            throw RuntimeMaintenanceError.unsafePath
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw RuntimeMaintenanceError.busy
        }
        if !exclusive {
            do { try RuntimeMaintenanceService.requireNoPendingTransaction(layout: layout) }
            catch { flock(fd, LOCK_UN); Darwin.close(fd); throw error }
        }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

public struct ManagedUninstallItem: Codable, Equatable, Sendable {
    public enum Category: String, Codable, Sendable { case generation, downloads, staging, backup, metadata }
    public let relativePath: String
    public let category: Category
    public let allocatedBytes: Int64
    fileprivate let entries: [MaintenanceEntry]
}

public struct ManagedUninstallPlan: Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let policyVersion: Int
    public let items: [ManagedUninstallItem]
    public let preserved: [String]
    public let userDataPolicy: String
    public let externalSDKPolicy: String
    public var estimatedReclaimBytes: Int64 { items.reduce(0) { $0 + $1.allocatedBytes } }
    // Never serialize absolute SDK paths or credential material into diagnostics.
    fileprivate let selectionDigest: String
    fileprivate let rootIdentity: MaintenanceEntry
}

public struct ManagedRuntimeStorage: Codable, Equatable, Sendable {
    public var componentBytes: Int64 = 0
    public var cacheBytes: Int64 = 0
    public var userDataBytes: Int64 = 0
    public var backupBytes: Int64 = 0
    public var maintenanceBytes: Int64 = 0
    public var isComplete = true
    public var hasPendingMaintenance = false
}

public struct ManagedMaintenanceDiagnostic: Codable, Sendable {
    public let plan: ManagedUninstallPlan
    public let phase: String
    public let removedPaths: [String]
}

public struct ManagedUninstallResult: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let cleanupPending: Bool
    public let removedPaths: [String]
}

fileprivate struct MaintenanceEntry: Codable, Equatable, Sendable {
    let path: String
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let allocated: Int64
    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    var isSymlink: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
    func sameIdentity(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode
    }
}

/// All traversal, renames and removals are relative to opened, no-follow
/// directory descriptors. A replaced path cannot redirect deletion outside
/// the opened tree. Only relative symlinks within the same candidate are
/// admitted; their directory entries are unlinked, never their targets.
private final class MaintenanceDirectory {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }
    static func support(_ layout: AndroidRuntimeLayout) throws -> MaintenanceDirectory {
        let parent = layout.root.deletingLastPathComponent().standardizedFileURL
        guard layout.root.isFileURL, parent.path != "/", parent.path != NSHomeDirectory() else {
            throw RuntimeMaintenanceError.unsafePath
        }
        // These two system aliases are canonical on macOS. No application or
        // user-controlled ancestor symlink is followed.
        var path = parent.path
        if path == "/tmp" || path.hasPrefix("/tmp/") { path = "/private" + path }
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw RuntimeMaintenanceError.filesystem }
        for part in path.split(separator: "/") {
            let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else { throw RuntimeMaintenanceError.unsafePath }
            descriptor = next
        }
        return MaintenanceDirectory(fd: descriptor)
    }
    static func root(_ layout: AndroidRuntimeLayout) throws -> MaintenanceDirectory {
        let parent = try support(layout)
        let fd = openat(parent.fd, layout.root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimeMaintenanceError.unsafePath }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid() else {
            Darwin.close(fd); throw RuntimeMaintenanceError.unsafePath
        }
        return MaintenanceDirectory(fd: fd)
    }
    static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.hasPrefix("~") }) else {
            throw RuntimeMaintenanceError.unsafePath
        }
        return parts
    }
    func child(_ name: String, create: Bool = false) throws -> MaintenanceDirectory {
        guard try Self.components(name).count == 1 else { throw RuntimeMaintenanceError.unsafePath }
        if create, mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw RuntimeMaintenanceError.filesystem }
        let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard childFD >= 0 else { throw RuntimeMaintenanceError.unsafePath }
        var parentInfo = stat(), childInfo = stat()
        guard fstat(fd, &parentInfo) == 0, fstat(childFD, &childInfo) == 0,
              parentInfo.st_dev == childInfo.st_dev, childInfo.st_uid == getuid() else {
            Darwin.close(childFD); throw RuntimeMaintenanceError.unsafePath
        }
        return MaintenanceDirectory(fd: childFD)
    }
    func parent(of path: String, create: Bool = false) throws -> (MaintenanceDirectory, String) {
        var parts = try Self.components(path)
        let name = parts.removeLast()
        var directory = self
        for part in parts { directory = try directory.child(part, create: create) }
        return (directory, name)
    }
    func names() throws -> [String] {
        // openat creates a new directory offset; dup would share readdir state.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { Darwin.close(copy) }
            throw RuntimeMaintenanceError.filesystem
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw RuntimeMaintenanceError.filesystem }
        return result.sorted()
    }
    func entry(_ name: String, path: String? = nil) throws -> MaintenanceEntry? {
        var s = stat()
        if fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw RuntimeMaintenanceError.filesystem
        }
        let kind = s.st_mode & S_IFMT
        guard (kind == S_IFDIR || kind == S_IFREG || kind == S_IFLNK), s.st_uid == getuid(),
              kind == S_IFDIR || s.st_nlink == 1 else { throw RuntimeMaintenanceError.unsafePath }
        return MaintenanceEntry(path: path ?? name, device: s.st_dev, inode: s.st_ino,
            mode: s.st_mode, size: s.st_size, modifiedSeconds: Int64(s.st_mtimespec.tv_sec),
            modifiedNanos: Int64(s.st_mtimespec.tv_nsec), allocated: Int64(s.st_blocks) * 512)
    }
    func tree(_ name: String, prefix: String = "") throws -> [MaintenanceEntry] {
        let path = prefix.isEmpty ? name : prefix + "/" + name
        guard let item = try entry(name, path: path) else { throw RuntimeMaintenanceError.changed }
        var entries = [item]
        if item.isSymlink {
            var buffer = [CChar](repeating: 0, count: 4097)
            let count = readlinkat(fd, name, &buffer, buffer.count - 1)
            guard count > 0, count < buffer.count - 1 else { throw RuntimeMaintenanceError.unsafePath }
            let target = String(cString: buffer)
            guard !target.hasPrefix("/"), !target.hasPrefix("~") else { throw RuntimeMaintenanceError.unsafePath }
            var resolved = path.split(separator: "/").map(String.init)
            let boundary = resolved.first
            resolved.removeLast()
            for component in target.split(separator: "/") {
                if component == "." { continue }
                if component == ".." {
                    guard resolved.count > 1 else { throw RuntimeMaintenanceError.unsafePath }
                    resolved.removeLast()
                } else { resolved.append(String(component)) }
            }
            guard resolved.first == boundary else { throw RuntimeMaintenanceError.unsafePath }
        }
        if item.isDirectory {
            let directory = try child(name)
            for nested in try directory.names() { entries += try directory.tree(nested, prefix: path) }
        }
        return entries
    }
    func data(_ name: String) throws -> Data? {
        guard let before = try entry(name) else { return nil }
        guard !before.isDirectory, before.size <= 16_777_216 else { throw RuntimeMaintenanceError.unsafePath }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw RuntimeMaintenanceError.filesystem }
        defer { Darwin.close(file) }
        var s = stat()
        guard fstat(file, &s) == 0, s.st_ino == before.inode, s.st_dev == before.device else { throw RuntimeMaintenanceError.changed }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            guard count >= 0 else { throw RuntimeMaintenanceError.filesystem }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= 16_777_216 else { throw RuntimeMaintenanceError.unsafePath }
        }
        return result
    }
    func write<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        let temporary = ".write-" + UUID().uuidString
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw RuntimeMaintenanceError.filesystem }
        defer { Darwin.close(file); unlinkat(fd, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw RuntimeMaintenanceError.filesystem }
                offset += written
            }
        }
        guard fsync(file) == 0, renameat(fd, temporary, fd, name) == 0 else { throw RuntimeMaintenanceError.filesystem }
        _ = fsync(fd)
    }
    func move(_ path: String, to destination: MaintenanceDirectory, expected: MaintenanceEntry) throws {
        let (source, name) = try parent(of: path)
        let (target, targetName) = try destination.parent(of: path, create: true)
        guard let actual = try source.entry(name), actual.sameIdentity(expected),
              try target.entry(targetName) == nil else { throw RuntimeMaintenanceError.changed }
        guard renameatx_np(source.fd, name, target.fd, targetName, UInt32(RENAME_EXCL)) == 0 else { throw RuntimeMaintenanceError.filesystem }
        _ = fsync(source.fd); _ = fsync(target.fd)
    }
    func remove(_ name: String, expected: [MaintenanceEntry], prefix: String = "") throws {
        let path = prefix.isEmpty ? name : prefix + "/" + name
        guard let actual = try entry(name, path: path) else { return }
        guard let original = expected.first(where: { $0.path == path }),
              original.sameIdentity(actual) else { throw RuntimeMaintenanceError.changed }
        if actual.isDirectory {
            let directory = try child(name)
            for nested in try directory.names() { try directory.remove(nested, expected: expected, prefix: path) }
            guard let final = try entry(name), final.sameIdentity(original),
                  unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw RuntimeMaintenanceError.changed }
        } else {
            guard original == actual else { throw RuntimeMaintenanceError.changed }
            guard unlinkat(fd, name, 0) == 0 else { throw RuntimeMaintenanceError.filesystem }
        }
    }
}

/// A plan is an expiring in-process snapshot, not a deletion authorization.
/// The caller holds its session admission closed while execute/recover runs.
public actor RuntimeMaintenanceService {
    public let layout: AndroidRuntimeLayout
    private let catalog: RuntimeCatalog
    private let lifetime: TimeInterval
    private var prepared: (ManagedUninstallPlan, TimeInterval)?
    private var running = false
    private var lastDiagnostic: ManagedUninstallPlan?
    private let checkpoint: @Sendable (String) throws -> Void
    private struct Journal: Codable {
        enum Phase: String, Codable { case moving, committed, completed, restored }
        let schemaVersion: Int
        let plan: ManagedUninstallPlan
        var phase: Phase
        var removed: [String]
    }
    public init(applicationSupportDirectory: URL, catalog: RuntimeCatalog,
                planLifetime: TimeInterval = 120,
                checkpoint: @escaping @Sendable (String) throws -> Void = { _ in }) {
        layout = AndroidRuntimeLayout(applicationSupportDirectory: applicationSupportDirectory)
        self.catalog = catalog
        lifetime = planLifetime
        self.checkpoint = checkpoint
    }
    public func diagnosticPlan() -> ManagedUninstallPlan? { lastDiagnostic }
    public func transactionDiagnostics() -> [ManagedMaintenanceDiagnostic] {
        guard let root = try? MaintenanceDirectory.root(layout),
              let directory = try? root.child("Maintenance"),
              let names = try? directory.names() else { return [] }
        return names.compactMap { name in
            guard UUID(uuidString: name) != nil,
                  let transaction = try? directory.child(name),
                  let data = try? transaction.data("transaction.json"),
                  let journal = try? JSONDecoder().decode(Journal.self, from: data),
                  journal.schemaVersion == 1, journal.plan.id.uuidString == name,
                  (try? validateJournal(journal)) != nil else { return nil }
            return ManagedMaintenanceDiagnostic(plan: journal.plan,
                phase: journal.phase.rawValue, removedPaths: journal.removed)
        }
    }
    public func prepareManagedUninstall() throws -> ManagedUninstallPlan {
        guard !running else { throw RuntimeMaintenanceError.busy }
        try Self.requireNoPendingTransaction(layout: layout)
        let plan = try makePlan()
        prepared = (plan, ProcessInfo.processInfo.systemUptime)
        lastDiagnostic = plan
        return plan
    }
    public func storage() -> ManagedRuntimeStorage {
        var result = ManagedRuntimeStorage()
        guard FileManager.default.fileExists(atPath: layout.root.path) else { return result }
        do {
            let root = try MaintenanceDirectory.root(layout)
            for (name, category) in [("Generations", 0), ("Downloads", 1), ("Staging", 1),
                                     ("avd", 2), ("home", 2), ("Backups", 3), ("Maintenance", 4)] {
                do {
                    guard try root.entry(name) != nil else { continue }
                    let bytes = try root.tree(name).filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.allocated }
                    switch category {
                    case 0: result.componentBytes += bytes
                    case 1: result.cacheBytes += bytes
                    case 2: result.userDataBytes += bytes
                    case 3: result.backupBytes += bytes
                    default: result.maintenanceBytes += bytes
                    }
                } catch { result.isComplete = false }
            }
            result.hasPendingMaintenance = (try? Self.requireNoPendingTransaction(layout: layout)) == nil
        } catch { result.isComplete = false; result.hasPendingMaintenance = true }
        return result
    }
    public static func requireNoPendingTransaction(layout: AndroidRuntimeLayout) throws {
        guard FileManager.default.fileExists(atPath: layout.root.path) else { return }
        let root = try MaintenanceDirectory.root(layout)
        guard try root.entry("Maintenance") != nil else { return }
        let maintenance = try root.child("Maintenance")
        for name in try maintenance.names() {
            guard UUID(uuidString: name) != nil else { throw RuntimeMaintenanceError.corruptJournal }
            let directory = try maintenance.child(name)
            guard let data = try directory.data("transaction.json"),
                  let journal = try? JSONDecoder().decode(Journal.self, from: data),
                  journal.schemaVersion == 1, journal.plan.id.uuidString == name else { throw RuntimeMaintenanceError.corruptJournal }
            if journal.phase != .completed && journal.phase != .restored { throw RuntimeMaintenanceError.pendingRecovery }
        }
    }
    public func execute(planID: UUID, quiesce: @Sendable () async throws -> Void) async throws -> ManagedUninstallResult {
        guard !running else { throw RuntimeMaintenanceError.busy }
        guard let (plan, created) = prepared, plan.id == planID,
              ProcessInfo.processInfo.systemUptime - created <= lifetime else { throw RuntimeMaintenanceError.expiredPlan }
        prepared = nil // single use, including failed execution
        running = true
        defer { running = false }
        let lease = try RuntimeMaintenanceLease(layout: layout, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        try Self.requireNoPendingTransaction(layout: layout)
        try await quiesce()
        try await detachCompressedGenerations()
        guard ProcessInfo.processInfo.systemUptime - created <= lifetime else { throw RuntimeMaintenanceError.expiredPlan }
        let current = try makePlan()
        guard current.items == plan.items, current.selectionDigest == plan.selectionDigest,
              current.rootIdentity.sameIdentity(plan.rootIdentity) else { throw RuntimeMaintenanceError.changed }
        guard !plan.items.isEmpty else { throw RuntimeMaintenanceError.nothingToRemove }
        try Task.checkCancellation()
        let root = try MaintenanceDirectory.root(layout)
        let maintenance = try root.child("Maintenance", create: true)
        let transaction = try maintenance.child(plan.id.uuidString, create: true)
        var journal = Journal(schemaVersion: 1, plan: plan, phase: .moving, removed: [])
        try transaction.write(journal, name: "transaction.json")
        let quarantine = try transaction.child("quarantine", create: true)
        do {
            // Pointer first: a crash must never leave a valid active pointer
            // while a generation is being moved away.
            for item in ordered(plan.items) {
                try Task.checkCancellation()
                try checkpoint("beforeMove:" + item.relativePath)
                try root.move(item.relativePath, to: quarantine, expected: item.entries[0])
            }
            try checkpoint("beforeCommit")
            journal.phase = .committed
            try transaction.write(journal, name: "transaction.json")
        } catch {
            // No recursive cleanup on a failed restore. The journal and every
            // remaining byte stay recoverable in Maintenance.
            try? restore(journal, root: root, transaction: transaction, quarantine: quarantine)
            throw error
        }
        return finish(&journal, transaction: transaction, quarantine: quarantine)
    }
    public func recover(quiesce: @Sendable () async throws -> Void) async throws -> [ManagedUninstallResult] {
        guard !running else { throw RuntimeMaintenanceError.busy }
        running = true; prepared = nil
        defer { running = false }
        let lease = try RuntimeMaintenanceLease(layout: layout, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        try await quiesce()
        try await detachCompressedGenerations()
        let root = try MaintenanceDirectory.root(layout)
        guard try root.entry("Maintenance") != nil else { return [] }
        let maintenance = try root.child("Maintenance")
        var results: [ManagedUninstallResult] = []
        for id in try maintenance.names() {
            guard UUID(uuidString: id) != nil else { throw RuntimeMaintenanceError.corruptJournal }
            let transaction = try maintenance.child(id)
            guard let data = try transaction.data("transaction.json"),
                  var journal = try? JSONDecoder().decode(Journal.self, from: data),
                  journal.schemaVersion == 1, journal.plan.id.uuidString == id,
                  journal.plan.rootIdentity.sameIdentity(try root.entry(".")!) else { throw RuntimeMaintenanceError.corruptJournal }
            if journal.phase == .completed || journal.phase == .restored { continue }
            try validateJournal(journal)
            let quarantine = try transaction.child("quarantine", create: true)
            if journal.phase == .moving {
                let selection = try root.data("runtime-selection.json") ?? Data()
                let digest = SHA256.hash(data: selection).map { String(format: "%02x", $0) }.joined()
                guard digest == journal.plan.selectionDigest else { throw RuntimeMaintenanceError.changed }
                try restore(journal, root: root, transaction: transaction, quarantine: quarantine)
            } else {
                results.append(finish(&journal, transaction: transaction, quarantine: quarantine))
            }
        }
        return results
    }
    private func ordered(_ items: [ManagedUninstallItem]) -> [ManagedUninstallItem] {
        items.sorted { ($0.relativePath == "current-runtime.json" ? "" : $0.relativePath) < ($1.relativePath == "current-runtime.json" ? "" : $1.relativePath) }
    }
    private func restore(_ journal: Journal, root: MaintenanceDirectory,
                         transaction: MaintenanceDirectory, quarantine: MaintenanceDirectory) throws {
        for item in ordered(journal.plan.items).reversed() {
            // Missing parent means this item was never moved.
            let (parent, name) = try quarantine.parent(of: item.relativePath, create: true)
            guard try parent.entry(name) != nil else {
                let (originalParent, originalName) = try root.parent(of: item.relativePath)
                guard let original = try originalParent.entry(originalName),
                      original.sameIdentity(item.entries[0]) else { throw RuntimeMaintenanceError.changed }
                continue
            }
            try checkpoint("beforeRestore:" + item.relativePath)
            try quarantine.move(item.relativePath, to: root, expected: item.entries[0])
        }
        var restored = journal; restored.phase = .restored
        try transaction.write(restored, name: "transaction.json")
    }
    private func finish(_ journal: inout Journal, transaction: MaintenanceDirectory,
                        quarantine: MaintenanceDirectory) -> ManagedUninstallResult {
        do {
            for item in ordered(journal.plan.items) {
                try checkpoint("beforeDelete:" + item.relativePath)
                let (parent, name) = try quarantine.parent(of: item.relativePath)
                try parent.remove(name, expected: item.entries)
                if !journal.removed.contains(item.relativePath) { journal.removed.append(item.relativePath) }
                try transaction.write(journal, name: "transaction.json")
            }
            journal.phase = .completed
            try transaction.write(journal, name: "transaction.json")
        } catch {
            return ManagedUninstallResult(transactionID: journal.plan.id, cleanupPending: true, removedPaths: journal.removed)
        }
        return ManagedUninstallResult(transactionID: journal.plan.id, cleanupPending: false, removedPaths: journal.removed)
    }
    private func validateJournal(_ journal: Journal) throws {
        guard journal.plan.policyVersion == 1, journal.plan.userDataPolicy == "KEEP",
              journal.plan.externalSDKPolicy == "EXCLUDED" else { throw RuntimeMaintenanceError.corruptJournal }
        for item in journal.plan.items {
            let parts = try MaintenanceDirectory.components(item.relativePath)
            let allowed: Bool
            switch item.category {
            case .generation: allowed = parts.count == 2 && parts[0] == "Generations" && RuntimeGenerationID(rawValue: parts[1]).isValid
            case .downloads: allowed = parts.count == 2 && parts[0] == "Downloads" && downloadNames().contains(parts[1])
            case .staging: allowed = parts.count == 2 && parts[0] == "Staging" && UUID(uuidString: parts[1]) != nil
            case .backup: allowed = parts.count == 2 && parts[0] == "Backups" && catalog.generations.contains { parts[1].hasPrefix($0.generationID.rawValue + "-") }
            case .metadata: allowed = parts.count == 1 && ["current-runtime.json", "installation-transaction.json"].contains(parts[0])
            }
            guard allowed, let first = item.entries.first, first.path == parts.last,
                  item.entries.allSatisfy({ $0.path == first.path || $0.path.hasPrefix(first.path + "/") }) else { throw RuntimeMaintenanceError.corruptJournal }
            for entry in item.entries { _ = try MaintenanceDirectory.components(entry.path) }
        }
    }
    private func downloadNames() -> Set<String> {
        Set(catalog.generations.flatMap(\.components).flatMap { component in
            let name = component.sha256.lowercased() + "-" + component.id + ".artifact"
            return [name, component.sha256.lowercased() + "-" + component.id + ".partial"]
        })
    }
    private func makePlan() throws -> ManagedUninstallPlan {
        let root = try MaintenanceDirectory.root(layout)
        let selection = try root.data("runtime-selection.json") ?? Data()
        var external: URL?
        if !selection.isEmpty {
            guard let object = try JSONSerialization.jsonObject(with: selection) as? [String: Any],
                  object["schemaVersion"] as? Int == 1,
                  let mode = object["mode"] as? String, ["managed", "external"].contains(mode) else { throw RuntimeMaintenanceError.unsafePath }
            if let path = object["externalSDKRoot"] as? String {
                guard path.hasPrefix("/"), !path.contains("\0") else { throw RuntimeMaintenanceError.unsafePath }
                external = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            } else if mode == "external" {
                throw RuntimeMaintenanceError.unsafePath
            }
        }
        var items: [ManagedUninstallItem] = [], preserved = ["avd/", "home/", "Mounts/", "runtime-selection.json", "runtime-profile.json", "runtime-continuity.json", "runtime-manifest.json", "Backups/<user-data-or-unrecognized>/"]
        func append(_ path: String, _ category: ManagedUninstallItem.Category) throws {
            if let external {
                let target = layout.root.appendingPathComponent(path).resolvingSymlinksInPath().path
                let externalPath = external.path
                guard target != externalPath, !target.hasPrefix(externalPath + "/"), !externalPath.hasPrefix(target + "/") else { throw RuntimeMaintenanceError.unsafePath }
            }
            let (parent, name) = try root.parent(of: path)
            let entries = try parent.tree(name)
            items.append(ManagedUninstallItem(relativePath: path, category: category,
                allocatedBytes: entries.filter { !$0.isDirectory }.reduce(0) { $0 + $1.allocated }, entries: entries))
        }
        for category in ["Generations", "Downloads", "Staging", "Backups"] {
            guard try root.entry(category) != nil else { continue }
            let directory = try root.child(category)
            for name in try directory.names() {
                let path = category + "/" + name
                switch category {
                case "Downloads":
                    if downloadNames().contains(name), try directory.entry(name)?.isDirectory == false { try append(path, .downloads) }
                    else { preserved.append(path) }
                case "Staging":
                    // Unknown/legacy temporary content is not proof of ownership.
                    if UUID(uuidString: name) != nil, let data = try root.data("installation-transaction.json"),
                       let record = try? JSONDecoder().decode(RuntimeInstallationTransaction.self, from: data),
                       record.schemaVersion == 1, record.transactionID.lowercased() == name.lowercased(),
                       catalog.generations.contains(where: { $0.generationID == record.generationID }) { try append(path, .staging) }
                    else { preserved.append(path) }
                default:
                    guard try directory.entry(name)?.isDirectory == true else {
                        preserved.append(path); continue
                    }
                    let candidate = try directory.child(name)
                    guard let data = try candidate.data("generation-manifest.json"),
                          let manifest = try? JSONDecoder().decode(RuntimeGenerationManifest.self, from: data),
                          manifest.schemaVersion == 1, manifest.generationID.isValid,
                          let descriptor = catalog.generations.first(where: { $0.generationID == manifest.generationID }),
                          manifest.runtimeSchema == descriptor.runtimeSchema,
                          manifest.avdSchema == descriptor.avdSchema,
                          manifest.bridgeSchema == descriptor.bridgeSchema,
                          Set(manifest.components.map(\.id)) == Set(descriptor.components.map(\.id)),
                          manifest.components.allSatisfy({ installed in descriptor.components.contains {
                              $0.id == installed.id && $0.sha256 == installed.sha256 && $0.role == installed.role
                          } }),
                          try validGenerationFiles(candidate),
                          (category == "Generations" ? name == manifest.generationID.rawValue :
                            (name.hasPrefix(manifest.generationID.rawValue + "-") && UUID(uuidString: String(name.dropFirst(manifest.generationID.rawValue.count + 1))) != nil)) else {
                        preserved.append(path); continue
                    }
                    try append(path, category == "Generations" ? .generation : .backup)
                }
            }
        }
        if let data = try root.data("current-runtime.json") {
            guard let pointer = try? JSONDecoder().decode(CurrentRuntimePointer.self, from: data),
                  pointer.schemaVersion == 1, pointer.generationID.isValid else { throw RuntimeMaintenanceError.unsafePath }
            let path = "Generations/" + pointer.generationID.rawValue
            guard items.contains(where: { $0.relativePath == path }) ||
                    !(FileManager.default.fileExists(atPath: layout.root.appendingPathComponent(path).path)) else { throw RuntimeMaintenanceError.unsafePath }
            try append("current-runtime.json", .metadata)
        }
        if let data = try root.data("installation-transaction.json") {
            if let record = try? JSONDecoder().decode(RuntimeInstallationTransaction.self, from: data),
               record.schemaVersion == 1, UUID(uuidString: record.transactionID) != nil, record.generationID.isValid {
                try append("installation-transaction.json", .metadata)
            } else { preserved.append("installation-transaction.json") }
        }
        return ManagedUninstallPlan(id: UUID(), createdAt: Date(), policyVersion: 1,
            items: items.sorted { $0.relativePath < $1.relativePath }, preserved: preserved.sorted(),
            userDataPolicy: "KEEP", externalSDKPolicy: "EXCLUDED",
            selectionDigest: SHA256.hash(data: selection).map { String(format: "%02x", $0) }.joined(),
            rootIdentity: try root.entry(".")!)
    }

    private func validGenerationFiles(_ directory: MaintenanceDirectory) throws -> Bool {
        let names = Set(try directory.names())
        if names.isSubset(of: ["sdk", "jre", "generation-manifest.json"]) { return true }
        guard names == ["runtime.dmg", "compressed-image.json", "generation-manifest.json"],
              let data = try directory.data("compressed-image.json"),
              let manifest = try? JSONDecoder().decode(RuntimeCompressedImageManifest.self, from: data),
              manifest.schemaVersion == 1, ["ULFO/APFS", "ULMO/APFS"].contains(manifest.format),
              manifest.imageSHA256.count == 64,
              manifest.imageSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              let image = try directory.entry("runtime.dmg"),
              !image.isDirectory, !image.isSymlink, image.size == manifest.imageBytes else { return false }
        return true
    }

    private func detachCompressedGenerations() async throws {
        let storage = try RuntimeCompressedStorage(root: layout.root)
        for descriptor in catalog.generations {
            let generation = layout.generation(descriptor.generationID)
            if generation.isCompressed {
                try await storage.unmount(container: generation.root, at: generation.payloadRoot)
            }
        }
    }
}
