import Foundation
import OKVideoCore

/// Negative provenance evidence, not identity. Legacy tokens are opaque and
/// globally stored per kind today; a hold never asserts source ownership.
public struct ImportedReferenceHold: Codable, Equatable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let kind: MigrationReferenceKind
    public let legacyToken: String
    public init(kind: MigrationReferenceKind, legacyToken: String) { self.kind = kind; self.legacyToken = legacyToken }
    public var description: String { "ImportedReferenceHold(<opaque>)" }
    public var debugDescription: String { description }
}

public enum MigrationReferenceKind: String, Codable { case favorite, hidden }

/// A claim survives removal of the value. Absence of stable state is NOT absence
/// of ownership. These are pure diagnostic contracts, not production settings.
public struct ImportedReferenceClaim: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sourceID: UUID
    public let kind: MigrationReferenceKind
    public let legacyToken: String
    public let identity: ImportedLiveChannelIdentity
    public init(sourceID: UUID, kind: MigrationReferenceKind, legacyToken: String, identity: ImportedLiveChannelIdentity) throws {
        guard identity.source == .imported(sourceID) else { throw ImportedChannelRegistryError.invalidRecord }
        self.sourceID = sourceID; self.kind = kind; self.legacyToken = legacyToken; self.identity = identity
    }
    public var description: String { "ImportedReferenceClaim(<authority metadata omitted>)" }
    public var debugDescription: String { description }
}
public struct ImportedStableReferenceState: Codable, Equatable {
    public let identity: ImportedLiveChannelIdentity
    public let kind: MigrationReferenceKind
    public init(identity: ImportedLiveChannelIdentity, kind: MigrationReferenceKind) {
        self.identity = identity; self.kind = kind
    }
}
