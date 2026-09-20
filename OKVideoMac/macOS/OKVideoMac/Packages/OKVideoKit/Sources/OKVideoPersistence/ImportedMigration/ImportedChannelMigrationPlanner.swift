import Foundation
import OKVideoCore

public enum MigrationClassification: String, Codable, CaseIterable {
    case safeMatched, allocateNew, safeLegacyMigrationCandidate, sourceProvenanceUnknown
    case ambiguous, conflict, orphanedLegacyReference, futureSplitRisk, unresolved
}

/// Diagnostic observations only, never persistent identity. Tokens are transient
/// equality evidence; callers must not provide raw locators or headers to reports.
public struct ImportedObservedLine {
    public let locatorToken: String
    public let headersToken: String
    public let metadataToken: String?
    public init(locatorToken: String, headersToken: String, metadataToken: String? = nil) {
        self.locatorToken = locatorToken; self.headersToken = headersToken; self.metadataToken = metadataToken
    }
}
public struct ImportedRawObservation: CustomStringConvertible, CustomDebugStringConvertible {
    public let evidence: ImportedChannelEvidence
    public let lines: [ImportedObservedLine]
    public let tvgName: String?
    public let metadataToken: String?
    public let ordinal: Int?
    public init(evidence: ImportedChannelEvidence, locatorToken: String, headersToken: String) {
        self.init(evidence: evidence, lines: [ImportedObservedLine(locatorToken: locatorToken, headersToken: headersToken)])
    }
    public init(evidence: ImportedChannelEvidence, lines: [ImportedObservedLine], tvgName: String? = nil,
                metadataToken: String? = nil, ordinal: Int? = nil) {
        self.evidence = evidence; self.lines = lines; self.tvgName = tvgName
        self.metadataToken = metadataToken; self.ordinal = ordinal
    }
    public var description: String { "ImportedRawObservation(<metadata and line equality tokens omitted>)" }
    public var debugDescription: String { description }
}

public struct MigrationChannel {
    public let legacyChannelID: String
    public let evidence: ImportedChannelEvidence
    public init(legacyChannelID: String, evidence: ImportedChannelEvidence) {
        self.legacyChannelID = legacyChannelID; self.evidence = evidence
    }
}

public struct MigrationSourceSnapshot {
    public let id: UUID
    public let name: String
    public let format: String
    public let channels: [MigrationChannel]
    public let existing: [ImportedExistingChannel]
    /// nil means pre-merge completeness CANNOT be established. Never infer it
    /// from the merged production catalog's stream count.
    public let rawObservations: [ImportedRawObservation]?
    public let catalogComplete: Bool
    public let favoriteProvenance: ImportedSourceProvenance
    public init(id: UUID, name: String, format: String, channels: [MigrationChannel],
                existing: [ImportedExistingChannel] = [], rawObservations: [ImportedRawObservation]? = nil,
                catalogComplete: Bool = true, favoriteProvenance: ImportedSourceProvenance = .unknown) {
        self.id = id; self.name = name; self.format = format; self.channels = channels
        self.existing = existing; self.rawObservations = rawObservations
        self.catalogComplete = catalogComplete; self.favoriteProvenance = favoriteProvenance
    }
}

public struct MigrationChannelPlan: Codable, Equatable {
    public let token: String
    public let sourceID: UUID
    public let group: String
    public let name: String
    public let tvgID: String?
    public var classification: MigrationClassification
    public var reasons: [String]
    public let existingIdentity: ImportedLiveChannelIdentity?
    public var allocationRequired: Bool
}

public struct MigrationReferencePlan: Codable, Equatable {
    public let token: String
    public let kind: String
    public let candidates: [String]
    public let classification: MigrationClassification
    public let syntacticallyUnique: Bool
    public let historicallyTrusted: Bool
    public let action: String
    public let reason: String
}

public struct MigrationSourceSummary: Codable, Equatable {
    public let sourceID: UUID
    public let name: String
    public let format: String
    public let channels: Int
    public let rawRecords: Int?
    public let registryIdentities: Int
    public let catalogComplete: Bool
    public let splitRiskProven: Bool
    public var favoriteReferences: Int
    public var hiddenReferences: Int
    public var classifications: [String: Int]
    public let preMerge: PreMergeEvidenceReport?
}

/// Contains only sanitized output, no opaque legacy strings, payloads, URLs or headers.
public struct ImportedChannelMigrationPlan: Codable, Equatable {
    public let planVersion: Int
    public let allocationIsIntentOnly: Bool
    public let channels: [MigrationChannelPlan]
    public let references: [MigrationReferencePlan]
    public let sources: [MigrationSourceSummary]
    public var channelCounts: [String: Int] { Self.counts(channels.map(\.classification)) }
    public func referenceCounts(kind: String) -> [String: Int] {
        Self.counts(references.filter { $0.kind == kind }.map(\.classification))
    }
    static func counts(_ values: [MigrationClassification]) -> [String: Int] {
        var result = Dictionary(uniqueKeysWithValues: MigrationClassification.allCases.map { ($0.rawValue, 0) })
        for value in values { result[value.rawValue, default: 0] += 1 }
        return result
    }
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    public func markdown() -> String {
        var lines = ["# Imported identity migration dry-run", "", "Planning only. All legacy references remain unchanged.",
                     "Missing rawRecords means UNKNOWN, not zero. No migration approval is implied.", "",
                     "## Sources", "", "| Source | UUID | Channels | Raw records | Registry | Favorites | Hidden |",
                     "|---|---|---:|---:|---:|---:|---:|"]
        for s in sources {
            lines.append("| \(s.name) | \(s.sourceID) | \(s.channels) | \(s.rawRecords.map(String.init) ?? "UNKNOWN") | \(s.registryIdentities) | \(s.favoriteReferences) | \(s.hiddenReferences) |")
        }
        lines += ["", "## Classification counts (channels / Favorites / Hidden)", ""]
        for c in MigrationClassification.allCases {
            lines.append("- \(c.rawValue): \(channelCounts[c.rawValue] ?? 0) / \(referenceCounts(kind: "favorite")[c.rawValue] ?? 0) / \(referenceCounts(kind: "hidden")[c.rawValue] ?? 0)")
        }
        lines += ["", "## Pre-merge evidence (accepted channel entries)", "",
                  "COMPLETE means all accepted parser records were observed, not that migration is safe.",
                  "sameIdentityEvidence alone never authorizes allocation for a multi-record group."]
        let evidenceReports = sources.compactMap(\.preMerge)
        lines.append("Sources: \(sources.count); raw observations (known): \(evidenceReports.reduce(0) { $0 + $1.rawObservations }); merged channels: \(channels.count); unavailable sources: \(sources.count - evidenceReports.count).")
        lines.append("Single-record channels: \(evidenceReports.reduce(0) { $0 + $1.singleRecordChannels }); multi-record merged channels: \(evidenceReports.reduce(0) { $0 + $1.multiRecordMergedChannels }); allocation eligible (including legacy candidates): \(channels.filter(\.allocationRequired).count).")
        var totals: [String: Int] = [:]
        for report in evidenceReports { for (key, count) in report.counts { totals[key, default: 0] += count } }
        for (key, count) in totals.sorted(by: { $0.key < $1.key }) { lines.append("- \(key): \(count)") }
        for s in sources {
            lines += ["", "### \(s.name) — \(s.sourceID)", ""]
            guard let p = s.preMerge else { lines.append("Evidence: UNAVAILABLE"); continue }
            lines.append("Format: \(s.format); evidence: \(s.splitRiskProven ? "COMPLETE" : "PARTIAL"); raw: \(p.rawObservations); merged: \(p.mergedChannels); single-record channels: \(p.singleRecordChannels); multi-record merged channels: \(p.multiRecordMergedChannels).")
            for (key, count) in p.counts.sorted(by: { $0.key < $1.key }) { lines.append("- \(key): \(count)") }
            let review = p.groups.filter { !$0.reasons.isEmpty }
            if !review.isEmpty {
                lines += ["", "| Group | Channel | Raw | TVG IDs | Missing ID | Reasons |", "|---|---|---:|---|---:|---|"]
                for g in review {
                    lines.append("| \(g.group) | \(g.name) | \(g.observations) | \(g.tvgIDs.joined(separator: ", ")) | \(g.missingTVGIDs) | \(g.reasons.joined(separator: ", ")) |")
                }
            }
        }
        lines += ["", "## Channels", "", "| Token | Source UUID | Group | Name | tvg-id | Classification | Reasons |", "|---|---|---|---|---|---|---|"]
        for c in channels {
            lines.append("| \(c.token) | \(c.sourceID) | \(c.group) | \(c.name) | \(c.tvgID ?? "—") | \(c.classification.rawValue) | \(c.reasons.joined(separator: ", ")) |")
        }
        lines += ["", "## Legacy references (opaque values intentionally omitted)", ""]
        for r in references {
            lines.append("- \(r.token) \(r.kind): \(r.classification.rawValue); candidates: \(r.candidates.joined(separator: ", ")); \(r.reason); \(r.action)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum MigrationDiagnosticError: Error { case invalidSnapshot }

public enum ImportedChannelMigrationPlanner {
    // Exact current production formulas (AppState.liveFavoriteID and
    // LiveChannelDeletionPolicy.identifier). Opaque values are NEVER parsed.
    public static func favoriteKey(sourceName: String, channelID: String) -> String { "\(sourceName)::\(channelID)" }
    public static func hiddenKey(sourceID: UUID, channelID: String) -> String { "\(sourceID.uuidString)::\(channelID)" }

    public static func safeMetadata(_ value: String) -> String {
        // Reports are less permissive than runtime labels. No URL-like or credential
        // syntax, control/Markdown syntax, long opaque tokens, or auth vocabulary.
        let lower = value.lowercased()
        let forbidden = ["token", "secret", "password", "passwd", "authorization", "cookie", "bearer", "username", "credential"]
        guard value.utf8.count <= 160, !forbidden.contains(where: lower.contains),
              LogRedactor.text(value) == value,
              value.range(of: #"[^\p{L}\p{N}\p{Zs}\-+().:：（）·]"#, options: .regularExpression) == nil,
              value.range(of: #"[A-Za-z0-9]{24,}"#, options: .regularExpression) == nil else { return "REDACTED" }
        return value
    }

    private struct Name: Hashable { let group: String; let name: String }
    private static func rawCoverageComplete(_ source: MigrationSourceSnapshot) -> Bool {
        guard let raw = source.rawObservations else { return false }
        let rawNames = Set(raw.map { Name(group: $0.evidence.group, name: $0.evidence.name) })
        let catalogNames = Set(source.channels.map { Name(group: $0.evidence.group, name: $0.evidence.name) })
        return rawNames == catalogNames
    }
    public static func splitRisks(_ records: [ImportedRawObservation]) -> [String: [String]] {
        ImportedPreMergeEvidence.analyze(records, channels: []).risks
    }

    public static func plan(sources input: [MigrationSourceSnapshot], favorites: [ImportedLegacyReference],
                            hidden: [ImportedLegacyReference]) throws -> ImportedChannelMigrationPlan {
        let sources = input.sorted { $0.id.uuidString < $1.id.uuidString }
        guard Set(sources.map(\.id)).count == sources.count else { throw MigrationDiagnosticError.invalidSnapshot }
        var entries: [(source: MigrationSourceSnapshot, channel: MigrationChannel, token: String, correlation: UUID)] = []
        var risks: [UUID: [String: [String]]] = [:]
        var rawComplete: [UUID: Bool] = [:]
        for source in sources {
            guard source.existing.allSatisfy({ $0.identity.source == .imported(source.id) }) else { throw MigrationDiagnosticError.invalidSnapshot }
            risks[source.id] = source.rawObservations.map(splitRisks)
            rawComplete[source.id] = rawCoverageComplete(source)
            let sorted = source.channels.sorted {
                [$0.evidence.group, $0.evidence.name, $0.legacyChannelID, fingerprint($0.evidence)].lexicographicallyPrecedes(
                    [$1.evidence.group, $1.evidence.name, $1.legacyChannelID, fingerprint($1.evidence)])
            }
            for c in sorted {
                let n = entries.count + 1
                // Reconciler requires a UUID-shaped correlation token; a fixed
                // diagnostic namespace + counter is not an allocated local UUID.
                let correlation = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", Int64(n)))!
                entries.append((source, c, String(format: "P%04d", n), correlation))
            }
        }
        var outcomes: [UUID: ImportedReconciliationResult] = [:]
        for source in sources {
            let candidates = entries.filter { $0.source.id == source.id }.map {
                ImportedChannelCandidate(candidateID: $0.correlation, source: .imported(source.id), provenance: .verified, evidence: $0.channel.evidence)
            }
            let results = try ImportedChannelReconciler.reconcile(existing: source.existing, candidates: candidates, catalogsAreComplete: source.catalogComplete)
            for result in results { outcomes[result.candidateID] = result }
        }
        var favoriteIndex: [String: Set<Int>] = [:], hiddenIndex: [String: Set<Int>] = [:]
        for (i, e) in entries.enumerated() {
            favoriteIndex[favoriteKey(sourceName: e.source.name, channelID: e.channel.legacyChannelID), default: []].insert(i)
            hiddenIndex[hiddenKey(sourceID: e.source.id, channelID: e.channel.legacyChannelID), default: []].insert(i)
        }
        var channels: [MigrationChannelPlan] = entries.map { e in
            let result = outcomes[e.correlation]!
            var category: MigrationClassification
            var identity: ImportedLiveChannelIdentity?
            var allocation = false
            switch result.outcome {
            case .matched(let id): category = .safeMatched; identity = id
            case .newIdentityRequired: category = .allocateNew; allocation = true
            case .ambiguous: category = .ambiguous
            case .conflict: category = .conflict
            case .unresolved: category = .unresolved
            }
            var reasons = result.reasons.map(\.rawValue).sorted()
            if let found = risks[e.source.id]?[e.channel.legacyChannelID], !found.isEmpty {
                category = .futureSplitRisk; reasons += found; allocation = false
            } else if rawComplete[e.source.id] != true {
                if category != .ambiguous && category != .conflict { category = .unresolved }
                reasons.append("preMergeEvidenceUnavailable"); allocation = false
            }
            if hiddenIndex[hiddenKey(sourceID: e.source.id, channelID: e.channel.legacyChannelID), default: []].count > 1 {
                category = .ambiguous; reasons.append("legacyChannelIDCollision"); allocation = false
            }
            return MigrationChannelPlan(token: e.token, sourceID: e.source.id, group: safeMetadata(e.channel.evidence.group),
                name: safeMetadata(e.channel.evidence.name), tvgID: e.channel.evidence.tvgID.map(safeMetadata),
                classification: category, reasons: Array(Set(reasons)).sorted(), existingIdentity: identity, allocationRequired: allocation)
        }
        let baseChannels = channels
        var refs: [MigrationReferencePlan] = []
        for (kind, values, index) in [("favorite", favorites, favoriteIndex), ("hidden", hidden, hiddenIndex)] {
            for value in Set(values.map(\.rawValue)).sorted() {
                let matches = (index[value] ?? []).sorted()
                var c: MigrationClassification = .orphanedLegacyReference
                var trusted = false
                var reason = "noExactOpaqueKeyMatch"
                if matches.count > 1 {
                    c = .ambiguous; reason = "multipleExactOpaqueKeyMatches"
                    for i in matches where channels[i].classification == .allocateNew {
                        channels[i].classification = .ambiguous
                        channels[i].allocationRequired = false
                        channels[i].reasons.append("legacyReferenceHasMultipleTargets")
                    }
                }
                else if let i = matches.first {
                    trusted = kind == "hidden" || entries[i].source.favoriteProvenance == .verified
                    if !trusted { c = .sourceProvenanceUnknown; reason = "currentNameUniquenessIsNotHistoricalOwnership" }
                    else {
                        c = baseChannels[i].classification
                        if c == .allocateNew || c == .safeMatched { c = .safeLegacyMigrationCandidate }
                        reason = c == .safeLegacyMigrationCandidate ? "uniqueCorrespondenceWithVerifiedOwnership" : "channelEvidenceBlocksMigration"
                    }
                    if channels[i].classification == .allocateNew {
                        channels[i].classification = c
                        channels[i].allocationRequired = c == .safeLegacyMigrationCandidate
                        channels[i].reasons.append("legacyReferenceRequiresReview")
                    }
                }
                if matches.isEmpty && sources.contains(where: { !$0.catalogComplete }) {
                    c = .unresolved; reason = "catalogIncompleteCannotProveOrphan"
                }
                refs.append(MigrationReferencePlan(token: String(format: "R%04d", refs.count + 1), kind: kind,
                    candidates: matches.map { entries[$0].token }, classification: c, syntacticallyUnique: matches.count == 1,
                    historicallyTrusted: trusted, action: c == .safeLegacyMigrationCandidate ? "would migrate; preserve legacy reference unchanged in dry-run" : "preserve legacy reference unchanged", reason: reason))
            }
        }
        let summaries = sources.map { s -> MigrationSourceSummary in
            let tokens = Set(channels.filter { $0.sourceID == s.id }.map(\.token))
            return MigrationSourceSummary(sourceID: s.id, name: safeMetadata(s.name), format: safeMetadata(s.format),
                channels: s.channels.count, rawRecords: s.rawObservations?.count, registryIdentities: s.existing.count,
                catalogComplete: s.catalogComplete, splitRiskProven: rawComplete[s.id] == true,
                favoriteReferences: refs.filter { $0.kind == "favorite" && !tokens.isDisjoint(with: $0.candidates) }.count,
                hiddenReferences: refs.filter { $0.kind == "hidden" && !tokens.isDisjoint(with: $0.candidates) }.count,
                classifications: ImportedChannelMigrationPlan.counts(channels.filter { $0.sourceID == s.id }.map(\.classification)),
                preMerge: s.rawObservations.map { ImportedPreMergeEvidence.analyze($0, channels: s.channels).report })
        }
        return ImportedChannelMigrationPlan(planVersion: 1, allocationIsIntentOnly: true, channels: channels, references: refs, sources: summaries)
    }

    private static func fingerprint(_ evidence: ImportedChannelEvidence) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: (try? e.encode(evidence)) ?? Data(), as: UTF8.self)
    }
}
