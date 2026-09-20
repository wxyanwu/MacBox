import Foundation

public enum ImportedReconciliationOutcome: Equatable, Sendable {
    case matched(ImportedLiveChannelIdentity)
    case newIdentityRequired
    case ambiguous
    case conflict
    case unresolved
}

public enum ImportedReconciliationReason: String, Hashable, Sendable {
    case incompleteCatalog, unknownSourceProvenance, unsupportedSource
    case duplicateUpstreamID, evidenceDisagreement, metadataConflict
    case multipleCandidates, multipleIncomingClaims, insufficientEvidence, noExistingCandidate
}

public enum ImportedEvidenceKind: String, CaseIterable, Sendable {
    case upstreamID, tvgID, exactName, normalizedName
}

/// Bounded diagnostics: no raw values and no per-result expansion of large alias
/// buckets. Counts refer to distinct old identities in this source only.
public struct ImportedEvidenceObservation: Equatable, Sendable {
    public let kind: ImportedEvidenceKind
    public let existingCount: Int
    public let incomingCount: Int
    public let uniqueIdentity: ImportedLiveChannelIdentity?
    public let isStrong: Bool
}

public struct ImportedReconciliationResult: Equatable, Sendable {
    public let candidateID: UUID
    public internal(set) var outcome: ImportedReconciliationOutcome
    public internal(set) var reasons: Set<ImportedReconciliationReason>
    public let evidence: [ImportedEvidenceObservation]
}

/// Pure, batch-only planning. Not called by the production import/refresh paths.
///
/// Both inventories must contain all logical-channel records for the sources being
/// reconciled (not visible rows or raw playlist lines). Otherwise uniqueness cannot
/// be established: catalogsAreComplete=false fails closed. The caller must also
/// retain missing/tombstoned identities in its future registry rather than recycle
/// their IDs. Source deletion/re-addition is a different source UUID by default.
///
/// Expected index construction/query work is linear in input size and text length;
/// sorting result tokens is O(C log C). There is no old x new scan, nor expansion
/// of a shared many-candidate bucket for every incoming record.
public enum ImportedChannelReconciler {
    public static func normalizeName(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    public static func reconcile(existing: [ImportedExistingChannel],
                                 candidates: [ImportedChannelCandidate],
                                 catalogsAreComplete: Bool) throws -> [ImportedReconciliationResult] {
        var records: [ImportedLiveChannelIdentity: ImportedChannelEvidence] = [:]
        var oldIndex: [Key: Set<ImportedLiveChannelIdentity>] = [:]
        var incomingCounts: [Key: Int] = [:]
        var candidateIDs = Set<UUID>()
        for record in existing {
            guard records.updateValue(record.evidence, forKey: record.identity) == nil else {
                throw ImportedIdentityError.duplicateExistingIdentity
            }
            for key in keys(record.evidence, source: record.identity.source) {
                oldIndex[key, default: []].insert(record.identity)
            }
        }
        for candidate in candidates {
            guard candidateIDs.insert(candidate.candidateID).inserted else {
                throw ImportedIdentityError.duplicateCandidateID
            }
            if candidate.provenance == .verified {
                for key in keys(candidate.evidence, source: candidate.source) {
                    incomingCounts[key, default: 0] += 1
                }
            }
        }

        var results = candidates.map { candidate -> ImportedReconciliationResult in
            func result(_ outcome: ImportedReconciliationOutcome,
                        _ reasons: Set<ImportedReconciliationReason>,
                        _ observations: [ImportedEvidenceObservation] = []) -> ImportedReconciliationResult {
                ImportedReconciliationResult(candidateID: candidate.candidateID, outcome: outcome,
                                             reasons: reasons, evidence: observations)
            }
            guard case .imported = candidate.source else { return result(.unresolved, [.unsupportedSource]) }
            guard candidate.provenance == .verified else { return result(.unresolved, [.unknownSourceProvenance]) }
            guard catalogsAreComplete else { return result(.unresolved, [.incompleteCatalog]) }

            // Collect every relevant bucket before choosing an outcome. A strong
            // match never silently overrides evidence pointing at a different ID.
            let lookups = keys(candidate.evidence, source: candidate.source).map { key in
                (key: key, ids: oldIndex[key] ?? [], incoming: incomingCounts[key] ?? 0)
            }
            let observations = lookups.map { lookup -> ImportedEvidenceObservation in
                let sole = lookup.ids.count == 1 ? lookup.ids.first : nil
                let strong = lookup.key.kind == .upstreamID && lookup.incoming == 1
                    && candidate.evidence.upstream?.formatSupportsStableID == true
                    && sole.flatMap { records[$0]?.upstream?.formatSupportsStableID } == true
                return ImportedEvidenceObservation(kind: lookup.key.kind, existingCount: lookup.ids.count,
                    incomingCount: lookup.incoming, uniqueIdentity: sole, isStrong: strong)
            }
            var conflicts = Set<ImportedReconciliationReason>()
            if lookups.contains(where: { $0.key.kind == .upstreamID && ($0.ids.count > 1 || $0.incoming > 1) }) {
                conflicts.insert(.duplicateUpstreamID)
            }
            let uniqueIDs = Set(observations.compactMap(\.uniqueIdentity))
            if uniqueIDs.count > 1 { conflicts.insert(.evidenceDisagreement) }
            // At most four singleton anchors. Membership checks stay O(1), even
            // when an alias has thousands of distinct old channel candidates.
            for id in uniqueIDs where lookups.contains(where: { !$0.ids.isEmpty && !$0.ids.contains(id) }) {
                conflicts.insert(.evidenceDisagreement)
            }
            if !conflicts.isEmpty { return result(.conflict, conflicts, observations) }

            let strongID = observations.first(where: { $0.isStrong })?.uniqueIdentity
            if strongID == nil, lookups.contains(where: { $0.ids.count > 1 }) {
                return result(.ambiguous, [.multipleCandidates], observations)
            }
            if strongID == nil, lookups.contains(where: {
                ($0.key.kind == .normalizedName || $0.key.kind == .tvgID) && $0.incoming > 1
            }) {
                return result(.ambiguous, [.multipleIncomingClaims], observations)
            }
            guard let id = strongID ?? uniqueIDs.first, let old = records[id] else {
                // In particular, a legacy favorite with no current match is not
                // authorization to allocate a replacement and attach old state.
                let hasName = nonblank(candidate.evidence.name) != nil
                let hasVerifiedID = candidate.evidence.upstream?.formatSupportsStableID == true
                    && upstreamKey(candidate.evidence) != nil
                if candidate.legacyReference == nil && (hasName || hasVerifiedID) {
                    return result(.newIdentityRequired, [.noExistingCandidate], observations)
                }
                return result(.unresolved, [.insufficientEvidence], observations)
            }

            if metadataConflicts(old, candidate.evidence, strongMatch: strongID != nil) {
                return result(.conflict, [.metadataConflict], observations)
            }
            let nameSupport = observations.contains {
                ($0.kind == .exactName || $0.kind == .normalizedName) && $0.uniqueIdentity == id
            }
            guard strongID != nil || nameSupport else {
                return result(.unresolved, [.insufficientEvidence], observations)
            }
            return result(.matched(id), [], observations)
        }

        // One old channel must not be assigned to two new logical channels, even
        // when each individual query appears unique using different evidence.
        var claims: [ImportedLiveChannelIdentity: Int] = [:]
        for result in results {
            if case .matched(let id) = result.outcome { claims[id, default: 0] += 1 }
        }
        for index in results.indices {
            if case .matched(let id) = results[index].outcome, claims[id, default: 0] > 1 {
                results[index].outcome = .ambiguous
                results[index].reasons.insert(.multipleIncomingClaims)
            }
        }
        return results.sorted { $0.candidateID.uuidString < $1.candidateID.uuidString }
    }

    // Structured fields deliberately avoid group/name delimiter collisions.
    private struct Key: Hashable {
        let source: LiveSourceID
        let kind: ImportedEvidenceKind
        let first: String
        let second: String
    }
    private static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func upstreamKey(_ value: ImportedChannelEvidence) -> (String, String)? {
        guard let upstream = value.upstream, let namespace = nonblank(upstream.namespace),
              let id = nonblank(upstream.value) else { return nil }
        return (namespace, id)
    }
    private static func keys(_ value: ImportedChannelEvidence, source: LiveSourceID) -> [Key] {
        var result: [Key] = []
        if let (namespace, id) = upstreamKey(value) {
            result.append(Key(source: source, kind: .upstreamID, first: namespace, second: id))
        }
        if let tvgID = nonblank(value.tvgID) {
            result.append(Key(source: source, kind: .tvgID, first: tvgID, second: ""))
        }
        if nonblank(value.name) != nil {
            result.append(Key(source: source, kind: .exactName, first: value.group, second: value.name))
            result.append(Key(source: source, kind: .normalizedName,
                              first: normalizeName(value.group), second: normalizeName(value.name)))
        }
        return result
    }
    private static func metadataConflicts(_ old: ImportedChannelEvidence,
                                          _ new: ImportedChannelEvidence, strongMatch: Bool) -> Bool {
        for (a, b) in [(old.region, new.region), (old.language, new.language), (old.channelType, new.channelType)] {
            if let a = nonblank(a), let b = nonblank(b), normalizeName(a) != normalizeName(b) { return true }
        }
        if let a = upstreamKey(old), let b = upstreamKey(new), a != b { return true }
        // A corrected guide ID is allowed only with independent verified stable
        // evidence. Conflicting references to another old ID were checked above.
        if !strongMatch, let a = nonblank(old.tvgID), let b = nonblank(new.tvgID), a != b { return true }
        return false
    }
}
