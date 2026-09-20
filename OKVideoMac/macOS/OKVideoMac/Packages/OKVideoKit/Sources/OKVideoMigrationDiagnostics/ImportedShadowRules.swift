import Foundation
import OKVideoCore
import OKVideoPersistence

/// 8C.1 diagnostics only. No persistent IDs, authority decisions or parser output.
public enum ImportedShadowRules {
    public enum Classification: String, Codable { case unchanged, split, ambiguous }
    public struct Partition: Codable, Equatable {
        public let tvgID: String?
        public let records: Int
        public let routes: Int
    }
    public struct Group: Codable, Equatable {
        public let group: String
        public let name: String
        public let normalizedGroup: String
        public let normalizedName: String
        public let rawRecords: Int
        public let tvgIDs: [String]
        public let missingIDs: Int
        public let oldChannels: Int
        /// nil means undecided, NOT zero. Partitions never allocate identities.
        public let proposedChannels: Int?
        public let oldRoutes: Int
        /// Route-only experiment under OLD channel topology, not split topology.
        public let routeOnlyProposedRoutes: Int?
        public let proposedRoutes: Int?
        public let sameURLDifferentHeaders: Int
        public let sameURLDifferentProperties: Int
        public let restoredRouteVariants: Int?
        public let classification: Classification
        public let partitions: [Partition]
        public let reasons: [String]
        public let frozen8BReasons: [String]
        public let identityImpact: String
        public let existingIdentities: Int
        public let registryEvidenceCandidates: Int
        public let legacyFavorites: Int
        public let legacyHidden: Int
        public let claimedFavorites: Int
        public let claimedHidden: Int
        public let referenceImpact: String
        public let runtimeKeyRisk: Bool
        public let routeRuntimeKeyRisk: Bool
        public var routeDedupeChange: Bool { routeOnlyProposedRoutes.map { $0 != oldRoutes } ?? false }
    }
    public struct Source: Codable, Equatable {
        public let sourceID: UUID
        public let name: String
        public let format: String
        public let existingIdentities: Int
        public let oldChannels: Int
        public let oldRoutes: Int
        public let rawRecords: Int
        public let groups: [Group]
        public let parseAvailable: Bool
        public var proposedChannels: Int? {
            guard parseAvailable, groups.allSatisfy({ $0.proposedChannels != nil }) else { return nil }
            return groups.reduce(0) { $0 + ($1.proposedChannels ?? 0) }
        }
        public var proposedRoutes: Int? {
            guard parseAvailable, groups.allSatisfy({ $0.proposedRoutes != nil }) else { return nil }
            return groups.reduce(0) { $0 + ($1.proposedRoutes ?? 0) }
        }
        public var counts: [String: Int] { [
            "unchanged": groups.filter { $0.classification == .unchanged && !$0.routeDedupeChange }.count,
            "routeDedupeChange": groups.filter(\.routeDedupeChange).count,
            "split": groups.filter { $0.classification == .split }.count,
            "merge": 0, // No cross-production-channel merge is approved by rule v1.
            "ambiguous": groups.filter { $0.classification == .ambiguous }.count,
            "identityDeferredByFrozen8B": groups.filter { !$0.frozen8BReasons.isEmpty }.count,
            "runtimeKeyRisk": groups.filter(\.runtimeKeyRisk).count,
            "routeRuntimeKeyRisk": groups.filter(\.routeRuntimeKeyRisk).count
        ] }
    }
    // Structured tuple: no delimiter concatenation and no normalization-based merge.
    private struct Name: Hashable { let group: String; let name: String }
    private struct Route: Hashable { let locator: String; let headers: String; let properties: String? }
    private static func name(_ e: ImportedChannelEvidence) -> Name { Name(group: e.group, name: e.name) }
    private static func id(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func routeCount(_ raw: [ImportedRawObservation]) -> Int {
        Set(raw.flatMap(\.lines).map { Route(locator: $0.locatorToken, headers: $0.headersToken, properties: $0.metadataToken) }).count
    }
    private static func safe(_ value: String) -> String { ImportedChannelMigrationPlanner.safeMetadata(value) }

    public static func evaluate(sourceID: UUID, sourceName: String, parsed: ImportedPreMergeEvidence.Parsed,
                                registry: [ImportedChannelRegistryRecord] = [],
                                favorites: [ImportedLegacyReference] = [], hidden: [ImportedLegacyReference] = [],
                                claims: [ImportedReferenceClaim] = []) -> Source {
        evaluate(sourceID: sourceID, sourceName: sourceName, playlist: parsed.playlist,
                 observations: parsed.observations, registry: registry, favorites: favorites, hidden: hidden, claims: claims)
    }
    /// Separate observation input makes permutation invariance testable without
    /// changing the production parser's intentionally ordered presentation.
    static func evaluate(sourceID: UUID, sourceName: String, playlist: LivePlaylist,
                         observations: [ImportedRawObservation], registry: [ImportedChannelRegistryRecord] = [],
                         favorites: [ImportedLegacyReference] = [], hidden: [ImportedLegacyReference] = [],
                         claims: [ImportedReferenceClaim] = []) -> Source {
        let channels = playlist.groups.flatMap(\.channels)
        let rawBuckets = Dictionary(grouping: observations) { name($0.evidence) }
        let oldBuckets = Dictionary(grouping: channels) { Name(group: $0.groupName, name: $0.name) }
        let runtimeCounts = Dictionary(grouping: channels, by: \.id).mapValues(\.count)
        // Topology unchanged is NOT permission to allocate deferred identities.
        let frozenRisks = ImportedChannelMigrationPlanner.splitRisks(observations)
        let owned = registry.filter { $0.identity.source == .imported(sourceID) }
        let recordsByName = Dictionary(grouping: owned) { name($0.evidence) }
        let normalizedRegistry = Dictionary(grouping: owned) {
            Name(group: ImportedChannelReconciler.normalizeName($0.evidence.group), name: ImportedChannelReconciler.normalizeName($0.evidence.name))
        }
        let registryTVG = Dictionary(grouping: owned.filter { id($0.evidence.tvgID) != nil }) { id($0.evidence.tvgID)! }
        let incomingTVG = Dictionary(grouping: rawBuckets.keys.flatMap { n in
            Set(rawBuckets[n]!.compactMap { id($0.evidence.tvgID) }).map { ($0, n) }
        }, by: { $0.0 }).mapValues { Set($0.map { $0.1 }).count }
        let favoriteTokens = Set(favorites.map(\.rawValue)), hiddenTokens = Set(hidden.map(\.rawValue))
        let ownClaims = claims.filter { $0.sourceID == sourceID }
        let allNames = Set(rawBuckets.keys).union(oldBuckets.keys)
        let calculatedIDs = Dictionary(grouping: allNames) { "\($0.group)::\($0.name)" }.mapValues(\.count)
        let normalizedIncoming = Dictionary(grouping: allNames) {
            Name(group: ImportedChannelReconciler.normalizeName($0.group), name: ImportedChannelReconciler.normalizeName($0.name))
        }.mapValues(\.count)
        let result = allNames.sorted { [$0.group, $0.name].lexicographicallyPrecedes([$1.group, $1.name]) }.map { n -> Group in
            let raw = rawBuckets[n] ?? [], old = oldBuckets[n] ?? [], existing = recordsByName[n] ?? []
            let ids = Set(raw.compactMap { id($0.evidence.tvgID) })
            let missing = raw.filter { id($0.evidence.tvgID) == nil }.count
            let lines = raw.flatMap(\.lines)
            let locators = Dictionary(grouping: lines, by: \.locatorToken)
            let headerConflicts = locators.values.filter { Set($0.map(\.headersToken)).count > 1 }.count
            let propertyConflicts = locators.values.filter { Set($0.map(\.metadataToken)).count > 1 }.count
            let routes = routeCount(raw)
            let oldRoutes = old.reduce(0) { $0 + $1.streams.count }
            let legacyIDs = Set(old.map(\.id))
            let frozenReasons = Set(legacyIDs.flatMap { frozenRisks[$0] ?? [] }).sorted()
            let favKeys = Set(legacyIDs.map { ImportedChannelMigrationPlanner.favoriteKey(sourceName: sourceName, channelID: $0) })
            let hiddenKeys = Set(legacyIDs.map { ImportedChannelMigrationPlanner.hiddenKey(sourceID: sourceID, channelID: $0) })
            let legacyFav = favKeys.intersection(favoriteTokens).count
            let legacyHid = hiddenKeys.intersection(hiddenTokens).count
            let existingIDs = Set(existing.map(\.identity))
            let relevantClaims = ownClaims.filter { existingIDs.contains($0.identity) ||
                ($0.kind == .favorite ? favKeys : hiddenKeys).contains($0.legacyToken) }
            let claimedFav = relevantClaims.filter { $0.kind == .favorite }.count
            let claimedHid = relevantClaims.filter { $0.kind == .hidden }.count
            var reasons: [String] = []
            let classification: Classification
            let partitions: [[ImportedRawObservation]]
            let collision = old.contains { (runtimeCounts[$0.id] ?? 0) > 1 } || (calculatedIDs["\(n.group)::\(n.name)"] ?? 0) > 1
            // Optional metadata disagreements are only a veto; never positive
            // identity evidence, and never absorbed by whichever record came first.
            let bucketsByID = Dictionary(grouping: raw) { id($0.evidence.tvgID) ?? "" }
            let metadataConflict = bucketsByID.values.contains { records in
                Set(records.compactMap { id($0.tvgName) }).count > 1 || Set(records.map(\.metadataToken)).count > 1
            }
            if raw.isEmpty || old.isEmpty {
                classification = .ambiguous; partitions = []; reasons.append("incompleteObservationCoverage")
            } else if collision || old.count != 1 {
                classification = .ambiguous; partitions = []; reasons.append("existingRuntimeCollisionOrUnapprovedCrossChannelMerge")
            } else if missing > 0 && !ids.isEmpty {
                classification = .ambiguous; partitions = []; reasons.append("mixedPresentMissingIDNoGreedyAbsorption")
            } else if metadataConflict {
                classification = .ambiguous; partitions = []; reasons.append("optionalMetadataDisagreementDeferred")
            } else if ids.count > 1 {
                classification = .split
                partitions = ids.sorted().map { value in raw.filter { id($0.evidence.tvgID) == value } }
                reasons.append("distinctNonblankTVGIDsStrongSplitEvidenceNotPermanentIdentity")
            } else {
                classification = .unchanged; partitions = [raw]
                reasons.append(ids.isEmpty ? "provisionalSameChannelMultiRouteNoPermanentIdentityProof" : "sameGroupNameAndIDNoContradictoryEvidence")
            }
            if headerConflicts > 0 { reasons.append("sameURLDifferentHeadersRouteEvidenceOnly") }
            if propertyConflicts > 0 { reasons.append("sameURLDifferentPlaybackPropertiesRouteEvidenceOnly") }
            let normalized = Name(group: ImportedChannelReconciler.normalizeName(n.group), name: ImportedChannelReconciler.normalizeName(n.name))
            let competingRegistry = Set((normalizedRegistry[normalized] ?? []).map(\.identity))
                .union(ids.flatMap { (registryTVG[$0] ?? []).map(\.identity) })
            let tvgShared = ids.contains { (incomingTVG[$0] ?? 0) > 1 }
            let identityImpact: String
            if !frozenReasons.isEmpty { identityImpact = "deferredByFrozen8BNoIdentityTransfer" }
            else if classification != .unchanged { identityImpact = "deferredNoIdentityTransfer" }
            else if existing.count == 1, existing[0].lifecycle == .active, existing[0].provenance == .verified,
                    competingRegistry.isSubset(of: existingIDs), !tvgShared,
                    normalizedIncoming[normalized] == 1, raw.allSatisfy({ $0.evidence == existing[0].evidence }),
                    id(existing[0].evidence.tvgID) == ids.first {
                identityImpact = "uniqueExactEvidenceCandidateRequiresFullReconciliation"
            } else if existing.isEmpty && competingRegistry.isEmpty { identityImpact = "noRegistryIdentityAllocationNotPerformed" }
            else { identityImpact = "unresolvedRegistryEvidenceDoNotSelectFirst" }
            if tvgShared { reasons.append("sameTVGIDAcrossGroupsOrNamesNoAutomaticKinship") }
            let references = legacyFav + legacyHid + claimedFav + claimedHid
            let impact = references == 0 ? "noAssociatedReferenceObserved" :
                (classification != .unchanged ? "preserveNoBroadcastOneToManyOrUnresolved" :
                    "preserveExistingAuthorityLegacyFavoriteProvenanceNotPromoted")
            return Group(group: safe(n.group), name: safe(n.name), normalizedGroup: safe(normalized.group), normalizedName: safe(normalized.name),
                rawRecords: raw.count, tvgIDs: ids.map(safe).sorted(), missingIDs: missing,
                oldChannels: old.count, proposedChannels: classification == .ambiguous ? nil : partitions.count,
                oldRoutes: oldRoutes, routeOnlyProposedRoutes: old.count == 1 ? routes : nil,
                proposedRoutes: classification == .ambiguous ? nil : partitions.reduce(0) { $0 + routeCount($1) },
                sameURLDifferentHeaders: headerConflicts, sameURLDifferentProperties: propertyConflicts,
                restoredRouteVariants: old.count == 1 ? max(0, routes - oldRoutes) : nil,
                classification: classification, partitions: partitions.map {
                    Partition(tvgID: $0.compactMap { id($0.evidence.tvgID) }.first.map(safe), records: $0.count, routes: routeCount($0))
                }, reasons: reasons.sorted(), frozen8BReasons: frozenReasons, identityImpact: identityImpact, existingIdentities: existing.count,
                registryEvidenceCandidates: competingRegistry.count,
                legacyFavorites: legacyFav, legacyHidden: legacyHid, claimedFavorites: claimedFav, claimedHidden: claimedHid,
                referenceImpact: impact, runtimeKeyRisk: collision || classification == .split,
                routeRuntimeKeyRisk: headerConflicts > 0 || propertyConflicts > 0)
        }
        return Source(sourceID: sourceID, name: safe(sourceName), format: playlist.format.rawValue,
            existingIdentities: owned.count, oldChannels: channels.count, oldRoutes: channels.reduce(0) { $0 + $1.streams.count },
            rawRecords: observations.count, groups: result, parseAvailable: true)
    }
}
