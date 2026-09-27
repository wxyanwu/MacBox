import XCTest
import Foundation
import CSQLite
import OKVideoCore
@testable import OKVideoPersistence
@testable import OKVideoMigrationDiagnostics

final class ImportedShadowTests: XCTestCase {
    private let source = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private func entry(_ id: String? = nil, group: String = "G", name: String = "X", url: String = "one", headers: String = "") -> String {
        "#EXTINF:-1 group-title=\"\(group)\"\(id.map { " tvg-id=\"\($0)\"" } ?? ""),\(name)\n\(headers)https://fixture.invalid/\(url)\n"
    }
    private func parsed(_ entries: [String]) throws -> ImportedPreMergeEvidence.Parsed {
        try ImportedPreMergeEvidence.parse(Data(("#EXTM3U\n" + entries.joined()).utf8))
    }
    private func evaluate(_ entries: [String], records: [ImportedChannelRegistryRecord] = [], favorites: [String] = [], hidden: [String] = [], claims: [ImportedReferenceClaim] = []) throws -> ImportedShadowRules.Source {
        ImportedShadowRules.evaluate(sourceID: source, sourceName: "Source", parsed: try parsed(entries), registry: records,
            favorites: favorites.map(ImportedLegacyReference.init), hidden: hidden.map(ImportedLegacyReference.init), claims: claims)
    }
    private func record(_ id: String? = nil, local: Int = 1, owner: UUID? = nil) throws -> ImportedChannelRegistryRecord {
        .init(identity: try ImportedLiveChannelIdentity(source: .imported(owner ?? source),
            localID: UUID(uuidString: String(format: "11111111-1111-1111-1111-%012d", local))!),
            evidence: ImportedChannelEvidence(group: "G", name: "X", tvgID: id), provenance: .verified, lifecycle: .active,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }
    func testDifferentNonblankIDsSplitButAllocateNothing() throws {
        let p = try evaluate([entry("1"), entry("2")])
        XCTAssertEqual(p.oldChannels, 1); XCTAssertEqual(p.proposedChannels, 2)
        XCTAssertEqual(p.groups[0].classification, .split); XCTAssertTrue(p.groups[0].runtimeKeyRisk)
        XCTAssertEqual(p.groups[0].identityImpact, "deferredByFrozen8BNoIdentityTransfer")
    }
    func testMixedPresentMissingIsAmbiguous() throws {
        let p = try evaluate([entry(), entry("1")]); XCTAssertNil(p.proposedChannels)
        XCTAssertNil(p.proposedRoutes); XCTAssertEqual(p.groups[0].classification, .ambiguous)
    }
    func testAllNoIDsProvisionalMultiRouteNotIdentityProof() throws {
        let p = try evaluate([entry(url: "a"), entry(url: "b")])
        XCTAssertEqual(p.proposedChannels, 1); XCTAssertEqual(p.proposedRoutes, 2)
        XCTAssertTrue(p.groups[0].reasons.contains("provisionalSameChannelMultiRouteNoPermanentIdentityProof"))
        XCTAssertEqual(p.groups[0].identityImpact, "deferredByFrozen8BNoIdentityTransfer")
        XCTAssertTrue(p.groups[0].frozen8BReasons.contains("insufficientIdentityEvidence"))
    }
    func testSameIDSameGroupRetainsChannel() throws {
        XCTAssertEqual(try evaluate([entry("1", url: "a"), entry("1", url: "b")]).proposedChannels, 1)
    }
    func testSameIDDoesNotMergeAcrossGroups() throws {
        let p = try evaluate([entry("1", group: "A"), entry("1", group: "B")])
        XCTAssertEqual(p.proposedChannels, 2); XCTAssertEqual(p.counts["merge"], 0)
        XCTAssertTrue(p.groups.allSatisfy { $0.reasons.contains("sameTVGIDAcrossGroupsOrNamesNoAutomaticKinship") })
    }
    func testSameURLDifferentHeadersNowPreservedButRuntimeKeyRiskRemains() throws {
        let p = try evaluate([entry(headers: "#EXTHTTP:{\"User-Agent\":\"A\"}\n"), entry(headers: "#EXTHTTP:{\"User-Agent\":\"B\"}\n")])
        // "old" means the current production parser, now using 8C.2 equality.
        // The frozen shadow rule is unchanged; Change C's key risk is not fixed.
        XCTAssertEqual(p.oldRoutes, 2); XCTAssertEqual(p.proposedRoutes, 2); XCTAssertEqual(p.proposedChannels, 1)
        XCTAssertEqual(p.groups[0].restoredRouteVariants, 0); XCTAssertTrue(p.groups[0].routeRuntimeKeyRisk)
        XCTAssertFalse(p.groups[0].runtimeKeyRisk)
    }
    func testExactRouteDuplicateStaysDeduped() throws {
        let p = try evaluate([entry(), entry()]); XCTAssertEqual(p.proposedRoutes, 1); XCTAssertEqual(p.counts["routeDedupeChange"], 0)
    }
    func testPropertiesDifferIndependentOfHeaders() throws {
        let p = try parsed([entry()]), e = ImportedChannelEvidence(group: "G", name: "X")
        let raw = ["mp4:false", "hls:true"].map {
            ImportedRawObservation(evidence: e, lines: [.init(locatorToken: "same", headersToken: "same", metadataToken: $0)])
        }
        let result = ImportedShadowRules.evaluate(sourceID: source, sourceName: "Source", playlist: p.playlist, observations: raw)
        XCTAssertEqual(result.proposedRoutes, 2); XCTAssertEqual(result.proposedChannels, 1)
        XCTAssertEqual(result.groups[0].sameURLDifferentProperties, 1)
    }
    func testAllSixMixedIDPermutationsHaveIdenticalEntireOutput() throws {
        let entries = [entry(), entry("1"), entry("2")]
        let expected = try evaluate(entries)
        for permutation in permutations(entries) { XCTAssertEqual(try evaluate(permutation), expected) }
    }
    func testAllTwentyFourSplitPermutationsPreservePartitionsAndImpacts() throws {
        let entries = [entry("1", url: "a"), entry("2", url: "b"), entry("1", url: "c"), entry("2", url: "d")]
        let expected = try evaluate(entries, records: [record("1")], hidden: ["\(source)::G::X"])
        for permutation in permutations(entries) {
            XCTAssertEqual(try evaluate(permutation, records: [record("1")], hidden: ["\(source)::G::X"]), expected)
        }
    }
    private func permutations<T>(_ input: [T]) -> [[T]] {
        guard !input.isEmpty else { return [[]] }
        return input.indices.flatMap { i in var rest = input; let first = rest.remove(at: i); return permutations(rest).map { [first] + $0 } }
    }
    func testHMACAndRawOrderAreNotReportIdentity() throws {
        let p = try parsed([entry(url: "a"), entry(url: "b")]), result = try evaluate([entry(url: "a"), entry(url: "b")])
        XCTAssertEqual(result, ImportedShadowRules.evaluate(sourceID: source, sourceName: "Source", playlist: p.playlist, observations: p.observations.reversed()))
    }
    func testHeaderDictionaryOrderDoesNotMatter() throws {
        let p = try evaluate([entry(headers: "#EXTHTTP:{\"A\":\"1\",\"B\":\"2\"}\n"), entry(headers: "#EXTHTTP:{\"B\":\"2\",\"A\":\"1\"}\n")])
        XCTAssertEqual(p.proposedRoutes, 1)
    }
    func testMetadataConflictDoesNotPickFirst() throws {
        let entries = [entry().replacingOccurrences(of: "group-title", with: "tvg-name=\"A\" group-title"),
                       entry().replacingOccurrences(of: "group-title", with: "tvg-name=\"B\" group-title")]
        XCTAssertEqual(try evaluate(entries).groups[0].classification, .ambiguous)
        XCTAssertEqual(try evaluate(entries), try evaluate(entries.reversed()))
    }
    func testDelimiterCollisionNotMerged() throws {
        let p = try evaluate([entry(group: "A::B", name: "C"), entry(group: "A", name: "B::C")])
        XCTAssertEqual(p.oldChannels, 2); XCTAssertNil(p.proposedChannels); XCTAssertTrue(p.groups.allSatisfy(\.runtimeKeyRisk))
    }
    func testNormalizationIsReportOnlyNotGrouping() throws {
        let p = try evaluate([entry(name: "CCTV-1"), entry(name: "CCTV1")]); XCTAssertEqual(p.proposedChannels, 2)
    }
    func testJSONDuplicateRuntimeIDsDeferredNoNewMerge() throws {
        let json = "[{\"name\":\"G\",\"channel\":[{\"name\":\"X\",\"urls\":[\"https://fixture.invalid/a\"]},{\"name\":\"X\",\"urls\":[\"https://fixture.invalid/b\"]}]}]"
        let p = ImportedShadowRules.evaluate(sourceID: source, sourceName: "Source", parsed: try ImportedPreMergeEvidence.parse(Data(json.utf8)))
        XCTAssertEqual(p.oldChannels, 2); XCTAssertNil(p.proposedChannels); XCTAssertEqual(p.counts["merge"], 0)
    }
    func testUniqueRegistryIsOnlyScreeningNotAuthority() throws {
        let p = try evaluate([entry()], records: [record()])
        XCTAssertEqual(p.groups[0].identityImpact, "uniqueExactEvidenceCandidateRequiresFullReconciliation")
    }
    func testRegistryAmbiguityNeverSelectsFirst() throws {
        let a = try record(), b = try record(local: 2)
        let p = try evaluate([entry()], records: [a, b])
        XCTAssertEqual(p.groups[0].identityImpact, "unresolvedRegistryEvidenceDoNotSelectFirst")
        XCTAssertEqual(p, try evaluate([entry()], records: [b, a]))
    }
    func testOtherSourceRegistryCannotMatch() throws {
        let r = try record(owner: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        XCTAssertEqual(try evaluate([entry()], records: [r]).groups[0].existingIdentities, 0)
    }
    func testSplitNeverBroadcastsClaimAndCountsFalseStableOwnership() throws {
        let r = try record("1"), c = try ImportedReferenceClaim(sourceID: source, kind: .hidden, legacyToken: "opaque", identity: r.identity)
        let p = try evaluate([entry("1"), entry("2")], records: [r], claims: [c])
        XCTAssertEqual(p.groups[0].claimedHidden, 1)
        XCTAssertEqual(p.groups[0].referenceImpact, "preserveNoBroadcastOneToManyOrUnresolved")
    }
    func testOpaqueReferencesWithDelimitersNeverSplitOrPrefixMatch() throws {
        let p = try evaluate([entry()], favorites: ["Source::G::X", "Source::G::X::suffix"], hidden: ["\(source)::G::X"])
        XCTAssertEqual(p.groups[0].legacyFavorites, 1); XCTAssertEqual(p.groups[0].legacyHidden, 1)
        XCTAssertTrue(p.groups[0].referenceImpact.contains("ProvenanceNotPromoted"))
    }
    func testSecretCanariesAreNotSerialized() throws {
        let p = try evaluate([entry("SECRET_TOKEN_DO_NOT_PERSIST", name: "Cookie=CANARY", url: "x?token=SECRET_TOKEN_DO_NOT_PERSIST", headers: "#EXTHTTP:{\"Authorization\":\"Bearer CANARY\"}\n")])
        let data = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        for secret in ["SECRET_TOKEN_DO_NOT_PERSIST", "CANARY", "Authorization", "Bearer", "fixture.invalid", "?token="] { XCTAssertFalse(data.contains(secret)) }
    }
    func testObserverEqualsProductionAcrossAllExistingFixtures() throws {
        for value in ParserOutputEquivalence.fixtures.values {
            let data = Data(value.utf8), base = URL(string: "https://fixture.invalid/base/")!
            XCTAssertEqual(try ParserOutputEquivalence.digest(ImportedPreMergeEvidence.parse(data, baseURL: base).playlist),
                           try ParserOutputEquivalence.digest(LiveSourceParser().parse(data, baseURL: base)))
        }
    }
    func testRouteOnlyAndSplitExperimentsHaveSeparateCounts() throws {
        let p = try evaluate([entry("1"), entry("2")])
        XCTAssertEqual(p.groups[0].routeOnlyProposedRoutes, 1); XCTAssertEqual(p.groups[0].proposedRoutes, 2)
    }
    private func directory(_ prefix: String = "OKVideoMac-8C1-Test-") throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/\(prefix)\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func legacySchema10Store(at url: URL) throws -> SQLiteStore {
        let store = try SQLiteStore(databaseURL: url)
        let connection = try SQLiteConnection(url: url)
        defer { connection.close() }
        // ImportedShadowDiff deliberately audits the frozen schema-10 format.
        // Keep its synthetic inputs independent of the application's current schema.
        try connection.execute("PRAGMA user_version=10")
        return store
    }
    func testRejectsRealDatabasePathWithoutOpeningIt() throws {
        XCTAssertThrowsError(try ImportedShadowDiff.run(temporaryInput: URL(fileURLWithPath: "/Users/never/Library/Database.sqlite3"), output: directory()))
    }
    func testOnlineBackupIncludesWALAndNeverMigratesInputOrSnapshot() async throws {
        let root = try directory("OKVideoMac-8B2-DryRun-ShadowTest-"), url = root.appendingPathComponent("snapshot.sqlite3")
        let store = try legacySchema10Store(at: url)
        let s = StoredLiveSource(id: source, name: "Source", sourceKind: .pasted, rawData: Data(("#EXTM3U\n" + entry()).utf8), updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.saveLiveSource(s)
        let before = try QuiescentDatabaseSnapshot.audit(database: url), out = try directory()
        let p = try ImportedShadowDiff.run(temporaryInput: url, output: out)
        XCTAssertEqual(p.schema, 10); XCTAssertEqual(p.sources.count, 1); XCTAssertEqual(p.sources[0].oldChannels, 1)
        XCTAssertEqual(p.historicalRegistryCount, 0); XCTAssertEqual(p.registryWrites, 0); XCTAssertEqual(p.uuidAllocations, 0)
        // SQLite READONLY backup participates in WAL read locks; the temporary
        // input's SHM read marks can change. Committed main/WAL content cannot.
        let after = try QuiescentDatabaseSnapshot.audit(database: url)
        XCTAssertEqual(after["main"], before["main"]); XCTAssertEqual(after["wal"], before["wal"])
        XCTAssertTrue(p.snapshotBytesUnchanged); XCTAssertTrue(p.permutationVerified)
        let sourceRows = try await store.liveSources(); XCTAssertEqual(sourceRows, [s])
        XCTAssertEqual(try ImportedShadowDiff.read(snapshot: out.appendingPathComponent("shadow.sqlite3")), p)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("ImportedShadowDiff.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testRetiredSourcesAreExcludedWithoutChangingTombstones() async throws {
        let root = try directory("OKVideoMac-8B3B-ShadowTest-"), workspace = try ImportedAcceptanceWorkspace(root: root)
        let db = try SQLiteStore(importedAcceptance: workspace)
        let s = StoredLiveSource(id: source, name: "Source", sourceKind: .pasted, rawData: Data(("#EXTM3U\n" + entry()).utf8))
        try await db.createLiveSource(s)
        let g = ImportedCatalogGeneration(sourceID: source); g.invalidate()
        try await db.retireImportedSource(id: source, revokedGeneration: g)
        let p = try ImportedShadowDiff.run(temporaryInput: workspace.databaseURL, output: directory())
        XCTAssertEqual(p.schema, 12); XCTAssertEqual(p.retiredSourcesExcluded, 1); XCTAssertTrue(p.sources.isEmpty)
        XCTAssertEqual(p.historicalRegistryCount, 0)
    }
    func testParseFailureRemainsVisibleAndUndecided() async throws {
        let root = try directory("OKVideoMac-8B2-DryRun-ShadowTest-"), url = root.appendingPathComponent("snapshot.sqlite3")
        let db = try legacySchema10Store(at: url)
        try await db.saveLiveSource(.init(id: source, name: "Source", sourceKind: .pasted, rawData: Data()))
        let p = try ImportedShadowDiff.run(temporaryInput: url, output: directory())
        XCTAssertFalse(p.sources[0].parseAvailable); XCTAssertNil(p.summaries[0].proposedChannels)
    }
    func testSourceAndDatabaseRowOrderDoNotChangeEntireReport() async throws {
        let a = StoredLiveSource(id: source, name: "A", sourceKind: .pasted, rawData: Data(("#EXTM3U\n" + entry()).utf8), updatedAt: Date(timeIntervalSince1970: 100))
        let b = StoredLiveSource(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, name: "B", sourceKind: .pasted,
            rawData: Data(("#EXTM3U\n" + entry("1") + entry("2")).utf8), updatedAt: Date(timeIntervalSince1970: 100))
        var reports: [ImportedShadowDiff.Report] = []
        for order in [[a, b], [b, a]] {
            let input = try directory("OKVideoMac-8B2-DryRun-ShadowTest-").appendingPathComponent("snapshot.sqlite3")
            let db = try legacySchema10Store(at: input)
            for s in order { try await db.saveLiveSource(s) }
            reports.append(try ImportedShadowDiff.run(temporaryInput: input, output: directory()))
        }
        XCTAssertEqual(reports[0], reports[1]); XCTAssertEqual(try reports[0].json(), try reports[1].json())
    }
    func testJSONAndMarkdownReportsNeverIncludeCanaryPayloads() async throws {
        let input = try directory("OKVideoMac-8B2-DryRun-ShadowTest-").appendingPathComponent("snapshot.sqlite3")
        let db = try legacySchema10Store(at: input)
        let raw = "#EXTM3U\n" + entry("1", name: "SECRET_TOKEN_DO_NOT_PERSIST", headers: "#EXTHTTP:{\"Authorization\":\"Bearer CANARY\",\"Cookie\":\"CANARY\"}\n") + entry("2", name: "SECRET_TOKEN_DO_NOT_PERSIST")
        try await db.saveLiveSource(.init(id: source, name: "SECRET_TOKEN_DO_NOT_PERSIST", sourceKind: .pasted, rawData: Data(raw.utf8)))
        let report = try ImportedShadowDiff.run(temporaryInput: input, output: directory())
        let output = String(decoding: try report.json(), as: UTF8.self) + report.markdown()
        for value in ["SECRET_TOKEN_DO_NOT_PERSIST", "CANARY", "Authorization", "Cookie", "Bearer", "fixture.invalid"] { XCTAssertFalse(output.contains(value)) }
    }
}
