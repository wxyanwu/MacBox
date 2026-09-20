import Foundation
import XCTest
@testable import OKVideoCore

final class ImportedChannelReconciliationTests: XCTestCase {
    private let source = LiveSourceID.imported(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let otherSource = LiveSourceID.imported(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
    private func token(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
    private func identity(_ n: Int = 1, source: LiveSourceID? = nil) -> ImportedLiveChannelIdentity {
        try! ImportedLiveChannelIdentity(source: source ?? self.source, localID: token(n))
    }
    private func evidence(_ name: String = "CCTV-1", group: String = "News", tvg: String? = nil,
                          upstream: String? = nil, verified: Bool = true, namespace: String = "fixture",
                          region: String? = nil, language: String? = nil, type: String? = nil) -> ImportedChannelEvidence {
        ImportedChannelEvidence(group: group, name: name,
            upstream: upstream.map { ImportedUpstreamEvidence(namespace: namespace, value: $0, formatSupportsStableID: verified) },
            tvgID: tvg, region: region, language: language, channelType: type)
    }
    private func old(_ metadata: ImportedChannelEvidence, _ n: Int = 1, source: LiveSourceID? = nil) -> ImportedExistingChannel {
        ImportedExistingChannel(identity: identity(n, source: source), evidence: metadata)
    }
    private func candidate(_ metadata: ImportedChannelEvidence, _ n: Int = 100, source: LiveSourceID? = nil,
                           provenance: ImportedSourceProvenance = .verified,
                           legacy: ImportedLegacyReference? = nil) -> ImportedChannelCandidate {
        ImportedChannelCandidate(candidateID: token(n), source: source ?? self.source,
            provenance: provenance, evidence: metadata, legacyReference: legacy)
    }
    private func plan(_ old: [ImportedExistingChannel], _ new: [ImportedChannelCandidate],
                      complete: Bool = true) throws -> [ImportedReconciliationResult] {
        try ImportedChannelReconciler.reconcile(existing: old, candidates: new, catalogsAreComplete: complete)
    }
    private func outcome(_ a: ImportedChannelEvidence, _ b: ImportedChannelEvidence) throws -> ImportedReconciliationOutcome {
        try XCTUnwrap(plan([old(a)], [candidate(b)]).first).outcome
    }

    func testIdentityIsSourceScoped() {
        XCTAssertNotEqual(identity(), identity(source: otherSource))
        XCTAssertEqual(Set([identity(), identity(), identity(source: otherSource)]).count, 2)
    }
    func testIdentityCodableAndHashableRoundTrip() throws {
        let value = identity()
        let data = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(ImportedLiveChannelIdentity.self, from: data)
        XCTAssertEqual(value, restored)
        XCTAssertEqual(restored.source, source)
        XCTAssertTrue(Set([value]).contains(restored))
    }
    func testPermanentIdentityContainsOnlyTypedSourceAndLocalUUID() throws {
        let data = try JSONEncoder().encode(identity())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["kind", "sourceID", "localID"])
        XCTAssertEqual(object["kind"], "imported")
        // No URL, tvg-id, mutable metadata or credential field is serializable.
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("http"))
    }
    func testNativeIdentityConstructionRejected() {
        XCTAssertThrowsError(try ImportedLiveChannelIdentity(source: .xtream(token(1)), localID: token(2)))
    }
    func testNativeIdentityDecodingRejected() {
        let data = Data("{\"kind\":\"xtream\",\"sourceID\":\"\(token(1))\",\"localID\":\"\(token(2))\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ImportedLiveChannelIdentity.self, from: data))
    }
    func testUniqueVerifiedUpstreamSurvivesNameAndGroupChange() throws {
        let result = try plan([old(evidence(upstream: "1"))], [candidate(evidence("Renamed", group: "Other", upstream: "1"))])
        XCTAssertEqual(result[0].outcome, .matched(identity()))
        XCTAssertTrue(result[0].evidence.contains { $0.kind == .upstreamID && $0.isStrong })
    }
    func testUpstreamIsSourceScoped() throws {
        let result = try plan([old(evidence(upstream: "1"), source: otherSource)], [candidate(evidence(upstream: "1"))])
        XCTAssertEqual(result[0].outcome, .newIdentityRequired)
        XCTAssertTrue(result[0].evidence.allSatisfy { $0.existingCount == 0 })
    }
    func testDuplicateOldUpstreamIsConflictDespiteExactName() throws {
        let result = try plan([old(evidence("A", upstream: "1")), old(evidence("B", upstream: "1"), 2)],
                              [candidate(evidence("A", upstream: "1"))])[0]
        XCTAssertEqual(result.outcome, .conflict)
        XCTAssertTrue(result.reasons.contains(.duplicateUpstreamID))
        XCTAssertFalse(result.evidence.contains { $0.isStrong })
    }
    func testDuplicateIncomingUpstreamIsConflictForEveryClaimant() throws {
        let result = try plan([old(evidence(upstream: "1"))],
                             [candidate(evidence("A", upstream: "1")), candidate(evidence("B", upstream: "1"), 101)])
        XCTAssertTrue(result.allSatisfy { $0.outcome == .conflict && $0.reasons.contains(.duplicateUpstreamID) })
    }
    func testChangedUpstreamDoesNotReuseViaName() throws {
        XCTAssertEqual(try outcome(evidence(upstream: "old"), evidence(upstream: "new")), .conflict)
    }
    func testChangedUpstreamAndNameCannotProveRename() throws {
        XCTAssertEqual(try outcome(evidence("A", upstream: "old"), evidence("B", upstream: "new")), .newIdentityRequired)
    }
    func testUnverifiedUpstreamAloneIsNotStrong() throws {
        let result = try plan([old(evidence("A", upstream: "1", verified: false))],
                             [candidate(evidence("B", upstream: "1", verified: false))])[0]
        XCTAssertEqual(result.outcome, .unresolved)
        XCTAssertFalse(result.evidence.contains { $0.isStrong })
    }
    func testBothSidesMustAttestUpstreamFormat() throws {
        XCTAssertEqual(try outcome(evidence("A", upstream: "1", verified: false), evidence("B", upstream: "1")), .unresolved)
        XCTAssertEqual(try outcome(evidence("A", upstream: "1"), evidence("B", upstream: "1", verified: false)), .unresolved)
    }
    func testUpstreamNamespaceIsPartOfEvidence() throws {
        XCTAssertEqual(try outcome(evidence(upstream: "1", namespace: "one"), evidence(upstream: "1", namespace: "two")), .conflict)
    }
    func testTVGWithCompatibleNameIsEvidenceNotPrimaryKey() throws {
        let result = try plan([old(evidence(tvg: "CCTV1"))], [candidate(evidence(tvg: "CCTV1"))])[0]
        XCTAssertEqual(result.outcome, .matched(identity()))
        XCTAssertEqual(result.evidence.first { $0.kind == .tvgID }?.existingCount, 1)
        XCTAssertFalse(result.evidence.first { $0.kind == .tvgID }!.isStrong)
    }
    func testTVGAloneInsufficient() throws {
        XCTAssertEqual(try outcome(evidence("A", tvg: "shared"), evidence("B", tvg: "shared")), .unresolved)
    }
    func testSharedOldTVGIsAmbiguousDespiteExactName() throws {
        let result = try plan([old(evidence("A", tvg: "shared")), old(evidence("B", tvg: "shared"), 2)],
                             [candidate(evidence("A", tvg: "shared"))])[0]
        XCTAssertEqual(result.outcome, .ambiguous)
    }
    func testSharedTVGCanBeResolvedByIndependentStrongEvidence() throws {
        let result = try plan([old(evidence("A", tvg: "shared", upstream: "1")), old(evidence("B", tvg: "shared", upstream: "2"), 2)],
                             [candidate(evidence("A", tvg: "shared", upstream: "1")), candidate(evidence("B", tvg: "shared", upstream: "2"), 101)])
        XCTAssertEqual(result.map(\.outcome), [.matched(identity()), .matched(identity(2))])
    }
    func testSharedIncomingTVGWithoutStrongEvidenceIsAmbiguous() throws {
        let result = try plan([old(evidence("A", tvg: "shared"))],
                             [candidate(evidence("A", tvg: "shared")), candidate(evidence("B", tvg: "shared"), 101)])
        XCTAssertTrue(result.allSatisfy { $0.outcome == .ambiguous })
    }
    func testAddingTVGPreservesLocalUUID() throws {
        XCTAssertEqual(try outcome(evidence(), evidence(tvg: "new-guide-id")), .matched(identity()))
    }
    func testRemovingTVGPreservesLocalUUID() throws {
        XCTAssertEqual(try outcome(evidence(tvg: "old"), evidence(tvg: "  ")), .matched(identity()))
    }
    func testCorrectingTVGWithStrongEvidencePreservesLocalUUID() throws {
        XCTAssertEqual(try outcome(evidence(tvg: "old", upstream: "1"), evidence(tvg: "new", upstream: "1")), .matched(identity()))
    }
    func testCorrectingTVGWithoutIndependentStrongEvidenceIsConflict() throws {
        XCTAssertEqual(try outcome(evidence(tvg: "old"), evidence(tvg: "new")), .conflict)
    }
    func testRegionConflictIsNotHiddenByTVGOrStrongEvidence() throws {
        XCTAssertEqual(try outcome(evidence(tvg: "same", upstream: "1", region: "北京"),
                                   evidence(tvg: "same", upstream: "1", region: "上海")), .conflict)
    }
    func testLanguageAndTypeConflictsArePreserved() throws {
        XCTAssertEqual(try outcome(evidence(language: "en"), evidence(language: "fr")), .conflict)
        XCTAssertEqual(try outcome(evidence(type: "news"), evidence(type: "sport")), .conflict)
    }
    func testExactGroupAndNameCompatibility() throws {
        XCTAssertEqual(try outcome(evidence(), evidence()), .matched(identity()))
    }
    func testNFKCCompatibility() throws {
        XCTAssertEqual(try outcome(evidence("ＣＣＴＶ－１", group: "Ｎｅｗｓ"), evidence()), .matched(identity()))
    }
    func testWhitespaceCollapse() throws {
        XCTAssertEqual(try outcome(evidence("News  Channel", group: "My\tGroup"),
                                   evidence(" News\nChannel ", group: " My Group ")), .matched(identity()))
    }
    func testCaseNormalization() throws {
        XCTAssertEqual(try outcome(evidence("cctv-1", group: "news"), evidence()), .matched(identity()))
    }
    func testCCTVPlusIsNotRemoved() throws {
        XCTAssertEqual(try outcome(evidence("CCTV-5"), evidence("CCTV-5+")), .newIdentityRequired)
    }
    func testNumbersAreNotPrefixMatched() throws {
        XCTAssertEqual(try outcome(evidence("CCTV-1"), evidence("CCTV-13")), .newIdentityRequired)
    }
    func testRegionalSuffixIsNotRemoved() throws {
        XCTAssertEqual(try outcome(evidence("News 北京"), evidence("News 上海")), .newIdentityRequired)
    }
    func testQualitySuffixesAreNotRemoved() throws {
        for suffix in [" HD", "高清", "超清"] {
            XCTAssertEqual(try outcome(evidence("CCTV-1"), evidence("CCTV-1" + suffix)), .newIdentityRequired)
        }
    }
    func testEPGCCTVAliasesAreNotUsed() throws {
        for name in ["CCTV1", "CCTV 1"] {
            XCTAssertEqual(try outcome(evidence("CCTV-1"), evidence(name)), .newIdentityRequired)
        }
    }
    func testUnknownNamesDoNotUseFuzzyContainsOrPrefix() throws {
        for name in ["CCTV-", "CCTV-1 News", "CCTV-2", "CCVT-1"] {
            XCTAssertEqual(try outcome(evidence(), evidence(name)), .newIdentityRequired)
        }
    }
    func testNormalizedCollisionDoesNotPreferExactSpelling() throws {
        let result = try plan([old(evidence("News")), old(evidence("NEWS"), 2)], [candidate(evidence("News"))])[0]
        XCTAssertEqual(result.outcome, .ambiguous)
    }
    // URL tests deliberately project synthetic fixture transport data to the pure
    // contract. They prove exclusion from 8A inputs, NOT production parser wiring.
    private func projection(_ channel: LiveChannel) -> ImportedChannelEvidence {
        evidence(channel.name, group: channel.groupName, tvg: channel.tvgID)
    }
    private func fixture(_ urls: [String], name: String = "CCTV-1", tvg: String? = nil) -> LiveChannel {
        LiveChannel(groupName: "News", name: name, tvgID: tvg,
                    streams: urls.map { LiveStream(name: "line", url: URL(string: $0)!) })
    }
    func testTokenChangeDoesNotEnterIdentity() throws {
        let a = projection(fixture(["https://example.invalid/a?token=A"]))
        let b = projection(fixture(["https://example.invalid/a?token=B"]))
        XCTAssertEqual(a, b)
        XCTAssertEqual(try outcome(a, b), .matched(identity()))
    }
    func testHostChangeDoesNotEnterIdentity() throws {
        let a = projection(fixture(["https://a.invalid/live"]))
        let b = projection(fixture(["https://b.invalid/live"]))
        XCTAssertEqual(try outcome(a, b), .matched(identity()))
    }
    func testSameURLDoesNotOverrideMetadataConflict() throws {
        let url = "https://example.invalid/live"
        XCTAssertEqual(try outcome(projection(fixture([url], tvg: "A")),
                                   projection(fixture([url], tvg: "B"))), .conflict)
    }
    func testLineOrderAndCountDoNotAffectPlan() throws {
        let urls = ["https://a.invalid/live", "https://b.invalid/live"]
        let a = projection(fixture(urls))
        for lines in [Array(urls.reversed()), [], [urls[0]], urls + [urls[0]]] {
            XCTAssertEqual(try outcome(a, projection(fixture(lines))), .matched(identity()))
        }
    }
    func testCatalogOrderDoesNotAffectResultsOrDiagnostics() throws {
        let previous = [old(evidence("A", upstream: "1")), old(evidence("B", upstream: "2"), 2), old(evidence("C"), 3)]
        let current = [candidate(evidence("A", upstream: "1")), candidate(evidence("B", upstream: "2"), 101), candidate(evidence("C"), 102)]
        XCTAssertEqual(try plan(previous, current), try plan(previous.reversed(), [current[2], current[0], current[1]]))
    }
    func testEvidenceDictionaryConstructionOrderDoesNotAffectPlan() throws {
        func metadata(_ entries: [(String, String)]) -> ImportedChannelEvidence {
            let values = Dictionary(uniqueKeysWithValues: entries)
            return evidence(values["name"]!, group: values["group"]!, tvg: values["tvg"], upstream: values["upstream"])
        }
        let values = [("name", "A"), ("group", "G"), ("tvg", "T"), ("upstream", "U")]
        let previous = [old(metadata(values))]
        XCTAssertEqual(try plan(previous, [candidate(metadata(values))]),
                       try plan(previous, [candidate(metadata(values.reversed()))]))
    }
    func testUpstreamAAndTVGBProduceConflict() throws {
        let result = try plan([old(evidence("A", tvg: "a", upstream: "1")), old(evidence("B", tvg: "b", upstream: "2"), 2)],
                             [candidate(evidence("A", tvg: "b", upstream: "1"))])[0]
        XCTAssertEqual(result.outcome, .conflict)
        XCTAssertTrue(result.reasons.contains(.evidenceDisagreement))
    }
    func testNameAAndStrongBProduceConflict() throws {
        let result = try plan([old(evidence("A", upstream: "1")), old(evidence("B", upstream: "2"), 2)],
                             [candidate(evidence("A", upstream: "2"))])[0]
        XCTAssertEqual(result.outcome, .conflict)
    }
    func testNoEvidenceIsUnresolved() throws {
        XCTAssertEqual(try plan([], [candidate(evidence("  "))])[0].outcome, .unresolved)
    }
    func testNewChannelRequestsAllocationWithoutGeneratingUUID() throws {
        let input = [candidate(evidence("New"))]
        let first = try plan([], input)
        XCTAssertEqual(first[0].outcome, .newIdentityRequired)
        XCTAssertEqual(first, try plan([], input))
    }
    func testAllEvidenceLookupsIgnoreOtherSource() throws {
        let result = try plan([old(evidence(tvg: "1", upstream: "1"), source: otherSource)],
                             [candidate(evidence(tvg: "1", upstream: "1"))])[0]
        XCTAssertTrue(result.evidence.allSatisfy { $0.existingCount == 0 })
        XCTAssertEqual(result.outcome, .newIdentityRequired)
    }
    func testOtherSourceDuplicatesDoNotPoisonCurrentSource() throws {
        let result = try plan([old(evidence(upstream: "1")), old(evidence(upstream: "1"), 2, source: otherSource),
                              old(evidence(upstream: "1"), 3, source: otherSource)], [candidate(evidence(upstream: "1"))])[0]
        XCTAssertEqual(result.outcome, .matched(identity()))
    }
    func testSourceDeleteAndReaddCannotReuseIdentity() throws {
        let result = try plan([old(evidence())], [candidate(evidence(), source: otherSource)])[0]
        XCTAssertEqual(result.outcome, .newIdentityRequired)
    }
    func testUnknownSourceProvenanceFailsClosedDespiteUniqueName() throws {
        let result = try plan([old(evidence())], [candidate(evidence(), provenance: .unknown)])[0]
        XCTAssertEqual(result.outcome, .unresolved)
        XCTAssertEqual(result.reasons, [.unknownSourceProvenance])
    }
    func testIncompleteCatalogCannotAssertUniquenessOrAllocate() throws {
        let result = try plan([old(evidence())], [candidate(evidence()), candidate(evidence("New"), 101)], complete: false)
        XCTAssertTrue(result.allSatisfy { $0.outcome == .unresolved && $0.reasons == [.incompleteCatalog] })
    }
    func testNativeCandidateFailsClosed() throws {
        let result = try plan([], [candidate(evidence(), source: .xtream(token(1)))])[0]
        XCTAssertEqual(result.outcome, .unresolved)
        XCTAssertEqual(result.reasons, [.unsupportedSource])
    }
    func testLegacyReferenceIsOpaqueAndUnchanged() {
        let raw = "source::with::separator::group::name"
        let reference = ImportedLegacyReference(raw)
        XCTAssertEqual(reference.rawValue, raw)
        XCTAssertFalse(String(reflecting: reference).contains(raw))
    }
    func testDelimiterCollisionDoesNotMergeStructuredNames() throws {
        XCTAssertEqual(try outcome(evidence("c", group: "a::b"), evidence("b::c", group: "a")), .newIdentityRequired)
    }
    func testUnmatchedLegacyReferenceIsRetainedUnresolvedNotAllocated() throws {
        let reference = ImportedLegacyReference("Unknown::Group::Name")
        let input = candidate(evidence("New"), legacy: reference)
        XCTAssertEqual(try plan([], [input])[0].outcome, .unresolved)
        XCTAssertEqual(input.legacyReference, reference)
    }
    func testOpaqueLegacyNeverGrantsSourceOwnership() throws {
        let input = candidate(evidence(), provenance: .unknown, legacy: ImportedLegacyReference("News::CCTV-1"))
        XCTAssertEqual(try plan([old(evidence())], [input])[0].outcome, .unresolved)
    }
    func testTwoIncomingNamesCannotBothClaimOldIdentity() throws {
        let result = try plan([old(evidence("News"))], [candidate(evidence("News")), candidate(evidence("NEWS"), 101)])
        XCTAssertTrue(result.allSatisfy { $0.outcome == .ambiguous })
    }
    func testDifferentEvidenceCannotAssignOneOldUUIDTwice() throws {
        let previous = [old(evidence("Old", upstream: "1"))]
        let current = [candidate(evidence("Renamed", upstream: "1")), candidate(evidence("Old"), 101)]
        let result = try plan(previous, current)
        XCTAssertTrue(result.allSatisfy { $0.outcome == .ambiguous && $0.reasons.contains(.multipleIncomingClaims) })
    }
    func testMalformedBatchDuplicateCandidateTokensRejected() {
        XCTAssertThrowsError(try plan([], [candidate(evidence("A")), candidate(evidence("B"))]))
    }
    func testMalformedBatchDuplicateDurableIdentitiesRejected() {
        XCTAssertThrowsError(try plan([old(evidence("A")), old(evidence("B"))], [candidate(evidence())]))
    }
    func testDebugDescriptionsAndResultsDoNotEchoExternalMetadata() throws {
        let canary = "SECRET-CANARY"
        let metadata = evidence(canary, group: canary, tvg: canary, upstream: canary, namespace: canary)
        let input = candidate(metadata, legacy: ImportedLegacyReference(canary))
        let result = try plan([old(metadata)], [input])
        for text in [String(describing: metadata), String(reflecting: metadata), String(reflecting: input), String(reflecting: result)] {
            XCTAssertFalse(text.contains(canary))
        }
    }
    func testBlankIDsDoNotCreateEvidenceBuckets() throws {
        let result = try plan([old(evidence())], [candidate(evidence(tvg: " \n", upstream: " \t"))])[0]
        XCTAssertEqual(result.outcome, .matched(identity()))
        XCTAssertFalse(result.evidence.contains { $0.kind == .upstreamID || $0.kind == .tvgID })
    }
    func testTVGExactMatchingDoesNotCaseFoldIDs() throws {
        XCTAssertEqual(try outcome(evidence(tvg: "ID"), evidence(tvg: "id")), .conflict)
    }
    func testLargeCollisionBucketHasBoundedDiagnostics() throws {
        let previous = (1...10_000).map { old(evidence("Same"), $0) }
        let current = (20_000...20_999).map { candidate(evidence("Same"), $0) }
        let result = try plan(previous, current)
        XCTAssertEqual(result.count, 1_000)
        XCTAssertTrue(result.allSatisfy { $0.outcome == .ambiguous && $0.evidence.count == 2 })
        XCTAssertTrue(result.allSatisfy { $0.evidence.allSatisfy { $0.existingCount == 10_000 && $0.uniqueIdentity == nil } })
    }
}
