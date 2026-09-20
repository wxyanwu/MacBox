import Foundation
import Darwin

/// Explicit acceptance capability. No default Library path or recovery fallback.
public struct ImportedAcceptanceWorkspace {
    public let root: URL
    public var support: URL { root.appendingPathComponent("Application Support") }
    public var caches: URL { root.appendingPathComponent("Caches") }
    public var databaseURL: URL { support.appendingPathComponent("Database/OKVideoMac.sqlite3") }

    public init(root: URL) throws {
        let resolved = try Self.canonical(root)
        guard resolved.path == root.path,
              resolved.deletingLastPathComponent().path == "/private/tmp",
              resolved.lastPathComponent.hasPrefix("OKVideoMac-8B3B-") else { throw AcceptanceError.unsafeWorkspace }
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw AcceptanceError.unsafeWorkspace }
        self.root = resolved
        try validate()
    }

    public func validate() throws {
        // Reject links anywhere in the workspace BEFORE opening SQLite,
        // creating directories, chmod, recovery, or constructing cache services.
        let fm = FileManager.default
        guard try Self.canonical(root).path == root.path else { throw AcceptanceError.unsafeWorkspace }
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { throw AcceptanceError.unsafeWorkspace }
        for case let url as URL in iterator {
            let a = try fm.attributesOfItem(atPath: url.path)
            guard a[.type] as? FileAttributeType != .typeSymbolicLink,
                  try Self.canonical(url).path.hasPrefix(root.path + "/") else { throw AcceptanceError.unsafeWorkspace }
            if a[.type] as? FileAttributeType == .typeRegular,
               (a[.referenceCount] as? NSNumber)?.intValue != 1 { throw AcceptanceError.unsafeWorkspace }
        }
    }
    private static func canonical(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw AcceptanceError.unsafeWorkspace }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }
    public enum AcceptanceError: Error { case unsafeWorkspace }
}
