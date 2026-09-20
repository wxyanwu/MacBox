import Foundation
import CryptoKit
@_spi(MigrationDiagnostics) import OKVideoCore

public struct PreMergeGroupReport: Codable, Equatable {
    public let group: String
    public let name: String
    public let observations: Int
    public let lines: Int
    public let tvgIDs: [String]
    public let missingTVGIDs: Int
    public let sameTVGID: Bool
    public let conflictingTVGIDs: Bool
    public let idPresentMissing: Bool
    public let tvgNameDivergence: Bool
    public let metadataDivergence: Bool
    public let sameLocatorDifferentHeaders: Bool
    public let duplicateCalculatedID: Bool
    public let duplicateRuntimeID: Bool
    public let sameIdentityEvidence: Bool
    public let reasons: [String]
}
public struct PreMergeEvidenceReport: Codable, Equatable {
    public let rawObservations: Int
    public let mergedChannels: Int
    public let singleRecordChannels: Int
    public let multiRecordMergedChannels: Int
    public let counts: [String: Int]
    public let groups: [PreMergeGroupReport]
}

public enum ImportedPreMergeEvidence {
    public struct Parsed: CustomStringConvertible, CustomDebugStringConvertible {
        public let playlist: LivePlaylist
        public let observations: [ImportedRawObservation]
        public var description: String { "ImportedPreMergeEvidence.Parsed(<playlist and observations omitted>)" }
        public var debugDescription: String { description }
    }
    /// One parser pass. No payload/fingerprint is persisted or printed. A random
    /// in-memory HMAC key makes header tokens useless for offline guessing; the
    /// key is discarded with this call. Locator classes use actual URL equality,
    /// exactly as the current production append(), not URL string heuristics.
    public static func parse(_ data: Data, baseURL: URL? = nil) throws -> Parsed {
        let key = SymmetricKey(size: .bits256)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func token<T: Encodable>(_ value: T) -> String {
            // All values passed here are finite strings/bools and collections.
            let data = try! encoder.encode(value)
            return HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
        }
        var locators: [URL: String] = [:]
        var observations: [ImportedRawObservation] = []
        let playlist = try LiveSourceParser().parseObserving(data, baseURL: baseURL) { raw in
            let lines = raw.streams.compactMap { stream -> ImportedObservedLine? in
                guard let url = stream.url else { return nil }
                if locators[url] == nil { locators[url] = token("locator-class-\(locators.count)") }
                return ImportedObservedLine(locatorToken: locators[url]!, headersToken: token(stream.headers),
                    metadataToken: token([stream.format, String(stream.needsParsing)]))
            }
            observations.append(ImportedRawObservation(evidence: ImportedChannelEvidence(
                group: raw.group, name: raw.name, tvgID: raw.tvgID), lines: lines, tvgName: raw.tvgName,
                metadataToken: token([raw.number, raw.logoReference]), ordinal: raw.ordinal))
        }
        return Parsed(playlist: playlist, observations: observations)
    }
    private struct Name: Hashable { let group: String; let name: String; var id: String { "\(group)::\(name)" } }
    static func analyze(_ records: [ImportedRawObservation], channels: [MigrationChannel]) -> (risks: [String: [String]], report: PreMergeEvidenceReport) {
        let buckets: [Name: [ImportedRawObservation]] = Dictionary(grouping: records) { Name(group: $0.evidence.group, name: $0.evidence.name) }
        let rawIDs: [String: [ImportedRawObservation]] = Dictionary(grouping: records) { "\($0.evidence.group)::\($0.evidence.name)" }
        let runtimeIDs: [String: [MigrationChannel]] = Dictionary(grouping: channels, by: \.legacyChannelID)
        let runtimeNames: [Name: [MigrationChannel]] = Dictionary(grouping: channels) { Name(group: $0.evidence.group, name: $0.evidence.name) }
        let allLines: [String: [ImportedObservedLine]] = Dictionary(grouping: records.flatMap(\.lines), by: \.locatorToken)
        let divergentHeaders: Set<String> = Set(allLines.filter { Set($0.value.map(\.headersToken)).count > 1 }.keys)
        let divergentLineMetadata: Set<String> = Set(allLines.filter { Set($0.value.map(\.metadataToken)).count > 1 }.keys)
        var upstreamCounts: [String: Int] = [:]
        for r in records {
            if let u = r.evidence.upstream, u.formatSupportsStableID {
                let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
                let key = String(decoding: try! e.encode([u.namespace, u.value]), as: UTF8.self)
                upstreamCounts[key, default: 0] += 1
            }
        }
        var risks: [String: Set<String>] = [:]
        var groups: [PreMergeGroupReport] = []
        var single = 0, multiple = 0, sameMergedIDs = 0
        for name in buckets.keys.sorted(by: { [$0.group, $0.name].lexicographicallyPrecedes([$1.group, $1.name]) }) {
            let raw = buckets[name]!
            let ids: [String] = raw.map { $0.evidence.tvgID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            let present = Set(ids.filter { !$0.isEmpty })
            let missing = ids.filter(\.isEmpty).count
            let mixed = missing > 0 && !present.isEmpty
            let conflicting = present.count > 1
            let sameID = raw.count > 1 && present.count == 1 && missing == 0
            let tvgNames = Set(raw.map(\.tvgName))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let metadata = Set(raw.map { String(decoding: try! encoder.encode($0.evidence), as: UTF8.self) })
            let divergence = metadata.count > 1 || Set(raw.map(\.metadataToken)).count > 1
            let headerConflict = raw.flatMap(\.lines).contains { divergentHeaders.contains($0.locatorToken) }
            let lineConflict = raw.flatMap(\.lines).contains { divergentLineMetadata.contains($0.locatorToken) }
            let duplicateID = (rawIDs[name.id]?.count ?? 0) > 1
            let duplicateRuntime = (runtimeIDs[name.id]?.count ?? 0) > 1
            let uniqueStructure = Set((rawIDs[name.id] ?? []).map { Name(group: $0.evidence.group, name: $0.evidence.name) }).count == 1
            var reasons = Set<String>()
            if raw.count > 1 {
                reasons.insert("multipleRawRecords")
                // Identical metadata does not prove separate entries are the same
                // permanent channel. Preserve the conservative 8B.2 safety gate.
                if missing == raw.count { reasons.insert("insufficientIdentityEvidence") }
            }
            if conflicting { reasons.insert("conflictingTVGIDs") }
            if mixed { reasons.insert("mixedPresentMissingTVGID") }
            if tvgNames.count > 1 { reasons.insert("tvgNameDivergence") }
            if divergence { reasons.insert("metadataConflict") }
            if headerConflict { reasons.insert("lineMetadataConflict") }
            if lineConflict { reasons.insert("lineFormatDivergence") }
            if !uniqueStructure { reasons.insert("calculatedIDCollision") }
            if duplicateRuntime { reasons.insert("runtimeIDCollision") }
            for r in raw {
                if let u = r.evidence.upstream, u.formatSupportsStableID {
                    let key = String(decoding: try! encoder.encode([u.namespace, u.value]), as: UTF8.self)
                    if upstreamCounts[key, default: 0] > 1 { reasons.insert("duplicateUpstreamID") }
                }
            }
            if !reasons.isEmpty { risks[name.id, default: []].formUnion(reasons) }
            let runtimeCount = runtimeNames[name]?.count ?? 0
            if raw.count == 1 { single += runtimeCount }
            if raw.count > 1 && runtimeCount == 1 { multiple += 1; if sameID { sameMergedIDs += 1 } }
            groups.append(PreMergeGroupReport(group: ImportedChannelMigrationPlanner.safeMetadata(name.group),
                name: ImportedChannelMigrationPlanner.safeMetadata(name.name), observations: raw.count,
                lines: raw.reduce(0) { $0 + $1.lines.count }, tvgIDs: present.map(ImportedChannelMigrationPlanner.safeMetadata).sorted(),
                missingTVGIDs: missing, sameTVGID: sameID, conflictingTVGIDs: conflicting, idPresentMissing: mixed,
                tvgNameDivergence: tvgNames.count > 1, metadataDivergence: divergence, sameLocatorDifferentHeaders: headerConflict,
                duplicateCalculatedID: duplicateID, duplicateRuntimeID: duplicateRuntime,
                sameIdentityEvidence: raw.count > 1 && !divergence && tvgNames.count == 1, reasons: reasons.sorted()))
        }
        let counts: [String: Int] = [
            "multiRecordGroups": groups.filter { $0.observations > 1 }.count,
            "sameTVGIDMergeGroups": sameMergedIDs,
            "conflictingTVGIDGroups": groups.filter(\.conflictingTVGIDs).count,
            "idPresentMissingGroups": groups.filter(\.idPresentMissing).count,
            "tvgNameDivergenceGroups": groups.filter(\.tvgNameDivergence).count,
            "metadataDivergenceGroups": groups.filter(\.metadataDivergence).count,
            "sameURLDifferentHeaderGroups": groups.filter(\.sameLocatorDifferentHeaders).count,
            "sameURLDifferentHeaderLocatorClasses": divergentHeaders.count,
            "duplicateCalculatedIDGroups": rawIDs.values.filter { $0.count > 1 }.count,
            "duplicateRuntimeChannelIDGroups": runtimeIDs.values.filter { $0.count > 1 }.count,
            "duplicateUpstreamIDs": upstreamCounts.values.filter { $0 > 1 }.count
        ]
        return (risks.mapValues { $0.sorted() }, PreMergeEvidenceReport(rawObservations: records.count,
            mergedChannels: channels.count, singleRecordChannels: single, multiRecordMergedChannels: multiple, counts: counts, groups: groups))
    }
}
