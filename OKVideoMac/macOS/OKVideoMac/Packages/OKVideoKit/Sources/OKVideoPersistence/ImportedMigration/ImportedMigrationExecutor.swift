import Foundation
import CryptoKit
import OKVideoCore

public enum ImportedExecutionError: Error { case stalePlan, corruption, blocked }
public enum ImportedExecutionDisposition: String, Encodable { case allocate, matched, deferred, blocked }
public enum ImportedReferenceAuthority: Equatable, Encodable {
    case legacy
    case stable(ImportedLiveChannelIdentity)
    case blocked
}
public struct ImportedExecutionRow: Encodable {
    public let sourceID: UUID
    public let group: String
    public let name: String
    public let disposition: ImportedExecutionDisposition
    public let identity: ImportedLiveChannelIdentity?
    public let reasons: [String]
    public let favoriteAuthority: ImportedReferenceAuthority
    public let hiddenAuthority: ImportedReferenceAuthority
}
private struct ExecutionEntry {
    let sourceID: UUID
    let sourceName: String
    let channel: LiveChannel
    let evidence: ImportedChannelEvidence
    var disposition: ImportedExecutionDisposition
    var identity: ImportedLiveChannelIdentity?
    let identityMappingTrusted: Bool
    var reasons: [String]
    var newClaims: [(MigrationReferenceKind, String)] = []
    var favorite: ImportedReferenceAuthority = .legacy
    var hidden: ImportedReferenceAuthority = .legacy
    func token(_ kind: MigrationReferenceKind) -> String {
        kind == .hidden ? ImportedChannelMigrationPlanner.hiddenKey(sourceID: sourceID, channelID: channel.id)
            : ImportedChannelMigrationPlanner.favoriteKey(sourceName: sourceName, channelID: channel.id)
    }
}
public struct ImportedExecutionPlan: CustomStringConvertible, CustomDebugStringConvertible {
    public let planFingerprint: String
    public let rows: [ImportedExecutionRow]
    fileprivate let input: ImportedAdmissionInput
    fileprivate let entries: [ExecutionEntry]
    fileprivate let newHolds: [ImportedReferenceHold]
    public var counts: [String: Int] { Dictionary(grouping: rows, by: { $0.disposition.rawValue }).mapValues(\.count) }
    public var claimsRequired: Int { entries.reduce(0) { $0 + $1.newClaims.count } }
    public var description: String { "ImportedExecutionPlan(<session-bound snapshot>)" }
    public var debugDescription: String { description }
    public func json() throws -> Data {
        struct Report: Encodable {
            let version = 2; let sessionBound = true; let executableReport = false
            let planFingerprint: String; let counts: [String: Int]; let rows: [ImportedExecutionRow]
            let claimsRequired: Int; let existingClaims: Int; let preservedHolds: Int
        }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(Report(planFingerprint: planFingerprint, counts: counts, rows: rows,
            claimsRequired: claimsRequired, existingClaims: input.claims.count, preservedHolds: input.holds.count + newHolds.count))
    }
}
public struct ImportedExecutionResult: Codable, Equatable {
    public let allocated: Int
    public let claimed: Int
    public let preservedHolds: Int
    public let batchRecorded: Bool
}

/// Plan authorization is session-only. Durable idempotency comes from Registry
/// and claims, NEVER a persisted fingerprint or a source-completed flag.
public final class ImportedMigrationExecutionSession {
    private let key = SymmetricKey(size: .bits256)
    public init() {}
    private func fingerprint(_ input: ImportedAdmissionInput) throws -> String {
        HMAC<SHA256>.authenticationCode(for: try input.canonical(), using: key).map { String(format: "%02x", $0) }.joined()
    }
    @_spi(ImportedMigration) public func prepare(_ snapshot: ImportedMigrationStoreSnapshot) throws -> ImportedExecutionPlan {
        let active = Set(snapshot.sources.map { LiveSourceID.imported($0.id) })
        let records = snapshot.schemaVersion < 12 ? snapshot.registry : snapshot.registry.filter { active.contains($0.identity.source) }
        let identities = Set(records.map(\.identity))
        var input = ImportedAdmissionInput(sources: snapshot.sources, registry: records,
            favorites: snapshot.favorites, hidden: snapshot.hidden,
            claims: snapshot.claims.filter { identities.contains($0.identity) },
            stable: snapshot.stable.filter { identities.contains($0.identity) },
            schemaVersion: snapshot.schemaVersion)
        input.holds = snapshot.holds
        input.retirementBlocks = snapshot.retirementBlocks
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Full historical records remain bound to authorization and validated by
        // snapshot(), but NEVER participate in current reconciliation.
        var historical = ImportedAdmissionInput(sources: [], registry: snapshot.registry,
            claims: snapshot.claims, stable: snapshot.stable, schemaVersion: snapshot.schemaVersion)
        historical.markers = snapshot.sourceHistory.map { "\($0.id.uuidString):\($0.retiredAt?.timeIntervalSince1970.description ?? "active")" }.sorted()
        input.historicalBinding = try historical.canonical()
        input.markers = try snapshot.batches.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        input.plannerVersion = 2; input.policyVersion = 2
        return try prepareInput(input)
    }
    func prepareInput(_ input: ImportedAdmissionInput) throws -> ImportedExecutionPlan {
        guard [11, 12].contains(input.schemaVersion), input.plannerVersion == 2, input.policyVersion == 2, input.evidenceVersion == 1 else { throw ImportedExecutionError.blocked }
        let known = Set(input.registry.map(\.identity)), sources = Set(input.sources.map { LiveSourceID.imported($0.id) })
        guard known.count == input.registry.count, sources.count == input.sources.count,
              input.registry.allSatisfy({ sources.contains($0.identity.source) }),
              input.claims.allSatisfy({ $0.identity.source == .imported($0.sourceID) && known.contains($0.identity) }),
              input.stable.allSatisfy({ state in input.claims.contains { $0.identity == state.identity && $0.kind == state.kind } }) else { throw ImportedExecutionError.corruption }
        struct ReferenceKey: Hashable { let kind: MigrationReferenceKind; let token: String }
        let existingClaims = Dictionary(grouping: input.claims) { ReferenceKey(kind: $0.kind, token: $0.legacyToken) }
        for claims in existingClaims.values {
            let bySource = Dictionary(grouping: claims, by: \.sourceID)
            guard bySource.values.allSatisfy({ Set($0.map(\.identity)).count == 1 }) else { throw ImportedExecutionError.corruption }
        }
        guard !input.holds.contains(where: { existingClaims[ReferenceKey(kind: $0.kind, token: $0.legacyToken)] != nil }) else { throw ImportedExecutionError.corruption }
        var entries: [ExecutionEntry] = []
        for source in input.sources.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let parsed = try ImportedPreMergeEvidence.parse(source.rawData, baseURL: source.baseURL)
            let channels = parsed.playlist.groups.flatMap(\.channels)
            let records = input.registry.filter { $0.identity.source == .imported(source.id) }
            let complete = records.allSatisfy { $0.provenance == .verified && $0.lifecycle == .active && $0.recordVersion == 1 && $0.evidenceVersion == 1 }
            let candidates = channels.map { channel in ImportedChannelCandidate(candidateID: UUID(), source: .imported(source.id),
                provenance: .verified, evidence: ImportedChannelEvidence(group: channel.groupName, name: channel.name, tvgID: channel.tvgID)) }
            // Correlation UUIDs are ephemeral tokens owned by this batch, NOT
            // identities. They attach reconciliation results to full input objects.
            let results = try ImportedChannelReconciler.reconcile(existing: records.map { ImportedExistingChannel(identity: $0.identity, evidence: $0.evidence) },
                candidates: candidates, catalogsAreComplete: complete)
            let outcomes = Dictionary(uniqueKeysWithValues: results.map { ($0.candidateID, $0) })
            let risks = ImportedPreMergeEvidence.analyze(parsed.observations,
                channels: zip(channels, candidates).map { MigrationChannel(legacyChannelID: $0.0.id, evidence: $0.1.evidence) }).risks
            // FULL catalog reconciled above; no deferred filtering before uniqueness.
            for (channel, candidate) in zip(channels, candidates) {
                guard let result = outcomes[candidate.candidateID] else { throw ImportedExecutionError.corruption }
                var state: ImportedExecutionDisposition; var identity: ImportedLiveChannelIdentity?
                switch result.outcome {
                case .matched(let id): state = .matched; identity = id
                case .newIdentityRequired: state = .allocate
                default: state = .blocked
                }
                var reasons = result.reasons.map(\.rawValue)
                if let risk = risks[channel.id], !risk.isEmpty { state = .deferred; reasons += risk }
                entries.append(ExecutionEntry(sourceID: source.id, sourceName: source.name, channel: channel,
                    evidence: candidate.evidence, disposition: state, identity: identity,
                    identityMappingTrusted: state == .matched, reasons: reasons.sorted()))
            }
        }
        var tokens: [ReferenceKey: [Int]] = [:]
        for i in entries.indices { for kind in [MigrationReferenceKind.favorite, .hidden] {
            tokens[ReferenceKey(kind: kind, token: entries[i].token(kind)), default: []].append(i)
        } }
        var newHolds = Set<ImportedReferenceHold>()
        for (kind, refs) in [(MigrationReferenceKind.favorite, input.favorites), (.hidden, input.hidden)] {
            for token in Set(refs.map(\.rawValue)).sorted() {
                let key = ReferenceKey(kind: kind, token: token)
                let matches = tokens[key] ?? []
                if existingClaims[key] != nil { continue } // Claim, not legacy value, owns state now.
                // Retirement evidence is neither a claim nor an eligibility
                // hold. Do not manufacture a hold conflicting with a historical claim.
                if input.retirementBlocks.contains(where: { $0.kind == kind && $0.tokenDigest == ImportedRetirementReferenceBlock.digest(token) }) { continue }
                let hold = ImportedReferenceHold(kind: kind, legacyToken: token)
                let safe = kind == .hidden && matches.count == 1 && !input.holds.contains(hold)
                    && [.allocate, .matched].contains(entries[matches[0]].disposition)
                if safe { entries[matches[0]].newClaims.append((kind, token)) }
                else {
                    if !input.holds.contains(hold) { newHolds.insert(hold) }
                    for i in matches {
                        // Identity and legacy ownership are separate: a prior
                        // hold never becomes a safe inheritance merely because a
                        // deferred catalog now has one row. Preserve legacy.
                        entries[i].reasons.append("legacyOwnershipUnproven")
                        if kind == .favorite && entries[i].disposition != .deferred { entries[i].disposition = .blocked }
                        if matches.count > 1 && entries[i].disposition != .deferred { entries[i].disposition = .blocked }
                    }
                }
            }
        }
        for i in entries.indices {
            for kind in [MigrationReferenceKind.favorite, .hidden] {
                let e = entries[i]
                let claims = input.claims.filter { $0.sourceID == e.sourceID && $0.kind == kind }
                let byToken = claims.filter { $0.legacyToken == e.token(kind) }
                let byIdentity = claims.filter { $0.identity == e.identity }
                if e.identityMappingTrusted, let id = e.identity, byToken.contains(where: { $0.identity != id }) {
                    throw ImportedExecutionError.corruption
                }
                let route: ImportedReferenceAuthority
                if !byToken.isEmpty || !byIdentity.isEmpty {
                    if e.identityMappingTrusted, let id = e.identity,
                       byToken.allSatisfy({ $0.identity == id }), byIdentity.allSatisfy({ $0.identity == id }) { route = .stable(id) }
                    else { route = .blocked; entries[i].reasons.append("claimedMappingUnresolved") }
                } else if input.retirementBlocks.contains(where: { $0.denies(e.sourceID, kind: kind, token: e.token(kind)) }) {
                    route = .blocked
                    entries[i].reasons.append("retiredLegacyInheritanceDenied")
                } else if (e.disposition == .blocked && !claims.isEmpty) || (tokens[ReferenceKey(kind: kind, token: e.token(kind))]?.count ?? 0) > 1 {
                    route = .blocked
                } else { route = .legacy }
                if kind == .hidden { entries[i].hidden = route } else { entries[i].favorite = route }
            }
            let hiddenBlocked = entries[i].hidden == .blocked, favoriteBlocked = entries[i].favorite == .blocked
            entries[i].newClaims.removeAll { $0.0 == .hidden ? hiddenBlocked : favoriteBlocked }
            // A legacy Favorite key collision alone is not a collision between
            // source-scoped permanent identities. Block that reference operation,
            // not an otherwise safe allocation in another source.
            if entries[i].reasons.contains("claimedMappingUnresolved"), entries[i].disposition == .allocate {
                entries[i].disposition = .blocked; entries[i].newClaims = []
            }
        }
        // Stable report ordering is not an identity/index mapping.
        entries.sort { [$0.sourceID.uuidString, $0.channel.groupName, $0.channel.name].lexicographicallyPrecedes([$1.sourceID.uuidString, $1.channel.groupName, $1.channel.name]) }
        let rows = entries.map { e in ImportedExecutionRow(sourceID: e.sourceID,
            group: ImportedChannelMigrationPlanner.safeMetadata(e.channel.groupName), name: ImportedChannelMigrationPlanner.safeMetadata(e.channel.name),
            disposition: e.disposition, identity: e.identity, reasons: Set(e.reasons).sorted(), favoriteAuthority: e.favorite, hiddenAuthority: e.hidden) }
        return ImportedExecutionPlan(planFingerprint: try fingerprint(input), rows: rows, input: input, entries: entries,
            newHolds: newHolds.sorted { [$0.kind.rawValue, $0.legacyToken].lexicographicallyPrecedes([$1.kind.rawValue, $1.legacyToken]) })
    }
    public func authority(_ plan: ImportedExecutionPlan, sourceID: UUID, channel: LiveChannel, kind: MigrationReferenceKind) -> ImportedReferenceAuthority {
        let matches = plan.entries.filter { $0.sourceID == sourceID && $0.channel == channel }
        guard matches.count == 1 else { return .blocked }
        return kind == .hidden ? matches[0].hidden : matches[0].favorite
    }
    public func value(_ plan: ImportedExecutionPlan, sourceID: UUID, channel: LiveChannel, kind: MigrationReferenceKind) -> Bool? {
        switch authority(plan, sourceID: sourceID, channel: channel, kind: kind) {
        case .blocked: return nil
        case .stable(let id): return plan.input.stable.contains { $0.identity == id && $0.kind == kind }
        case .legacy:
            guard let e = plan.entries.first(where: { $0.sourceID == sourceID && $0.channel == channel }) else { return nil }
            return (kind == .hidden ? plan.input.hidden : plan.input.favorites).contains { $0.rawValue == e.token(kind) }
        }
    }
    @_spi(ImportedMigration) public func execute(_ plan: ImportedExecutionPlan, store: ImportedMigrationStore) throws -> ImportedExecutionResult {
        try execute(plan, store: store, checkpoint: { _ in })
    }
    // Injection hook is internal/test-only. There is no force-execute API.
    func execute(_ plan: ImportedExecutionPlan, store: ImportedMigrationStore, checkpoint: (Int) throws -> Void) throws -> ImportedExecutionResult {
        try store.transaction { transaction in
            try execute(plan, transaction: transaction, checkpoint: checkpoint)
        }
    }
    func execute(_ plan: ImportedExecutionPlan, transaction: ImportedMigrationTransaction,
                 sourceID: UUID? = nil, checkpoint: (Int) throws -> Void = { _ in }) throws -> ImportedExecutionResult {
            let current = try prepare(transaction.snapshot())
            guard current.planFingerprint == plan.planFingerprint else { throw ImportedExecutionError.stalePlan }
            var allocated: [ImportedLiveChannelIdentity] = [], claimed: [ImportedReferenceClaim] = []
            for e in current.entries where (sourceID == nil || e.sourceID == sourceID) && [.allocate, .matched].contains(e.disposition) {
                let identity: ImportedLiveChannelIdentity
                if let existing = e.identity { identity = existing }
                else {
                    identity = try ImportedLiveChannelIdentity(source: .imported(e.sourceID), localID: UUID())
                    let now = Date()
                    try transaction.insertIdentity(ImportedChannelRegistryRecord(identity: identity, evidence: e.evidence,
                        provenance: .verified, lifecycle: .active, createdAt: now, updatedAt: now))
                    allocated.append(identity); try checkpoint(1)
                }
                for (kind, token) in e.newClaims {
                    let claim = try ImportedReferenceClaim(sourceID: e.sourceID, kind: kind, legacyToken: token, identity: identity)
                    if try transaction.claim(claim) {
                        claimed.append(claim); try checkpoint(2)
                        // A newly encountered legacy alias of an ALREADY claimed
                        // identity cannot overwrite a later user unhide/unfavorite.
                        if !current.input.claims.contains(where: { $0.identity == identity && $0.kind == kind }) {
                            try transaction.setStable(ImportedStableReferenceState(identity: identity, kind: kind), present: true)
                        }
                        try checkpoint(3)
                    }
                }
            }
            let holds = current.newHolds.filter { hold in
                sourceID == nil || current.entries.contains { $0.sourceID == sourceID && $0.token(hold.kind) == hold.legacyToken }
            }
            for hold in holds {
                try transaction.preserveUnprovenReference(hold, sourceID: sourceID ?? current.entries.first(where: { $0.token(hold.kind) == hold.legacyToken })?.sourceID)
            }
            let changed = !allocated.isEmpty || !claimed.isEmpty || !holds.isEmpty
            if changed {
                try transaction.recordBatch(ImportedMigrationBatch(id: UUID(), identities: allocated, claims: claimed, holds: holds))
                try checkpoint(4)
            }
            _ = try transaction.snapshot()
            return ImportedExecutionResult(allocated: allocated.count, claimed: claimed.count, preservedHolds: holds.count, batchRecorded: changed)
    }
    @_spi(ImportedMigration) public func write(_ plan: ImportedExecutionPlan, store: ImportedMigrationStore,
        sourceID: UUID, channel: LiveChannel, kind: MigrationReferenceKind, present: Bool) throws {
        try store.transaction { transaction in
            try write(plan, transaction: transaction, sourceID: sourceID, channel: channel, kind: kind, present: present)
        }
    }
    func write(_ plan: ImportedExecutionPlan, transaction: ImportedMigrationTransaction,
               sourceID: UUID, channel: LiveChannel, kind: MigrationReferenceKind, present: Bool) throws {
            let current = try prepare(transaction.snapshot())
            guard current.planFingerprint == plan.planFingerprint else { throw ImportedExecutionError.stalePlan }
            try writeValidated(current, transaction: transaction, sourceID: sourceID, channel: channel, kind: kind, present: present)
    }
    // Only the actor's already-validated transaction batch may reuse this
    // routing. Registry/claim/catalog do not mutate during reference edits.
    func writeValidated(_ current: ImportedExecutionPlan, transaction: ImportedMigrationTransaction,
                        sourceID: UUID, channel: LiveChannel, kind: MigrationReferenceKind, present: Bool) throws {
            switch authority(current, sourceID: sourceID, channel: channel, kind: kind) {
            case .blocked: throw ImportedExecutionError.blocked
            case .stable(let identity): try transaction.setStable(ImportedStableReferenceState(identity: identity, kind: kind), present: present)
            case .legacy:
                guard let e = current.entries.first(where: { $0.sourceID == sourceID && $0.channel == channel }) else { throw ImportedExecutionError.blocked }
                try transaction.setLegacy(sourceID: sourceID, kind: kind, token: e.token(kind), present: present)
            }
    }
}
