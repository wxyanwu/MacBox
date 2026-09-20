import Foundation
import CryptoKit
import OKVideoCore

public enum MigrationAdmissionError: Error { case stalePlan, unsupportedVersion, invalidInput }
public enum MigrationAdmission: String, Codable { case eligible, deferred, blocked }
public enum ImportedClaimedAuthority {
    public enum Resolution: Equatable { case legacy(Bool), stable(Bool) }
    public static func resolve(sourceID: UUID, kind: MigrationReferenceKind, legacyToken: String,
                               legacyContains: Bool, claims: [ImportedReferenceClaim],
                               stable: [ImportedStableReferenceState]) throws -> Resolution {
        let matching = claims.filter { $0.sourceID == sourceID && $0.kind == kind && $0.legacyToken == legacyToken }
        guard matching.allSatisfy({ $0.identity.source == .imported(sourceID) }),
              Set(matching.map(\.identity)).count <= 1 else { throw MigrationAdmissionError.invalidInput }
        guard let claim = matching.first else { return .legacy(legacyContains) }
        return .stable(stable.contains { $0.identity == claim.identity && $0.kind == kind })
    }
}

/// Full input, not the sanitized report. Never Codable/logged/persisted by this
/// module. Payloads stay in memory and only enter a session-keyed aggregate MAC.
public struct ImportedAdmissionInput: CustomStringConvertible, CustomDebugStringConvertible {
    public var sources: [StoredLiveSource]
    public var registry: [ImportedChannelRegistryRecord]
    public var favorites: [ImportedLegacyReference]
    public var hidden: [ImportedLegacyReference]
    public var claims: [ImportedReferenceClaim]
    public var stable: [ImportedStableReferenceState]
    public var markers: [String]
    public var holds: [ImportedReferenceHold] = []
    // Binds history without presenting retired rows as reconciliation candidates.
    var historicalBinding = Data()
    var retirementBlocks: [ImportedRetirementReferenceBlock] = []
    public var schemaVersion: Int
    public var plannerVersion = 1
    public var policyVersion = 1
    public var evidenceVersion = 1
    public init(sources: [StoredLiveSource], registry: [ImportedChannelRegistryRecord] = [],
                favorites: [ImportedLegacyReference] = [], hidden: [ImportedLegacyReference] = [],
                claims: [ImportedReferenceClaim] = [], stable: [ImportedStableReferenceState] = [],
                markers: [String] = [], schemaVersion: Int) {
        self.sources = sources; self.registry = registry; self.favorites = favorites; self.hidden = hidden
        self.claims = claims; self.stable = stable; self.markers = markers; self.schemaVersion = schemaVersion
    }
    public var description: String { "ImportedAdmissionInput(<snapshot omitted>)" }
    public var debugDescription: String { description }

    func canonical() throws -> Data {
        // Raw bytes bind ALL pre-merge records, including swallowed lines and
        // headers; the parsed catalog is derived from these same bytes below.
        // Conservative policy: playlist/line reorder invalidates approval even
        // when classifications stay equal. DB row order does not invalidate it.
        struct Source: Encodable {
            let id: UUID; let name: String; let kind: StoredLiveSourceKind
            let locator: String?; let base: URL?; let raw: Data; let updated: Date
        }
        struct Record: Encodable {
            let identity: ImportedLiveChannelIdentity; let recordVersion: Int; let evidenceVersion: Int
            let lifecycle: ImportedChannelRegistryLifecycle; let provenance: ImportedSourceProvenance
            let evidence: ImportedChannelEvidence; let created: Date; let updated: Date
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func sorted<T: Encodable>(_ values: [T]) throws -> [Data] {
            try values.map { try encoder.encode($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        }
        struct Binding: Encodable {
            let domain = "OKVideoMac.8B2b.admission.v1"
            let schema: Int; let planner: Int; let policy: Int; let evidence: Int
            let sources: [Data]; let registry: [Data]; let favorites: [String]; let hidden: [String]
            let claims: [Data]; let stable: [Data]; let markers: [String]; let holds: [Data]
            let history: Data; let retirementBlocks: [Data]
        }
        return try encoder.encode(Binding(schema: schemaVersion, planner: plannerVersion, policy: policyVersion,
            evidence: evidenceVersion,
            sources: sorted(sources.map { Source(id: $0.id, name: $0.name, kind: $0.sourceKind,
                locator: $0.sourceValue, base: $0.baseURL, raw: $0.rawData, updated: $0.updatedAt) }),
            registry: sorted(registry.map { Record(identity: $0.identity, recordVersion: $0.recordVersion,
                evidenceVersion: $0.evidenceVersion, lifecycle: $0.lifecycle, provenance: $0.provenance,
                evidence: $0.evidence, created: $0.createdAt, updated: $0.updatedAt) }),
            favorites: favorites.map(\.rawValue).sorted(), hidden: hidden.map(\.rawValue).sorted(),
            claims: sorted(claims), stable: sorted(stable), markers: markers.sorted(), holds: sorted(holds), history: historicalBinding,
            retirementBlocks: sorted(retirementBlocks)))
    }
}

public struct ImportedAdmissionRow: Encodable, Equatable {
    public let channel: MigrationChannelPlan
    public let admission: MigrationAdmission
    public let reasons: [String]
}
/// An immutable, session-bound plan, deliberately NOT Decodable. JSON is review
/// material, never an executable migration command or persistent UUID allocation.
public struct ImportedAdmissionPlan: Encodable {
    public let planFingerprint: String
    public let sessionBound = true
    public let executableReport = false
    public let plannerVersion = 1
    public let policyVersion = 1
    public let evidenceVersion = 1
    public let schemaVersion: Int
    public let fullPlan: ImportedChannelMigrationPlan
    public let rows: [ImportedAdmissionRow]
    public let blockers: [String]
    public var counts: [String: Int] {
        Dictionary(grouping: rows, by: { $0.admission.rawValue }).mapValues(\.count)
    }
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }
    public func markdown() -> String {
        var result = "# 8B.2b Admission — frozen snapshot, not migration\n\n"
        result += "Session-bound planFingerprint: `\(planFingerprint)`\n\n"
        result += "Report is not executable; a new session requires replanning. No permanent UUIDs allocated.\n\n"
        result += "Eligible: \(counts["eligible", default: 0]); deferred: \(counts["deferred", default: 0]); blocked: \(counts["blocked", default: 0]).\n\n"
        result += "| Source UUID | Token | Group | Channel | Admission | Reasons |\n|---|---|---|---|---|---|\n"
        for row in rows { result += "| \(row.channel.sourceID) | \(row.channel.token) | \(row.channel.group) | \(row.channel.name) | \(row.admission.rawValue) | \(row.reasons.joined(separator: ", ")) |\n" }
        result += "\nGlobal blockers: \(blockers.joined(separator: ", ")).\n\n"
        result += "## Authority and rollback gates\n\nUnclaimed reads legacy; claimed reads stable only, including false after unhide. Never fall back after claim.\n\n"
        result += "Future writes must recompute the input fingerprint inside the same transaction before Registry + claim + state + marker commit. An exported report is not authorization.\n\n"
        result += "SQL rollback prevents partial transaction state. Schema-9 disaster restoration requires stopped writers and a verified consistent backup; post-backup changes may be lost. It is not lossless App downgrade.\n\n"
        return result + fullPlan.markdown()
    }
}

/// No database connection and no write methods. The future executor must call
/// validate using SAME-TRANSACTION consistent reads, not an earlier cached input.
public final class ImportedAdmissionSession {
    private let key = SymmetricKey(size: .bits256)
    public init() {}
    private func fingerprint(_ input: ImportedAdmissionInput) throws -> String {
        HMAC<SHA256>.authenticationCode(for: try input.canonical(), using: key).map { String(format: "%02x", $0) }.joined()
    }
    public func validate(_ plan: ImportedAdmissionPlan, current: ImportedAdmissionInput) throws {
        guard try fingerprint(current) == plan.planFingerprint else { throw MigrationAdmissionError.stalePlan }
    }
    public func prepare(_ input: ImportedAdmissionInput) throws -> ImportedAdmissionPlan {
        guard [9, 10].contains(input.schemaVersion), input.plannerVersion == 1,
              input.policyVersion == 1, input.evidenceVersion == 1 else { throw MigrationAdmissionError.unsupportedVersion }
        let sourceIDs = Set(input.sources.map(\.id))
        guard sourceIDs.count == input.sources.count,
              Set(input.registry.map(\.identity)).count == input.registry.count else { throw MigrationAdmissionError.invalidInput }
        var blockers: [String] = []
        let ownedSources = Set(sourceIDs.map { LiveSourceID.imported($0) })
        if input.registry.contains(where: { !ownedSources.contains($0.identity.source) }) {
            blockers.append("registrySourceNotInSnapshot")
        }
        // No claimed-state ingestion/migration policy is authorized yet. Bind it
        // for invalidation, but fail closed rather than silently re-migrating it.
        if !input.claims.isEmpty || !input.stable.isEmpty || !input.markers.isEmpty { blockers.append("existingAuthorityRequiresReview") }
        let sources: [MigrationSourceSnapshot] = input.sources.map { source in
            let records = input.registry.filter { $0.identity.source == .imported(source.id) }
            let existing = records.map { ImportedExistingChannel(identity: $0.identity, evidence: $0.evidence) }
            let usable = records.allSatisfy { $0.lifecycle == .active && $0.provenance == .verified && $0.recordVersion == 1 && $0.evidenceVersion == 1 }
            do {
                let parsed = try ImportedPreMergeEvidence.parse(source.rawData, baseURL: source.baseURL)
                return MigrationSourceSnapshot(id: source.id, name: source.name, format: parsed.playlist.format.rawValue,
                    channels: parsed.playlist.groups.flatMap(\.channels).map { MigrationChannel(legacyChannelID: $0.id,
                        evidence: ImportedChannelEvidence(group: $0.groupName, name: $0.name, tvgID: $0.tvgID)) },
                    existing: existing, rawObservations: parsed.observations, catalogComplete: usable)
            } catch {
                return MigrationSourceSnapshot(id: source.id, name: source.name, format: "unavailable",
                    channels: [], existing: existing, catalogComplete: false)
            }
        }
        if sources.contains(where: { !$0.catalogComplete }) { blockers.append("incompleteCatalogOrRegistry") }
        // Crucial: FULL catalog is reconciled before ANY eligibility filtering.
        let full = try ImportedChannelMigrationPlanner.plan(sources: sources, favorites: input.favorites, hidden: input.hidden)
        let rows = full.channels.map { channel -> ImportedAdmissionRow in
            let unsafeRefs = full.references.filter { $0.candidates.contains(channel.token) && $0.classification != .safeLegacyMigrationCandidate }
            let admission: MigrationAdmission
            var reasons = channel.reasons
            if !blockers.isEmpty { admission = .blocked; reasons += blockers }
            else if channel.classification == .futureSplitRisk { admission = .deferred }
            else if !unsafeRefs.isEmpty { admission = .blocked; reasons += unsafeRefs.map { "legacy:\($0.classification.rawValue)" } }
            else if [.safeMatched, .allocateNew, .safeLegacyMigrationCandidate].contains(channel.classification) { admission = .eligible }
            else { admission = .blocked }
            return ImportedAdmissionRow(channel: channel, admission: admission, reasons: Set(reasons).sorted())
        }
        return ImportedAdmissionPlan(planFingerprint: try fingerprint(input), schemaVersion: input.schemaVersion,
            fullPlan: full, rows: rows, blockers: blockers.sorted())
    }
}
