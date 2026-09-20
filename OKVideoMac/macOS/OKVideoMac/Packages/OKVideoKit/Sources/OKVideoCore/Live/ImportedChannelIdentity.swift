import Foundation

public enum ImportedIdentityError: Error, Equatable {
    case unsupportedSource
    case duplicateExistingIdentity
    case duplicateCandidateID
}

/// Durable identity, not a metadata hash. The future owner allocates localID once,
/// persists it transactionally, and reuses it only after a successful reconciliation.
/// This type neither generates UUIDs nor changes LiveChannel / LiveStream identity.
public struct ImportedLiveChannelIdentity: Hashable, Codable, Sendable {
    private let sourceUUID: UUID
    public let localID: UUID
    public var source: LiveSourceID { .imported(sourceUUID) }

    public init(source: LiveSourceID, localID: UUID) throws {
        guard case .imported(let id) = source else { throw ImportedIdentityError.unsupportedSource }
        sourceUUID = id
        self.localID = localID
    }

    private enum CodingKeys: String, CodingKey { case kind, sourceID, localID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .kind) == "imported" else {
            throw ImportedIdentityError.unsupportedSource
        }
        sourceUUID = try values.decode(UUID.self, forKey: .sourceID)
        localID = try values.decode(UUID.self, forKey: .localID)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("imported", forKey: .kind)
        try values.encode(sourceUUID, forKey: .sourceID)
        try values.encode(localID, forKey: .localID)
    }
}

/// Unknown legacy ownership cannot be inferred from a currently unique source name.
public enum ImportedSourceProvenance: String, Codable, Sendable { case verified, unknown }

/// Never split this token on "::". No schema/ownership inference belongs in 8A.
public struct ImportedLegacyReference: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { "ImportedLegacyReference(<opaque>)" }
    public var debugDescription: String { description }
}

public struct ImportedUpstreamEvidence: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Identifies the upstream format's ID domain, not an endpoint or credential.
    public let namespace: String
    public let value: String
    /// Caller attests the format supports stable IDs. Batch uniqueness is checked
    /// independently by the reconciler, on both existing and incoming catalogs.
    public let formatSupportsStableID: Bool

    public init(namespace: String, value: String, formatSupportsStableID: Bool) {
        self.namespace = namespace
        self.value = value
        self.formatSupportsStableID = formatSupportsStableID
    }
    public var description: String { "ImportedUpstreamEvidence(<metadata>)" }
    public var debugDescription: String { description }
}

/// A logical-channel observation, NOT an unmerged playlist line. URLs, credentials,
/// headers, line order/count and EPG programme availability are intentionally absent.
/// Zero, one or many playback lines do not alter the identity contract.
public struct ImportedChannelEvidence: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let upstream: ImportedUpstreamEvidence?
    public let group: String
    public let name: String
    public let tvgID: String?
    public let region: String?
    public let language: String?
    public let channelType: String?

    public init(group: String, name: String, upstream: ImportedUpstreamEvidence? = nil,
                tvgID: String? = nil, region: String? = nil, language: String? = nil,
                channelType: String? = nil) {
        self.group = group
        self.name = name
        self.upstream = upstream
        self.tvgID = tvgID
        self.region = region
        self.language = language
        self.channelType = channelType
    }
    public var description: String { "ImportedChannelEvidence(<metadata>)" }
    public var debugDescription: String { description }
}

public struct ImportedExistingChannel: Sendable {
    public let identity: ImportedLiveChannelIdentity
    public let evidence: ImportedChannelEvidence
    public init(identity: ImportedLiveChannelIdentity, evidence: ImportedChannelEvidence) {
        self.identity = identity
        self.evidence = evidence
    }
}

public struct ImportedChannelCandidate: Sendable {
    /// Caller-provided correlation token, stable across permutations of this batch.
    /// This is NOT a newly allocated permanent channel identity.
    public let candidateID: UUID
    public let source: LiveSourceID
    public let provenance: ImportedSourceProvenance
    public let evidence: ImportedChannelEvidence
    public let legacyReference: ImportedLegacyReference?

    public init(candidateID: UUID, source: LiveSourceID, provenance: ImportedSourceProvenance,
                evidence: ImportedChannelEvidence, legacyReference: ImportedLegacyReference? = nil) {
        self.candidateID = candidateID
        self.source = source
        self.provenance = provenance
        self.evidence = evidence
        self.legacyReference = legacyReference
    }
}
