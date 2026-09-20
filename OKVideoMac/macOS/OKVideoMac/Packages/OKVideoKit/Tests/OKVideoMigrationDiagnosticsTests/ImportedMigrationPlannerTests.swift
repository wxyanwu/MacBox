import Foundation
import XCTest
import OKVideoCore
@testable import OKVideoMigrationDiagnostics

final class ImportedMigrationPlannerTests: XCTestCase {
    private let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private func channel(_ name: String = "CCTV-1", group: String = "央视", id: String? = nil, tvg: String? = nil) -> MigrationChannel {
        MigrationChannel(legacyChannelID: id ?? "\(group)::\(name)", evidence: ImportedChannelEvidence(group: group, name: name, tvgID: tvg))
    }
    private func raw(_ c: MigrationChannel, line: String = "line", headers: String = "headers") -> ImportedRawObservation {
        ImportedRawObservation(evidence: c.evidence, locatorToken: line, headersToken: headers)
    }
    private func source(_ channels: [MigrationChannel]? = nil, id: UUID? = nil, name: String = "联通",
                        existing: [ImportedExistingChannel] = [], unknownRaw: Bool = false,
                        observations: [ImportedRawObservation]? = nil, complete: Bool = true,
                        provenance: ImportedSourceProvenance = .unknown) -> MigrationSourceSnapshot {
        let c = channels ?? [channel()]
        return MigrationSourceSnapshot(id: id ?? a, name: name, format: "fixture", channels: c,
            existing: existing, rawObservations: unknownRaw ? nil : observations ?? c.map { raw($0) },
            catalogComplete: complete, favoriteProvenance: provenance)
    }
    private func existing(_ c: MigrationChannel, n: Int = 1, source: UUID? = nil) throws -> ImportedExistingChannel {
        let id = UUID(uuidString: String(format: "11111111-1111-1111-1111-%012d", n))!
        return ImportedExistingChannel(identity: try ImportedLiveChannelIdentity(source: .imported(source ?? a), localID: id), evidence: c.evidence)
    }
    private func plan(_ sources: [MigrationSourceSnapshot]? = nil, favorites: [String] = [], hidden: [String] = []) throws -> ImportedChannelMigrationPlan {
        try ImportedChannelMigrationPlanner.plan(sources: sources ?? [source()],
            favorites: favorites.map(ImportedLegacyReference.init), hidden: hidden.map(ImportedLegacyReference.init))
    }
    private func favorite(_ c: MigrationChannel, name: String = "联通") -> String {
        ImportedChannelMigrationPlanner.favoriteKey(sourceName: name, channelID: c.legacyChannelID)
    }
    private func hidden(_ c: MigrationChannel, id: UUID? = nil) -> String {
        ImportedChannelMigrationPlanner.hiddenKey(sourceID: id ?? a, channelID: c.legacyChannelID)
    }

    func testEmptyRegistryPlansAllocationWithoutIdentity() throws {
        let p = try plan(); XCTAssertEqual(p.channels[0].classification, .allocateNew)
        XCTAssertTrue(p.channels[0].allocationRequired); XCTAssertNil(p.channels[0].existingIdentity)
    }
    func testExistingIdentityIsReused() throws {
        let old = try existing(channel()); let p = try plan([source(existing: [old])])
        XCTAssertEqual(p.channels[0].classification, .safeMatched); XCTAssertEqual(p.channels[0].existingIdentity, old.identity)
    }
    func testAmbiguousOldIdentitiesPreserveHidden() throws {
        let p = try plan([source(existing: [existing(channel()), existing(channel(), n: 2)])], hidden: [hidden(channel())])
        XCTAssertEqual(p.references[0].classification, .ambiguous); XCTAssertTrue(p.references[0].action.hasPrefix("preserve"))
    }
    func testConflictingTVGEvidencePreservesHidden() throws {
        let p = try plan([source([channel(tvg: "B")], existing: [existing(channel(tvg: "A"))])], hidden: [hidden(channel())])
        XCTAssertEqual(p.references[0].classification, .conflict)
    }
    func testIncompleteCatalogUnresolved() throws {
        let p = try plan([source(complete: false)], hidden: [hidden(channel())])
        XCTAssertEqual(p.references[0].classification, .unresolved)
    }
    func testOrphanPreserved() throws {
        let r = try plan(favorites: ["unrecoverable::opaque"]).references[0]
        XCTAssertEqual(r.classification, .orphanedLegacyReference); XCTAssertTrue(r.action.hasPrefix("preserve"))
    }
    func testOpaqueFavoriteExactKeyWithDelimiters() throws {
        let c = channel("name::part", group: "group::part")
        let r = try plan([source([c], name: "source::part")], favorites: [favorite(c, name: "source::part")]).references[0]
        XCTAssertTrue(r.syntacticallyUnique); XCTAssertEqual(r.classification, .sourceProvenanceUnknown)
    }
    func testNoFavoritePrefixMatching() throws {
        XCTAssertEqual(try plan(favorites: [favorite(channel()) + "::suffix"]).references[0].classification, .orphanedLegacyReference)
    }
    func testCurrentUniqueSourceNameIsNotHistory() throws {
        let r = try plan(favorites: [favorite(channel())]).references[0]
        XCTAssertTrue(r.syntacticallyUnique); XCTAssertFalse(r.historicallyTrusted)
        XCTAssertEqual(r.classification, .sourceProvenanceUnknown)
    }
    func testTwoSameNamedSourcesAmbiguous() throws {
        let p = try plan([source(), source(id: b)], favorites: [favorite(channel())])
        XCTAssertEqual(p.references[0].classification, .ambiguous); XCTAssertEqual(p.references[0].candidates.count, 2)
        XCTAssertEqual(p.references.count, 1)
    }
    func testDuplicateFavoriteDoesNotBroadcast() throws {
        let p = try plan([source(), source(id: b)], favorites: [favorite(channel()), favorite(channel())])
        XCTAssertEqual(p.references.count, 1); XCTAssertEqual(p.references[0].classification, .ambiguous)
    }
    func testExplicitVerifiedFavoriteOwnershipCanPlan() throws {
        let p = try plan([source(provenance: .verified)], favorites: [favorite(channel())])
        XCTAssertEqual(p.references[0].classification, .safeLegacyMigrationCandidate)
        XCTAssertTrue(p.references[0].action.contains("would migrate")); XCTAssertTrue(p.allocationIsIntentOnly)
    }
    func testHiddenSourceUUIDScoping() throws {
        let p = try plan([source(), source(id: b)], hidden: [hidden(channel())])
        XCTAssertEqual(p.references[0].candidates.count, 1); XCTAssertEqual(p.references[0].classification, .safeLegacyMigrationCandidate)
    }
    func testHiddenUniqueCorrespondence() throws {
        let r = try plan(hidden: [hidden(channel())]).references[0]
        XCTAssertTrue(r.syntacticallyUnique); XCTAssertTrue(r.historicallyTrusted)
    }
    func testHiddenLegacyIDCollision() throws {
        let c = channel("B", id: channel().legacyChannelID)
        let p = try plan([source([channel(), c])], hidden: [hidden(channel())])
        XCTAssertEqual(p.references[0].classification, .ambiguous)
        XCTAssertTrue(p.channels.allSatisfy { $0.classification == .ambiguous })
    }
    func testDeleteReaddDifferentUUIDDoesNotInherit() throws {
        let p = try plan([source(id: b)], hidden: [hidden(channel())])
        XCTAssertEqual(p.references[0].classification, .orphanedLegacyReference)
    }
    func testHiddenOpaqueDelimiters() throws {
        let c = channel("a::b", group: "c::d")
        XCTAssertEqual(try plan([source([c])], hidden: [hidden(c)]).references[0].classification, .safeLegacyMigrationCandidate)
    }
    func testDifferentTVGIDsSplitRisk() throws {
        let p = try plan([source(observations: [raw(channel(tvg: "1")), raw(channel(tvg: "2"))])])
        XCTAssertEqual(p.channels[0].classification, .futureSplitRisk)
        XCTAssertTrue(p.channels[0].reasons.contains("conflictingTVGIDs"))
    }
    func testPresentAndMissingIDSplitRisk() throws {
        let p = try plan([source(observations: [raw(channel()), raw(channel(tvg: "1"))])])
        XCTAssertTrue(p.channels[0].reasons.contains("mixedPresentMissingTVGID"))
    }
    func testRawDuplicatesRequireReview() throws {
        let p = try plan([source(observations: [raw(channel()), raw(channel())])])
        XCTAssertEqual(p.channels[0].classification, .futureSplitRisk); XCTAssertFalse(p.channels[0].allocationRequired)
    }
    func testSameLocatorDifferentHeadersRisk() throws {
        let p = try plan([source(observations: [raw(channel(), headers: "A"), raw(channel(), headers: "B")])])
        XCTAssertTrue(p.channels[0].reasons.contains("lineMetadataConflict"))
    }
    func testRawOrderDoesNotChangeRisk() throws {
        let r = [raw(channel(tvg: "1")), raw(channel(tvg: "2"))]
        XCTAssertEqual(try plan([source(observations: r)]), try plan([source(observations: r.reversed())]))
    }
    func testSourceOrderDeterministic() throws {
        XCTAssertEqual(try plan([source(), source(id: b)]), try plan([source(id: b), source()]))
    }
    func testChannelOrderDeterministic() throws {
        let c = [channel(), channel("CCTV-2")]
        XCTAssertEqual(try plan([source(c)]), try plan([source(c.reversed())]))
    }
    func testLineOrderDeterministicJSON() throws {
        let r = [raw(channel(), line: "A"), raw(channel(), line: "B")]
        XCTAssertEqual(try plan([source(observations: r)]).json(), try plan([source(observations: r.reversed())]).json())
    }
    func testRegistryRowOrderDeterministic() throws {
        let c = [channel(), channel("CCTV-2")]; let old = try [existing(c[0]), existing(c[1], n: 2)]
        XCTAssertEqual(try plan([source(c, existing: old)]), try plan([source(c, existing: old.reversed())]))
    }
    func testReferenceOrderDeterministic() throws {
        XCTAssertEqual(try plan(favorites: ["B", "A"]), try plan(favorites: ["A", "B"]))
    }
    func testDiagnosticTokenNotPermanentUUID() throws {
        let c = try plan().channels[0]; XCTAssertEqual(c.token, "P0001"); XCTAssertNil(UUID(uuidString: c.token)); XCTAssertNil(c.existingIdentity)
    }
    func testUnknownRawEvidenceBlocksAllocation() throws {
        let p = try plan([source(unknownRaw: true)])
        XCTAssertNil(p.sources[0].rawRecords); XCTAssertFalse(p.sources[0].splitRiskProven)
        XCTAssertEqual(p.channels[0].classification, .unresolved); XCTAssertFalse(p.channels[0].allocationRequired)
    }
    func testUnknownRawEvidenceBlocksHidden() throws {
        XCTAssertEqual(try plan([source(unknownRaw: true)], hidden: [hidden(channel())]).references[0].classification, .unresolved)
    }
    func testMissingRawChannelCannotProveCoverage() throws {
        let p = try plan([source([channel(), channel("CCTV-2")], observations: [raw(channel())])])
        XCTAssertTrue(p.channels.allSatisfy { $0.classification == .unresolved })
        XCTAssertFalse(p.sources[0].splitRiskProven)
    }
    func testEmptyRawListCannotAuthorizePopulatedCatalog() throws {
        XCTAssertEqual(try plan([source(observations: [])]).channels[0].classification, .unresolved)
    }
    func testIncompleteSourceCannotProveOrphan() throws {
        XCTAssertEqual(try plan([source([], complete: false)], favorites: ["unfound"]).references[0].classification, .unresolved)
    }
    func testFavoriteDoesNotContaminateHiddenClassification() throws {
        let p = try plan(favorites: [favorite(channel())], hidden: [hidden(channel())])
        XCTAssertEqual(p.references[0].classification, .sourceProvenanceUnknown)
        XCTAssertEqual(p.references[1].classification, .safeLegacyMigrationCandidate)
    }
    func testDuplicateSourceIDsRejected() throws { XCTAssertThrowsError(try plan([source(), source()])) }
    func testWrongSourceRegistryRejected() throws {
        XCTAssertThrowsError(try plan([source(existing: [existing(channel(), source: b)])]))
    }
    func testSourceSummariesAndCounts() throws {
        let p = try plan([source(), source(id: b)], favorites: [favorite(channel())], hidden: [hidden(channel())])
        XCTAssertEqual(p.sources.map(\.favoriteReferences), [1, 1]); XCTAssertEqual(p.sources.map(\.hiddenReferences), [1, 0])
        XCTAssertEqual(p.channelCounts.values.reduce(0, +), 2)
    }
    func testNoStreamURLInReports() throws { try assertRedacted("https://example.invalid/live/user/pass?token=CANARY") }
    func testNoTokenInReports() throws { try assertRedacted("SECRET_TOKEN_DO_NOT_PERSIST") }
    func testNoAuthorizationInReports() throws { try assertRedacted("Authorization: Bearer CANARY") }
    func testNoCookieInReports() throws { try assertRedacted("Cookie: session=CANARY") }
    func testNoRawHeadersInReports() throws { try assertRedacted("{\"Referer\":\"https://secret.invalid\"}") }
    func testNoMarkdownInjectionInReports() throws { try assertRedacted("[click](https://secret.invalid)") }
    private func assertRedacted(_ secret: String) throws {
        let c = channel(secret, group: secret, tvg: secret)
        let p = try plan([source([c], name: secret, observations: [raw(c, line: secret, headers: secret)])], favorites: [secret])
        XCTAssertFalse(String(decoding: try p.json(), as: UTF8.self).contains(secret)); XCTAssertFalse(p.markdown().contains(secret))
    }
    func testSettingsUnknownShapeFailsClosed() throws {
        XCTAssertThrowsError(try ImportedMigrationDryRun.references(.object([:])))
        XCTAssertThrowsError(try ImportedMigrationDryRun.references(.array([.integer(1)])))
    }
    func testSettingsOpaqueValuesRemainExact() throws {
        XCTAssertEqual(try ImportedMigrationDryRun.references(.array([.string("a::b::c")])), [ImportedLegacyReference("a::b::c")])
    }
}
