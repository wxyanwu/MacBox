import Foundation
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMigrationDiagnostics

enum AdmissionFixture {
    static let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    static let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    static let local = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static func source(_ raw: String? = nil, id: UUID = a, name: String = "Fixture") -> StoredLiveSource {
        StoredLiveSource(id: id, name: name, sourceKind: .pasted,
            rawData: Data((raw ?? "#EXTM3U\n#EXTINF:-1 group-title=\"G\",One\nhttps://fixture.invalid/one\n").utf8),
            updatedAt: Date(timeIntervalSince1970: 0))
    }
    static var hidden: String { ImportedChannelMigrationPlanner.hiddenKey(sourceID: a, channelID: "G::One") }
    static var favorite: String { ImportedChannelMigrationPlanner.favoriteKey(sourceName: "Fixture", channelID: "G::One") }
    static func input() -> ImportedAdmissionInput { ImportedAdmissionInput(sources: [source()], schemaVersion: 10) }
    static func record(source: UUID = a, name: String = "One", tvgID: String? = nil,
                       lifecycle: ImportedChannelRegistryLifecycle = .active, evidenceVersion: Int = 1) throws -> ImportedChannelRegistryRecord {
        ImportedChannelRegistryRecord(identity: try ImportedLiveChannelIdentity(source: .imported(source), localID: local),
            evidence: ImportedChannelEvidence(group: "G", name: name, tvgID: tvgID), provenance: .verified, lifecycle: lifecycle,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), evidenceVersion: evidenceVersion)
    }
    static func claim(kind: MigrationReferenceKind = .hidden) throws -> ImportedReferenceClaim {
        try ImportedReferenceClaim(sourceID: a, kind: kind, legacyToken: hidden, identity: record().identity)
    }
}

final class ImportedAdmissionTests: XCTestCase {
    private func changed(_ mutate: (inout ImportedAdmissionInput) throws -> Void) throws {
        let session = ImportedAdmissionSession(); var input = AdmissionFixture.input()
        let plan = try session.prepare(input); try mutate(&input)
        XCTAssertThrowsError(try session.validate(plan, current: input))
    }
    func testEmptyRegistryCreatesOnlyEligibleIntent() throws {
        let p = try ImportedAdmissionSession().prepare(AdmissionFixture.input())
        XCTAssertEqual(p.counts["eligible"], 1); XCTAssertNil(p.rows[0].channel.existingIdentity)
        XCTAssertTrue(p.rows[0].channel.allocationRequired); XCTAssertFalse(p.executableReport)
        XCTAssertNil(UUID(uuidString: p.rows[0].channel.token))
    }
    func testRepeatedParsingRandomObservationTokensDoNotInvalidate() throws {
        let s = ImportedAdmissionSession(); let input = AdmissionFixture.input()
        let first = try s.prepare(input); let second = try s.prepare(input)
        XCTAssertEqual(first.planFingerprint, second.planFingerprint); XCTAssertEqual(first.rows, second.rows)
        XCTAssertNoThrow(try s.validate(first, current: input))
    }
    func testAnotherSessionCannotReplayPlan() throws {
        let input = AdmissionFixture.input(); let p = try ImportedAdmissionSession().prepare(input)
        XCTAssertThrowsError(try ImportedAdmissionSession().validate(p, current: input))
    }
    func testSourceUUIDInvalidates() throws { try changed { $0.sources[0].id = AdmissionFixture.b } }
    func testSourceNameInvalidates() throws { try changed { $0.sources[0].name = "Changed" } }
    func testFullCatalogStreamLocatorInvalidates() throws { try changed { $0.sources[0].rawData.append(Data("# extra input\n".utf8)) } }
    func testBaseURLInvalidates() throws { try changed { $0.sources[0].baseURL = URL(string: "https://fixture.invalid/base") } }
    func testSourceLocatorInvalidates() throws { try changed { $0.sources[0].sourceValue = "changed" } }
    func testFavoriteFingerprintInvalidates() throws { try changed { $0.favorites = [ImportedLegacyReference(AdmissionFixture.favorite)] } }
    func testHiddenFingerprintInvalidates() throws { try changed { $0.hidden = [ImportedLegacyReference(AdmissionFixture.hidden)] } }
    func testSchemaFingerprintInvalidates() throws { try changed { $0.schemaVersion = 9 } }
    func testPlannerVersionInvalidates() throws { try changed { $0.plannerVersion = 2 } }
    func testPolicyVersionInvalidates() throws { try changed { $0.policyVersion = 2 } }
    func testEvidenceVersionInvalidates() throws { try changed { $0.evidenceVersion = 2 } }
    func testRegistryFingerprintInvalidates() throws { try changed { $0.registry = [try AdmissionFixture.record()] } }
    func testRegistryMetadataLifecycleAndVersionsInvalidateExistingPlan() throws {
        var input = AdmissionFixture.input(); input.registry = [try AdmissionFixture.record()]
        let session = ImportedAdmissionSession(); let plan = try session.prepare(input)
        for record in [try AdmissionFixture.record(name: "Changed"), try AdmissionFixture.record(lifecycle: .missing),
                       try AdmissionFixture.record(evidenceVersion: 2)] {
            input.registry = [record]; XCTAssertThrowsError(try session.validate(plan, current: input))
        }
        let r = try AdmissionFixture.record()
        input.registry = [ImportedChannelRegistryRecord(identity: r.identity, evidence: r.evidence, provenance: .verified,
            lifecycle: .active, createdAt: r.createdAt, updatedAt: Date(timeIntervalSince1970: 1))]
        XCTAssertThrowsError(try session.validate(plan, current: input))
    }
    func testClaimFingerprintInvalidates() throws { try changed { $0.claims = [try AdmissionFixture.claim()] } }
    func testStableStateFingerprintInvalidates() throws { try changed { $0.stable = [try ImportedStableReferenceState(identity: AdmissionFixture.record().identity, kind: .hidden)] } }
    func testMarkerFingerprintInvalidates() throws { try changed { $0.markers = ["completed"] } }
    func testUnsupportedPolicyCannotPrepare() throws {
        var input = AdmissionFixture.input(); input.policyVersion = 2
        XCTAssertThrowsError(try ImportedAdmissionSession().prepare(input))
    }
    func testSourceReferenceRegistryRowOrderCanonical() throws {
        var input = AdmissionFixture.input(); input.sources += [AdmissionFixture.source(id: AdmissionFixture.b)]
        input.registry = [try AdmissionFixture.record(), try AdmissionFixture.record(source: AdmissionFixture.b)]
        input.hidden = [ImportedLegacyReference("z"), ImportedLegacyReference("a")]
        input.favorites = input.hidden
        let session = ImportedAdmissionSession(); let p = try session.prepare(input)
        input.sources.reverse(); input.registry.reverse(); input.hidden.reverse(); input.favorites.reverse()
        XCTAssertNoThrow(try session.validate(p, current: input))
        XCTAssertEqual(p.rows, try session.prepare(input).rows)
    }
    func testRawLineReorderInvalidatesButAdmissionStable() throws {
        let a = "#EXTINF:-1 group-title=\"G\",One\nhttps://fixture.invalid/one\n"
        let b = "#EXTINF:-1 group-title=\"G\",Two\nhttps://fixture.invalid/two\n"
        var input = AdmissionFixture.input(); input.sources = [AdmissionFixture.source("#EXTM3U\n" + a + b)]
        let session = ImportedAdmissionSession(); let p = try session.prepare(input)
        input.sources = [AdmissionFixture.source("#EXTM3U\n" + b + a)]
        XCTAssertThrowsError(try session.validate(p, current: input))
        XCTAssertEqual(p.rows, try session.prepare(input).rows)
    }
    func testSwallowedHeaderChangeInvalidates() throws {
        var input = AdmissionFixture.input()
        input.sources = [AdmissionFixture.source(ParserOutputEquivalence.fixtures["headers"]!)]
        let session = ImportedAdmissionSession(); let p = try session.prepare(input)
        input.sources[0].rawData = Data(ParserOutputEquivalence.fixtures["headers"]!.replacingOccurrences(of: "Bearer%20CANARY", with: "Bearer%20CHANGED").utf8)
        XCTAssertThrowsError(try session.validate(p, current: input))
    }
    func testArbitraryNamedMultiRecordIsDeferred() throws {
        var input = AdmissionFixture.input()
        input.sources = [AdmissionFixture.source("#EXTM3U\n#EXTINF:-1 group-title=\"G\",NotAChineseChannel\nhttps://fixture.invalid/a\n#EXTINF:-1 group-title=\"G\",NotAChineseChannel\nhttps://fixture.invalid/b\n")]
        let row = try ImportedAdmissionSession().prepare(input).rows[0]
        XCTAssertEqual(row.admission, .deferred); XCTAssertTrue(row.reasons.contains("multipleRawRecords"))
    }
    func testPreviouslyRiskyNameSingleRecordNotBlacklisted() throws {
        var input = AdmissionFixture.input()
        input.sources[0].rawData = Data(String(decoding: input.sources[0].rawData, as: UTF8.self).replacingOccurrences(of: "One", with: "安徽卫视").utf8)
        XCTAssertEqual(try ImportedAdmissionSession().prepare(input).rows[0].admission, .eligible)
    }
    func testFullCatalogIsReconciledBeforeDeferringRiskyCandidate() throws {
        var input = AdmissionFixture.input()
        input.registry = [try AdmissionFixture.record(tvgID: "same")]
        input.sources = [AdmissionFixture.source("#EXTM3U\n#EXTINF:-1 tvg-id=\"same\" group-title=\"G\",One\nhttps://fixture.invalid/a\n#EXTINF:-1 tvg-id=\"same\" group-title=\"G\",Two\nhttps://fixture.invalid/b\n#EXTINF:-1 tvg-id=\"same\" group-title=\"G\",Two\nhttps://fixture.invalid/c\n")]
        let p = try ImportedAdmissionSession().prepare(input)
        XCTAssertNotEqual(p.rows.first { $0.channel.name == "One" }?.admission, .eligible)
        XCTAssertFalse(p.rows.contains { $0.channel.classification == .safeMatched })
    }
    func testUniqueHiddenEligibleAndOpaquePreserved() throws {
        var input = AdmissionFixture.input(); input.hidden = [ImportedLegacyReference(AdmissionFixture.hidden)]
        let p = try ImportedAdmissionSession().prepare(input)
        XCTAssertEqual(p.rows[0].admission, .eligible)
        XCTAssertEqual(p.fullPlan.references[0].classification, .safeLegacyMigrationCandidate)
        XCTAssertEqual(input.hidden[0].rawValue, AdmissionFixture.hidden)
    }
    func testUnknownFavoriteBlocksEvenWhenHiddenIsSafe() throws {
        var input = AdmissionFixture.input(); input.hidden = [ImportedLegacyReference(AdmissionFixture.hidden)]
        input.favorites = [ImportedLegacyReference(AdmissionFixture.favorite)]
        let p = try ImportedAdmissionSession().prepare(input)
        XCTAssertEqual(p.rows[0].admission, .blocked)
        XCTAssertEqual(p.fullPlan.referenceCounts(kind: "favorite")["sourceProvenanceUnknown"], 1)
    }
    func testTwoSameNamedSourcesDoNotBroadcastFavorite() throws {
        var input = AdmissionFixture.input(); input.sources += [AdmissionFixture.source(id: AdmissionFixture.b)]
        input.favorites = [ImportedLegacyReference(AdmissionFixture.favorite)]
        let p = try ImportedAdmissionSession().prepare(input)
        XCTAssertTrue(p.rows.allSatisfy { $0.admission == .blocked })
        XCTAssertEqual(p.fullPlan.references.count, 1)
    }
    func testOrphanPreservedNotSilentlyRemoved() throws {
        var input = AdmissionFixture.input(); input.hidden = [ImportedLegacyReference("orphan::opaque")]
        let p = try ImportedAdmissionSession().prepare(input)
        XCTAssertEqual(p.fullPlan.references[0].classification, .orphanedLegacyReference)
        XCTAssertTrue(p.fullPlan.references[0].action.hasPrefix("preserve"))
    }
    func testUnsupportedRegistryEvidenceBlocks() throws {
        var input = AdmissionFixture.input(); input.registry = [try AdmissionFixture.record(evidenceVersion: 2)]
        XCTAssertEqual(try ImportedAdmissionSession().prepare(input).rows[0].admission, .blocked)
    }
    func testForeignRegistrySourceBlocks() throws {
        var input = AdmissionFixture.input(); input.registry = [try AdmissionFixture.record(source: AdmissionFixture.b)]
        XCTAssertEqual(try ImportedAdmissionSession().prepare(input).blockers, ["registrySourceNotInSnapshot"])
    }
    func testExistingClaimFailsClosedForReMigration() throws {
        var input = AdmissionFixture.input(); input.claims = [try AdmissionFixture.claim()]
        XCTAssertEqual(try ImportedAdmissionSession().prepare(input).rows[0].admission, .blocked)
    }
    func testUnclaimedReadsLegacy() throws {
        XCTAssertEqual(try ImportedClaimedAuthority.resolve(sourceID: AdmissionFixture.a, kind: .hidden,
            legacyToken: AdmissionFixture.hidden, legacyContains: true, claims: [], stable: []), .legacy(true))
    }
    func testClaimedHiddenReadsStable() throws {
        let claim = try AdmissionFixture.claim()
        XCTAssertEqual(try ImportedClaimedAuthority.resolve(sourceID: AdmissionFixture.a, kind: .hidden,
            legacyToken: AdmissionFixture.hidden, legacyContains: false, claims: [claim],
            stable: [ImportedStableReferenceState(identity: claim.identity, kind: .hidden)]), .stable(true))
    }
    func testUnhideNeverResurrectsLegacy() throws {
        XCTAssertEqual(try ImportedClaimedAuthority.resolve(sourceID: AdmissionFixture.a, kind: .hidden,
            legacyToken: AdmissionFixture.hidden, legacyContains: true, claims: [AdmissionFixture.claim()], stable: []), .stable(false))
    }
    func testFavoriteClaimDoesNotClaimHidden() throws {
        XCTAssertEqual(try ImportedClaimedAuthority.resolve(sourceID: AdmissionFixture.a, kind: .hidden,
            legacyToken: AdmissionFixture.hidden, legacyContains: true, claims: [AdmissionFixture.claim(kind: .favorite)], stable: []), .legacy(true))
    }
    func testDifferentSourceDoesNotInheritClaim() throws {
        XCTAssertEqual(try ImportedClaimedAuthority.resolve(sourceID: AdmissionFixture.b, kind: .hidden,
            legacyToken: AdmissionFixture.hidden, legacyContains: false, claims: [AdmissionFixture.claim()], stable: []), .legacy(false))
    }
    func testWrongSourceClaimRejected() throws {
        XCTAssertThrowsError(try ImportedReferenceClaim(sourceID: AdmissionFixture.b, kind: .hidden,
            legacyToken: "opaque", identity: AdmissionFixture.record().identity))
    }
    func testConflictingClaimsRejected() throws {
        let claim = try AdmissionFixture.claim()
        let other = try ImportedReferenceClaim(sourceID: AdmissionFixture.a, kind: .hidden, legacyToken: AdmissionFixture.hidden,
            identity: ImportedLiveChannelIdentity(source: .imported(AdmissionFixture.a), localID: AdmissionFixture.b))
        XCTAssertThrowsError(try ImportedClaimedAuthority.resolve(sourceID: AdmissionFixture.a, kind: .hidden,
            legacyToken: AdmissionFixture.hidden, legacyContains: true, claims: [claim, other], stable: []))
    }
    func testReportAndDescriptionsContainNoPayloadSecrets() throws {
        var input = AdmissionFixture.input()
        input.sources = [AdmissionFixture.source(ParserOutputEquivalence.fixtures["headers"]!)]
        let p = try ImportedAdmissionSession().prepare(input)
        let text = String(decoding: try p.json(), as: UTF8.self) + p.markdown() + String(reflecting: input)
        for secret in ["SECRET_TOKEN_DO_NOT_PERSIST", "Bearer", "CANARY", "fixture.invalid", "Cookie", "Authorization"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        let c = try ImportedReferenceClaim(sourceID: AdmissionFixture.a, kind: .hidden,
            legacyToken: "SECRET_TOKEN_DO_NOT_PERSIST", identity: AdmissionFixture.record().identity)
        XCTAssertFalse(String(reflecting: c).contains("SECRET_TOKEN_DO_NOT_PERSIST"))
    }
}
