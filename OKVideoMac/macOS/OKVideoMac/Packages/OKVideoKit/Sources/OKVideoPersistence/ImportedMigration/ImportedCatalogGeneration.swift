import Foundation
import OKVideoCore

/// Revocable admission, separate from the session HMAC. Revocation and commit
/// are serialized: a transaction already committing finishes before revocation;
/// work arriving after revocation cannot write. Never shared with the Player.
public final class ImportedCatalogGeneration: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var active = true
    public let sourceID: UUID
    public init(sourceID: UUID) { self.sourceID = sourceID }
    public func invalidate() { lock.lock(); defer { lock.unlock() }; active = false }
    public var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func admit<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw ImportedExecutionError.stalePlan }
        return try body()
    }
}

/// Immutable presentation projection. No SQL in cards and no IDs inferred from
/// array order or a legacy string. Full channel values are compared fail-closed.
public struct ImportedCatalogMapping {
    public let sourceID: UUID
    public let generation: ImportedCatalogGeneration
    let plan: ImportedExecutionPlan
    let session: ImportedMigrationExecutionSession
    public func value(channel: LiveChannel, kind: MigrationReferenceKind) -> Bool? {
        guard generation.isCurrent else { return nil }
        return session.value(plan, sourceID: sourceID, channel: channel, kind: kind)
    }
    public func authority(channel: LiveChannel, kind: MigrationReferenceKind) -> ImportedReferenceAuthority {
        guard generation.isCurrent else { return .blocked }
        return session.authority(plan, sourceID: sourceID, channel: channel, kind: kind)
    }
}
