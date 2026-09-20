import Foundation
import CSQLite
import CryptoKit
import OKVideoCore
import OKVideoPersistence

/// Explicit developer-only command. SQLite backup reads an ISOLATED acceptance
/// DB or an earlier temporary snapshot, never the user's Library database.
public enum ImportedShadowDiff {
    public struct Report: Codable, Equatable {
        public struct Summary: Codable, Equatable {
            public let sourceID: UUID
            public let name: String
            public let oldChannels: Int
            public let proposedChannels: Int?
            public let oldRoutes: Int
            public let proposedRoutes: Int?
            public let counts: [String: Int]
        }
        public let ruleVersion: Int
        public let schema: Int
        public let retiredSourcesExcluded: Int
        public let historicalRegistryCount: Int
        public let legacyFavoriteCount: Int
        public let legacyHiddenCount: Int
        public let historicalClaimCount: Int
        public let summaries: [Summary]
        public let sources: [ImportedShadowRules.Source]
        public let snapshotBytesUnchanged: Bool
        public let parserOutputUnchanged: Bool
        public let permutationVerified: Bool
        public let uuidAllocations: Int
        public let registryWrites: Int
        public func json() throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
        public func markdown() -> String {
            func count(_ value: Int?) -> String { value.map(String.init) ?? "UNDECIDED" }
            var lines = ["# 8C.1 Shadow diff — NOT an executable migration plan", "",
                "Rule v\(ruleVersion). Schema \(schema) unchanged. Retired sources excluded: \(retiredSourcesExcluded).",
                "Historical Registry: \(historicalRegistryCount); legacy Favorite/Hidden: \(legacyFavoriteCount)/\(legacyHiddenCount); claims: \(historicalClaimCount).",
                "UUID allocations: 0; Registry writes: 0. No source network requests. No runtime keys changed.",
                "Parser output equivalence: \(parserOutputUnchanged); permutation verification: \(permutationVerified); snapshot bytes unchanged: \(snapshotBytesUnchanged).",
                "", "Counts are group events, not disjoint totals: split and routeDedupeChange can overlap.",
                "UNDECIDED is not zero. Proposed counts are shadow hypotheses, never migration approval.",
                "Merge across existing channels is NOT enabled by v1. Normalized names are display evidence only.",
                "Route equality candidate = exact URL equality + exact headers dictionary + format + needsParsing; labels are presentation, not transport semantics.",
                "Signatures remain transient in memory, are not printed, and are not permanent identity.",
                "Registry impact uses conservative exact evidence screening, NOT an authority decision or full migration eligibility.",
                "Legacy references are opaque equality only; claims are counted even when stable value is false. No Favorite provenance is promoted.",
                "", "| Source | UUID | old/proposed channels | old/proposed routes | unchanged | route change | split | merge | ambiguous | channel/route key risk |",
                "|---|---|---|---|---:|---:|---:|---:|---:|---|"]
            for s in summaries {
                let c = s.counts
                lines.append("| \(s.name) | \(s.sourceID) | \(s.oldChannels)/\(count(s.proposedChannels)) | \(s.oldRoutes)/\(count(s.proposedRoutes)) | \(c["unchanged"] ?? 0) | \(c["routeDedupeChange"] ?? 0) | \(c["split"] ?? 0) | \(c["merge"] ?? 0) | \(c["ambiguous"] ?? 0) | \(c["runtimeKeyRisk"] ?? 0)/\(c["routeRuntimeKeyRisk"] ?? 0) |")
            }
            for s in sources {
                lines += ["", "## \(s.name) — \(s.sourceID)", "",
                    "Format: \(s.format); raw records: \(s.rawRecords); Registry: \(s.existingIdentities); parse available: \(s.parseAvailable)."]
                for g in s.groups where g.classification != .unchanged || g.routeDedupeChange || g.runtimeKeyRisk || g.routeRuntimeKeyRisk ||
                    !g.frozen8BReasons.isEmpty || g.legacyFavorites + g.legacyHidden + g.claimedFavorites + g.claimedHidden > 0 ||
                    g.identityImpact == "unresolvedRegistryEvidenceDoNotSelectFirst" {
                    lines += ["", "### \(g.group) / \(g.name)", "",
                        "- Normalized group/name: \(g.normalizedGroup) / \(g.normalizedName).",
                        "- \(g.classification.rawValue): channels \(g.oldChannels) → \(count(g.proposedChannels)); routes \(g.oldRoutes) → route-only \(count(g.routeOnlyProposedRoutes)) / combined \(count(g.proposedRoutes)).",
                        "- Raw records \(g.rawRecords); distinct tvg-id [\(g.tvgIDs.joined(separator: ", "))]; missing ID \(g.missingIDs).",
                        "- Same URL/different headers classes \(g.sameURLDifferentHeaders); different properties \(g.sameURLDifferentProperties); restored variants \(count(g.restoredRouteVariants)).",
                        "- Evidence: \(g.reasons.joined(separator: ", ")).",
                        "- Identity: \(g.identityImpact); associated Registry \(g.existingIdentities).",
                        "- Broader Registry evidence candidates: \(g.registryEvidenceCandidates). A tvg-id/normalized hit without exact evidence is not ownership.",
                        "- Frozen 8B vetoes (not overridden by shadow rules): \(g.frozen8BReasons.joined(separator: ", ")).",
                        "- References: \(g.referenceImpact); legacy Favorite/Hidden \(g.legacyFavorites)/\(g.legacyHidden); claimed Favorite/Hidden \(g.claimedFavorites)/\(g.claimedHidden).",
                        "- Runtime key risk: channel \(g.runtimeKeyRisk), route \(g.routeRuntimeKeyRisk)."]
                }
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
    static func outputDirectory(_ url: URL) throws -> URL {
        let path = url.resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        guard path.deletingLastPathComponent().path == temporaryRoot.path,
              path.lastPathComponent.hasPrefix("OKVideoMac-8C1-"), path.path == url.standardizedFileURL.path,
              (try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw SnapshotError.unsafeFile }
        return path
    }
    public static func run(temporaryInput: URL, output: URL) throws -> Report {
        let input = temporaryInput.resolvingSymlinksInPath(), directory = try outputDirectory(output)
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
        let priorSnapshot = input.deletingLastPathComponent()
        let acceptanceRoot = input.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let allowedSnapshot = priorSnapshot.deletingLastPathComponent().path == temporaryRoot.path &&
            priorSnapshot.lastPathComponent.hasPrefix("OKVideoMac-8B2-DryRun-") && ["snapshot.sqlite3", "staged.sqlite3"].contains(input.lastPathComponent)
        let allowedAcceptance = acceptanceRoot.deletingLastPathComponent().path == temporaryRoot.path &&
            acceptanceRoot.lastPathComponent.hasPrefix("OKVideoMac-8B3B-") &&
            input.path == acceptanceRoot.appendingPathComponent("Application Support/Database/OKVideoMac.sqlite3").path
        guard input == temporaryInput.standardizedFileURL, allowedSnapshot || allowedAcceptance else { throw SnapshotError.unsafeFile }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: input.path + suffix) {
            let a = try FileManager.default.attributesOfItem(atPath: input.path + suffix)
            guard a[.type] as? FileAttributeType == .typeRegular, (a[.referenceCount] as? NSNumber)?.intValue == 1 else { throw SnapshotError.unsafeFile }
        }
        let snapshot = directory.appendingPathComponent("shadow.sqlite3")
        try ImportedMigrationRehearsal.backup(source: input, destination: snapshot)
        return try replay(snapshot: snapshot, output: directory)
    }
    /// Recompute in a fresh CLI process from the SAME frozen snapshot. No live
    /// input is reopened and no prior report is accepted as execution authority.
    public static func replay(snapshot: URL, output: URL) throws -> Report {
        let directory = try outputDirectory(output)
        let report = try read(snapshot: snapshot)
        try QuiescentDatabaseSnapshot.writePrivate(report.json(), to: directory.appendingPathComponent("ImportedShadowDiff.json"))
        try QuiescentDatabaseSnapshot.writePrivate(Data(report.markdown().utf8), to: directory.appendingPathComponent("ImportedShadowDiff.md"))
        return report
    }
    /// Only a frozen output of the backup above may be opened immutable. NEVER
    /// immutable-open a live WAL input (that could omit committed WAL records).
    static func read(snapshot: URL) throws -> Report {
        _ = try outputDirectory(snapshot.deletingLastPathComponent())
        guard snapshot.lastPathComponent == "shadow.sqlite3",
              snapshot.standardizedFileURL.path == snapshot.resolvingSymlinksInPath().path,
              !FileManager.default.fileExists(atPath: snapshot.path + "-wal") else { throw SnapshotError.unsafeFile }
        let before = SHA256.hash(data: try Data(contentsOf: snapshot))
        var handle: OpaquePointer?
        let uri = snapshot.absoluteString + "?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }; throw SnapshotError.sqliteFailure
        }
        defer { sqlite3_close(db) }
        guard sqlite3_db_readonly(db, "main") == 1 else { throw SnapshotError.unsafeFile }
        func rows(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
            var handle: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else { throw SnapshotError.sqliteFailure }
            defer { sqlite3_finalize(statement) }
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return }
                guard code == SQLITE_ROW else { throw SnapshotError.sqliteFailure }
                try body(statement)
            }
        }
        func text(_ s: OpaquePointer, _ i: Int32) throws -> String {
            guard let v = sqlite3_column_text(s, i) else { throw SnapshotError.invalidDatabase }; return String(cString: v)
        }
        func uuid(_ s: OpaquePointer, _ i: Int32) throws -> UUID {
            guard let v = UUID(uuidString: try text(s, i)) else { throw SnapshotError.invalidDatabase }; return v
        }
        func blob(_ s: OpaquePointer, _ i: Int32) throws -> Data {
            guard sqlite3_column_type(s, i) == SQLITE_BLOB else { throw SnapshotError.invalidDatabase }
            return sqlite3_column_blob(s, i).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(s, i))) } ?? Data()
        }
        try rows("BEGIN") { _ in }
        var schema = 0
        try rows("PRAGMA user_version") { schema = Int(sqlite3_column_int($0, 0)) }
        guard [9, 10, 11, 12].contains(schema) else { throw SnapshotError.invalidDatabase }
        var retired = Set<UUID>(), knownSources = Set<UUID>()
        try rows("SELECT id," + (schema == 12 ? "retired_at" : "NULL") + " FROM live_sources") {
            let id = try uuid($0, 0); knownSources.insert(id)
            if sqlite3_column_type($0, 1) != SQLITE_NULL { retired.insert(id) }
        }
        var registry: [ImportedChannelRegistryRecord] = []
        if schema >= 10 {
            try rows("SELECT source_id,local_id,record_version,evidence_version,lifecycle,provenance,evidence,created_at,updated_at FROM imported_channel_identities") { s in
                let source = try uuid(s, 0)
                guard knownSources.contains(source), sqlite3_column_int(s, 2) == 1, sqlite3_column_int(s, 3) == 1,
                      let lifecycle = ImportedChannelRegistryLifecycle(rawValue: try text(s, 4)),
                      let provenance = ImportedSourceProvenance(rawValue: try text(s, 5)),
                      !retired.contains(source) || lifecycle == .retired else { throw SnapshotError.invalidDatabase }
                registry.append(ImportedChannelRegistryRecord(identity: try ImportedLiveChannelIdentity(source: .imported(source), localID: uuid(s, 1)),
                    evidence: try JSONDecoder().decode(ImportedChannelEvidence.self, from: blob(s, 6)), provenance: provenance, lifecycle: lifecycle,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 8))))
            }
        }
        var claims: [ImportedReferenceClaim] = []
        if schema >= 11 {
            let known = Set(registry.map(\.identity))
            try rows("SELECT source_id,local_id,kind,legacy_reference FROM imported_reference_claims") { s in
                let source = try uuid(s, 0), identity = try ImportedLiveChannelIdentity(source: .imported(source), localID: uuid(s, 1))
                guard known.contains(identity), let kind = MigrationReferenceKind(rawValue: try text(s, 2)) else { throw SnapshotError.invalidDatabase }
                claims.append(try ImportedReferenceClaim(sourceID: source, kind: kind, legacyToken: text(s, 3), identity: identity))
            }
        }
        var favorites: [ImportedLegacyReference] = [], hidden: [ImportedLegacyReference] = []
        try rows("SELECT key,value FROM settings WHERE key IN ('live.favoriteChannels','live.deletedChannels')") { s in
            let values = try ImportedMigrationDryRun.references(JSONDecoder().decode(JSONValue.self, from: blob(s, 1)))
            if try text(s, 0) == "live.favoriteChannels" { favorites = values } else { hidden = values }
        }
        var sources: [ImportedShadowRules.Source] = []
        try rows("SELECT id,name,base_url,raw_data FROM live_sources" + (schema == 12 ? " WHERE retired_at IS NULL" : "") + " ORDER BY id") { s in
            let sourceID = try uuid(s, 0), name = try text(s, 1), data = try blob(s, 3)
            let base = sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : URL(string: try text(s, 2))
            let parsed: ImportedPreMergeEvidence.Parsed
            do { parsed = try ImportedPreMergeEvidence.parse(data, baseURL: base) }
            catch {
                sources.append(ImportedShadowRules.Source(sourceID: sourceID, name: ImportedChannelMigrationPlanner.safeMetadata(name), format: "unavailable",
                    existingIdentities: registry.filter { $0.identity.source == .imported(sourceID) }.count, oldChannels: 0, oldRoutes: 0,
                    rawRecords: 0, groups: [], parseAvailable: false)); return
            }
            guard try ParserOutputEquivalence.digest(parsed.playlist) == ParserOutputEquivalence.digest(LiveSourceParser().parse(data, baseURL: base)) else { throw SnapshotError.invalidDatabase }
            let result = ImportedShadowRules.evaluate(sourceID: sourceID, sourceName: name, parsed: parsed, registry: registry, favorites: favorites, hidden: hidden, claims: claims)
            // Fresh HMAC equality labels on every parse must not affect output.
            let repeated = try ImportedPreMergeEvidence.parse(data, baseURL: base)
            guard result == ImportedShadowRules.evaluate(sourceID: sourceID, sourceName: name, parsed: repeated, registry: registry.reversed(), favorites: favorites.reversed(), hidden: hidden.reversed(), claims: claims.reversed()) else { throw SnapshotError.invalidDatabase }
            var reversedPlaylist = parsed.playlist
            reversedPlaylist.groups.reverse()
            for i in reversedPlaylist.groups.indices {
                reversedPlaylist.groups[i].channels.reverse()
                for j in reversedPlaylist.groups[i].channels.indices { reversedPlaylist.groups[i].channels[j].streams.reverse() }
            }
            guard result == ImportedShadowRules.evaluate(sourceID: sourceID, sourceName: name, playlist: reversedPlaylist,
                observations: parsed.observations.reversed(), registry: registry.reversed(), favorites: favorites.reversed(), hidden: hidden.reversed(), claims: claims.reversed()) else { throw SnapshotError.invalidDatabase }
            sources.append(result)
        }
        try rows("COMMIT") { _ in }
        let unchanged = before == SHA256.hash(data: try Data(contentsOf: snapshot))
        guard unchanged else { throw SnapshotError.invalidDatabase }
        sources.sort { $0.sourceID.uuidString < $1.sourceID.uuidString }
        return Report(ruleVersion: 1, schema: schema, retiredSourcesExcluded: retired.count, historicalRegistryCount: registry.count,
            legacyFavoriteCount: favorites.count, legacyHiddenCount: hidden.count, historicalClaimCount: claims.count,
            summaries: sources.map { .init(sourceID: $0.sourceID, name: $0.name, oldChannels: $0.oldChannels, proposedChannels: $0.proposedChannels,
                oldRoutes: $0.oldRoutes, proposedRoutes: $0.proposedRoutes, counts: $0.counts) }, sources: sources,
            snapshotBytesUnchanged: unchanged, parserOutputUnchanged: true, permutationVerified: true, uuidAllocations: 0, registryWrites: 0)
    }
}
