import Foundation
import CryptoKit
import Darwin

public enum RuntimeCompressedStorageError: String, Error, LocalizedError {
    case invalidLayout, invalidManifest, imageChanged, mountConflict
    case commandFailed, commandTimedOut, notReadOnly, busy

    public var errorDescription: String? {
        "Android compressed storage: \(rawValue)"
    }
}

/// The compressed container is stored outside its mount point. AVD, keys and
/// other mutable data never enter this image. Content addresses identify the
/// exact locally built image; the normal catalog still identifies components.
public struct RuntimeCompressedImageManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let format: String
    public let imageBytes: Int64
    public let imageSHA256: String
}

/// Disk-image operations are serialized and run away from the main actor.
/// This layer does not activate a generation, change a pointer, or remove the
/// original environment. The installation transaction owns those decisions.
public actor RuntimeCompressedStorage {
    public static let imageName = "runtime.dmg"
    public static let manifestName = "compressed-image.json"
    private let boundary: ManagedRuntimePathBoundary
    private let fileManager = FileManager.default
    private var operationRunning = false

    public init(root: URL) throws {
        boundary = try ManagedRuntimePathBoundary(root: root)
    }

    /// Build into a NEW directory. A failed build remains unactivated and can
    /// be handled by the installer's existing staging recovery transaction.
    public func create(source: URL, destination: URL) async throws -> RuntimeCompressedImageManifest {
        guard !operationRunning else { throw RuntimeCompressedStorageError.busy }
        operationRunning = true
        defer { operationRunning = false }
        try Task.checkCancellation()
        let source = try boundary.validateMutationTarget(source)
        let destination = try boundary.validateMutationTarget(destination)
        guard !destination.path.hasPrefix(source.path + "/"),
              !fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: source.appendingPathComponent("generation-manifest.json").path),
              fileManager.fileExists(atPath: source.appendingPathComponent("sdk").path),
              fileManager.fileExists(atPath: source.appendingPathComponent("jre").path) else {
            throw RuntimeCompressedStorageError.invalidLayout
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let image = destination.appendingPathComponent(Self.imageName)
        _ = try await command([
            "create", "-srcfolder", source.path, "-volname", "OKVideoMacRuntime",
            "-format", "ULMO", "-fs", "APFS", image.path
        ], timeout: 900)
        _ = try await command(["verify", image.path], timeout: 300)
        let descriptor = RuntimeCompressedImageManifest(
            schemaVersion: 1, format: "ULMO/APFS",
            imageBytes: try size(image), imageSHA256: try digest(image)
        )
        try fileManager.copyItem(
            at: source.appendingPathComponent("generation-manifest.json"),
            to: destination.appendingPathComponent("generation-manifest.json")
        )
        try JSONEncoder().encode(descriptor).write(
            to: destination.appendingPathComponent(Self.manifestName), options: .atomic
        )
        return descriptor
    }

    public func mount(container: URL, at mountPoint: URL) async throws {
        guard !operationRunning else { throw RuntimeCompressedStorageError.busy }
        operationRunning = true
        defer { operationRunning = false }
        try Task.checkCancellation()
        let container = try boundary.validateMutationTarget(container)
        let mountPoint = try boundary.validateMutationTarget(mountPoint)
        guard container != mountPoint,
              !mountPoint.path.hasPrefix(container.path + "/"),
              !container.path.hasPrefix(mountPoint.path + "/") else {
            throw RuntimeCompressedStorageError.invalidLayout
        }
        let image = try boundary.validateReadTarget(container.appendingPathComponent(Self.imageName))
        let descriptor = try readManifest(container)
        let identity = try await mountedImage(at: mountPoint)
        if let identity {
            guard identity == image.resolvingSymlinksInPath().path else {
                throw RuntimeCompressedStorageError.mountConflict
            }
            try validateMountedContent(container: container, mountPoint: mountPoint)
            return
        }
        guard try size(image) == descriptor.imageBytes,
              try digest(image) == descriptor.imageSHA256 else {
            throw RuntimeCompressedStorageError.imageChanged
        }
        if fileManager.fileExists(atPath: mountPoint.path) {
            guard try fileManager.contentsOfDirectory(atPath: mountPoint.path).isEmpty else {
                throw RuntimeCompressedStorageError.mountConflict
            }
        } else {
            try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        }
        _ = try await command([
            "attach", "-readonly", "-nobrowse", "-mountpoint", mountPoint.path,
            image.path
        ], timeout: 120)
        guard try await mountedImage(at: mountPoint) == image.resolvingSymlinksInPath().path else {
            throw RuntimeCompressedStorageError.mountConflict
        }
        try validateMountedContent(container: container, mountPoint: mountPoint)
    }

    /// Refuse to detach unrelated volumes, and never force-unmount busy data.
    public func unmount(container: URL, at mountPoint: URL) async throws {
        guard !operationRunning else { throw RuntimeCompressedStorageError.busy }
        operationRunning = true
        defer { operationRunning = false }
        let container = try boundary.validateMutationTarget(container)
        let mountPoint = try boundary.validateMutationTarget(mountPoint)
        guard let identity = try await mountedImage(at: mountPoint) else { return }
        let expected = container.appendingPathComponent(Self.imageName).resolvingSymlinksInPath().path
        guard identity == expected else { throw RuntimeCompressedStorageError.mountConflict }
        _ = try await command(["detach", mountPoint.path], timeout: 60)
        guard try await mountedImage(at: mountPoint) == nil else {
            throw RuntimeCompressedStorageError.mountConflict
        }
    }

    private func readManifest(_ container: URL) throws -> RuntimeCompressedImageManifest {
        let path = try boundary.validateReadTarget(container.appendingPathComponent(Self.manifestName))
        guard try size(path) < 16_384,
              let value = try? JSONDecoder().decode(RuntimeCompressedImageManifest.self, from: Data(contentsOf: path)),
              value.schemaVersion == 1, ["ULFO/APFS", "ULMO/APFS"].contains(value.format), value.imageBytes > 0,
              value.imageSHA256.count == 64,
              value.imageSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RuntimeCompressedStorageError.invalidManifest
        }
        return value
    }

    private func validateMountedContent(container: URL, mountPoint: URL) throws {
        let values = try mountPoint.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard values.volumeIsReadOnly == true else { throw RuntimeCompressedStorageError.notReadOnly }
        let expected = try Data(contentsOf: container.appendingPathComponent("generation-manifest.json"))
        let actual = try Data(contentsOf: mountPoint.appendingPathComponent("generation-manifest.json"))
        guard expected == actual,
              fileManager.fileExists(atPath: mountPoint.appendingPathComponent("sdk").path),
              fileManager.fileExists(atPath: mountPoint.appendingPathComponent("jre").path) else {
            throw RuntimeCompressedStorageError.invalidLayout
        }
    }

    private func mountedImage(at mountPoint: URL) async throws -> String? {
        let data = try await command(["info", "-plist"], timeout: 30)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            throw RuntimeCompressedStorageError.invalidLayout
        }
        for image in images {
            for entity in image["system-entities"] as? [[String: Any]] ?? [] {
                if let path = entity["mount-point"] as? String,
                   URL(fileURLWithPath: path).resolvingSymlinksInPath().path == mountPoint.resolvingSymlinksInPath().path {
                    guard let imagePath = image["image-path"] as? String else {
                        throw RuntimeCompressedStorageError.mountConflict
                    }
                    return URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().path
                }
            }
        }
        return nil
    }

    private func size(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func command(_ arguments: [String], timeout: TimeInterval) async throws -> Data {
        // A temporary output file avoids pipe-buffer deadlocks during long
        // image operations. Never forward tool output containing user paths.
        let result = try await Task.detached(priority: .utility) {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("okvideo-image-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw RuntimeCompressedStorageError.commandFailed
            }
            defer { try? FileManager.default.removeItem(at: output) }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while process.isRunning {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    process.terminate()
                    let grace = ProcessInfo.processInfo.systemUptime + 2
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if process.isRunning {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                    process.waitUntilExit()
                    throw RuntimeCompressedStorageError.commandTimedOut
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard process.terminationStatus == 0 else { throw RuntimeCompressedStorageError.commandFailed }
            let count = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard count <= 16_777_216 else { throw RuntimeCompressedStorageError.commandFailed }
            return try Data(contentsOf: output)
        }.value
        // Do not abandon an in-flight image writer and then let the installer
        // remove its staging files. Cancellation is observed after it exits.
        try Task.checkCancellation()
        return result
    }
}
