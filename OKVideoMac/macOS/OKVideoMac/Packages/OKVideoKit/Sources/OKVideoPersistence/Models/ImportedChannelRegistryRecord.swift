import Foundation
import OKVideoCore

public enum ImportedChannelRegistryLifecycle: String, Codable, Sendable {
    case active, missing, unresolved, retired
}

public enum ImportedChannelRegistryError: Error, Equatable {
    case unsupportedSource, unsupportedVersion, unsupportedFields, invalidRecord
    case unsafeEvidence, invalidTimestamp, staleUpdate
}

/// A registry record wraps the ONE Core identity/evidence contract. No parser,
/// favorite/hidden reference, locator, raw response or normalized-key cache lives
/// here. Dates and UUIDs are caller-supplied; persistence makes no lifecycle choices.
public struct ImportedChannelRegistryRecord: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let currentRecordVersion = 1
    public static let currentEvidenceVersion = 1
    public let identity: ImportedLiveChannelIdentity
    public let recordVersion: Int
    public let evidenceVersion: Int
    public let lifecycle: ImportedChannelRegistryLifecycle
    public let provenance: ImportedSourceProvenance
    public let evidence: ImportedChannelEvidence
    public let createdAt: Date
    public let updatedAt: Date

    public init(identity: ImportedLiveChannelIdentity, evidence: ImportedChannelEvidence,
                provenance: ImportedSourceProvenance, lifecycle: ImportedChannelRegistryLifecycle,
                createdAt: Date, updatedAt: Date,
                recordVersion: Int = Self.currentRecordVersion,
                evidenceVersion: Int = Self.currentEvidenceVersion) {
        self.identity = identity
        self.evidence = evidence
        self.provenance = provenance
        self.lifecycle = lifecycle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recordVersion = recordVersion
        self.evidenceVersion = evidenceVersion
    }
    public var description: String { "ImportedChannelRegistryRecord(\(identity.localID), <metadata>)" }
    public var debugDescription: String { description }
}

/// Explicit operations only. Removing a live_sources row never calls these APIs
/// or cascades into the registry. Future business integration owns that decision.
public enum ImportedChannelRegistryMutation: Sendable {
    case upsert(ImportedChannelRegistryRecord)
    case remove(ImportedLiveChannelIdentity)
    case removeAll(source: LiveSourceID)
}
