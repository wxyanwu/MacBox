import Foundation
import XCTest
@_spi(MigrationDiagnostics) import OKVideoCore
@testable import OKVideoMigrationDiagnostics
@testable import OKVideoPersistence

final class ParserObservationTests: XCTestCase {
    // Captured with the unmodified 8B.2 production parser BEFORE observation work.
    private let golden = [
        "epg": "06f8917cc398934c60abf211395bc7d1c0f94dae72ec25ab35bcf0919205f5b5",
        "headers": "198d85e4e977079f8a5b0cece10b388bc2495dfb8950b3978887058bf55c9296",
        "invalid": "076cb02f0a0664fcb487d6ab44dbdcc903cbbb1f6406e0153a6ee11cc77fa8e4",
        "json": "78827454a97b9fa38884ed7881419dd26adbfe7dc58a079773184e5dd993151e",
        "merge": "69371a136abf0094f21caf91c597179810f11878012abc57c0c04f86a08e6c3b",
        "order": "7df0034d0ad70538fb153fb9ca0fc5457531d1bbe6c41de71fc788731d6e1330",
        "protected": "b0b065977e38587fa3221b2ae874ecbaa5690cd3199db61b6ad34b1c9cdf3534",
        "single": "d3bcb9bb8773fcb3015c84379b3e8e038bfefd33af7c94ac81857372f50dabd2",
        "txt": "1299862d0662379bb02fad5a3f7b95c6e87144338c60dd4fd782ff6bbefc54e5"
    ]
    private func unchanged(_ key: String) throws {
        let output = try LiveSourceParser().parse(ParserOutputEquivalence.fixtures[key]!, baseURL: URL(string: "https://fixture.invalid/base/"))
        XCTAssertEqual(try ParserOutputEquivalence.digest(output), golden[key])
        let observed = try ImportedPreMergeEvidence.parse(Data(ParserOutputEquivalence.fixtures[key]!.utf8), baseURL: URL(string: "https://fixture.invalid/base/"))
        XCTAssertEqual(observed.playlist, output)
        XCTAssertEqual(try ParserOutputEquivalence.digest(observed.playlist), golden[key])
    }
    func testSingleOutputGolden() throws { try unchanged("single") }
    func testMultiLineMergeAndFirstMetadataGolden() throws { try unchanged("merge") }
    func testHeadersRestoreVariantWithoutChangingLegacyProjection() throws { try restoredVariant("headers", oldRoutes: 1) }
    func testEPGPrecedenceGolden() throws { try unchanged("epg") }
    func testChannelAndGroupOrderingGolden() throws { try unchanged("order") }
    func testProtectedGroupMergeGolden() throws { try unchanged("protected") }
    func testTXTRestoresVariantWithoutChangingLegacyProjection() throws { try restoredVariant("txt", oldRoutes: 2) }
    func testJSONNoMergeGolden() throws { try unchanged("json") }
    func testRejectedStreamGolden() throws { try unchanged("invalid") }

    /// Keep the PRE-8C.2 golden, rather than blessing a replacement digest.
    /// Removing the one explained restored header variant must reproduce the
    /// entire old ordered result, including channel identity and metadata.
    private func restoredVariant(_ key: String, oldRoutes: Int) throws {
        let text = ParserOutputEquivalence.fixtures[key]!, base = URL(string: "https://fixture.invalid/base/")!
        var output = try LiveSourceParser().parse(text, baseURL: base)
        let observed = try ImportedPreMergeEvidence.parse(Data(text.utf8), baseURL: base)
        XCTAssertEqual(observed.playlist, output)
        let routes = output.groups[0].channels[0].streams
        XCTAssertEqual(routes.count, oldRoutes + 1)
        let restored = try XCTUnwrap(routes.last)
        XCTAssertEqual(restored.url, routes[0].url)
        XCTAssertNotEqual(restored.headers, routes[0].headers)
        XCTAssertEqual(restored.format, routes[0].format)
        XCTAssertEqual(restored.needsParsing, routes[0].needsParsing)
        output.groups[0].channels[0].streams.removeLast()
        XCTAssertEqual(try ParserOutputEquivalence.digest(output), golden[key])
    }

    private func entry(id: String? = "one", tvgName: String? = nil, name: String = "Name", group: String = "G",
                       url: String = "https://fixture.invalid/one", extra: String = "", attributes: String = "") -> String {
        "#EXTINF:-1 group-title=\"\(group)\" \(id.map { "tvg-id=\"\($0)\"" } ?? "") \(tvgName.map { "tvg-name=\"\($0)\"" } ?? "") \(attributes),\(name)\n\(extra)\(url)\n"
    }
    private func parsed(_ entries: [String]) throws -> ImportedPreMergeEvidence.Parsed {
        try ImportedPreMergeEvidence.parse(Data(("#EXTM3U\n" + entries.joined()).utf8))
    }
    private func channels(_ p: ImportedPreMergeEvidence.Parsed) -> [MigrationChannel] {
        p.playlist.groups.flatMap(\.channels).map { MigrationChannel(legacyChannelID: $0.id,
            evidence: ImportedChannelEvidence(group: $0.groupName, name: $0.name, tvgID: $0.tvgID)) }
    }
    private func report(_ p: ImportedPreMergeEvidence.Parsed) -> PreMergeEvidenceReport {
        ImportedPreMergeEvidence.analyze(p.observations, channels: channels(p)).report
    }
    private func plan(_ p: ImportedPreMergeEvidence.Parsed, hidden: Bool = false) throws -> ImportedChannelMigrationPlan {
        let sourceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let c = channels(p)
        let source = MigrationSourceSnapshot(id: sourceID, name: "Fixture", format: p.playlist.format.rawValue,
            channels: c, rawObservations: p.observations)
        let refs = hidden ? [ImportedLegacyReference(ImportedChannelMigrationPlanner.hiddenKey(sourceID: sourceID, channelID: c[0].legacyChannelID))] : []
        return try ImportedChannelMigrationPlanner.plan(sources: [source], favorites: [], hidden: refs)
    }
    func testSingleRawRecordMetadataAndOrdinal() throws {
        var raw: [LiveParserObservation] = []
        _ = try LiveSourceParser().parseObserving(Data(("#EXTM3U\n" + entry(tvgName: "Alias")).utf8)) { raw.append($0) }
        XCTAssertEqual(raw.count, 1); XCTAssertEqual(raw[0].ordinal, 1); XCTAssertEqual(raw[0].group, "G")
        XCTAssertEqual(raw[0].name, "Name"); XCTAssertEqual(raw[0].tvgID, "one"); XCTAssertEqual(raw[0].tvgName, "Alias")
        XCTAssertNil(raw[0].upstreamID)
    }
    func testTwoSameGroupNameRecordsPreserved() throws {
        let p = try parsed([entry(), entry(url: "https://fixture.invalid/two")])
        XCTAssertEqual(p.observations.count, 2); XCTAssertEqual(channels(p).count, 1)
        XCTAssertEqual(report(p).multiRecordMergedChannels, 1)
    }
    func testSameTVGIDIsObservationNotIdentityProof() throws {
        let p = try parsed([entry(), entry(url: "https://fixture.invalid/two")])
        XCTAssertTrue(report(p).groups[0].sameTVGID); XCTAssertTrue(report(p).groups[0].sameIdentityEvidence)
        XCTAssertEqual(try plan(p).channels[0].classification, .futureSplitRisk)
    }
    func testDifferentTVGIDMergeBlocked() throws {
        let p = try parsed([entry(), entry(id: "two")])
        XCTAssertTrue(report(p).groups[0].conflictingTVGIDs)
        XCTAssertEqual(try plan(p).channels[0].classification, .futureSplitRisk)
    }
    func testIDPresentMissingMixBlocked() throws {
        let p = try parsed([entry(), entry(id: nil)])
        XCTAssertTrue(report(p).groups[0].idPresentMissing)
        XCTAssertEqual(try plan(p).channels[0].classification, .futureSplitRisk)
    }
    func testBothMissingIDsRemainInsufficient() throws {
        let p = try parsed([entry(id: nil), entry(id: nil)])
        XCTAssertTrue(report(p).groups[0].reasons.contains("insufficientIdentityEvidence"))
        XCTAssertFalse(report(p).groups[0].sameTVGID)
    }
    func testTVGNameDivergenceNotFirstRecordGuess() throws {
        let p = try parsed([entry(tvgName: "A"), entry(tvgName: "B")])
        XCTAssertTrue(report(p).groups[0].tvgNameDivergence)
        XCTAssertEqual(p.playlist.groups[0].channels[0].tvgName, "A")
    }
    func testLogoAndNumberDivergence() throws {
        let p = try parsed([entry(attributes: "tvg-logo=\"a.png\" tvg-chno=\"1\""), entry(attributes: "tvg-logo=\"b.png\" tvg-chno=\"2\"")])
        XCTAssertTrue(report(p).groups[0].metadataDivergence)
    }
    func testDuplicateURLRetainedOnlyInObservations() throws {
        let p = try parsed([entry(), entry()])
        XCTAssertEqual(p.observations.flatMap(\.lines).count, 2)
        XCTAssertEqual(p.playlist.groups[0].channels[0].streams.count, 1)
        XCTAssertEqual(p.observations[0].lines[0].locatorToken, p.observations[1].lines[0].locatorToken)
    }
    func testSameURLDifferentHeadersBeforeDiscard() throws {
        let p = try parsed([entry(extra: "ua=A\n"), entry(extra: "ua=B\n")])
        XCTAssertTrue(report(p).groups[0].sameLocatorDifferentHeaders)
        XCTAssertEqual(p.playlist.groups[0].channels[0].streams[0].headers["User-Agent"], "A")
    }
    func testHeadersConflictAcrossUnmergedChannels() throws {
        let p = try parsed([entry(name: "A", extra: "ua=A\n"), entry(name: "B", extra: "ua=B\n")])
        XCTAssertEqual(channels(p).count, 2)
        XCTAssertEqual(report(p).counts["sameURLDifferentHeaderGroups"], 2)
        XCTAssertTrue(try plan(p).channels.allSatisfy { $0.classification == .futureSplitRisk })
    }
    func testCalculatedIDDelimiterCollision() throws {
        let p = try parsed([entry(name: "C", group: "A::B"), entry(name: "B::C", group: "A")])
        XCTAssertEqual(report(p).counts["duplicateRuntimeChannelIDGroups"], 1)
        XCTAssertEqual(report(p).counts["duplicateCalculatedIDGroups"], 1)
        XCTAssertEqual(try plan(p, hidden: true).references[0].classification, .ambiguous)
    }
    func testPlaylistReorderDoesNotChangeRisk() throws {
        let a = entry(id: "one", tvgName: "A", extra: "ua=A\n")
        let b = entry(id: "two", tvgName: "B", extra: "ua=B\n")
        XCTAssertEqual(report(try parsed([a, b])), report(try parsed([b, a])))
    }
    func testTXTLineReorderRiskUnchanged() throws {
        let a = "G,#genre#\nName,https://fixture.invalid/a#https://fixture.invalid/b\n"
        let b = "G,#genre#\nName,https://fixture.invalid/b#https://fixture.invalid/a\n"
        let p = try ImportedPreMergeEvidence.parse(Data(a.utf8)), q = try ImportedPreMergeEvidence.parse(Data(b.utf8))
        XCTAssertEqual(report(p), report(q)); XCTAssertEqual(p.observations.count, 1); XCTAssertEqual(p.observations[0].lines.count, 2)
        XCTAssertEqual(try plan(p).channels[0].classification, .allocateNew)
    }
    func testHeaderDictionaryOrderEquality() throws {
        let p = try parsed([entry(extra: "#EXTHTTP:{\"A\":\"1\",\"B\":\"2\"}\n"), entry(extra: "#EXTHTTP:{\"B\":\"2\",\"A\":\"1\"}\n")])
        XCTAssertFalse(report(p).groups[0].sameLocatorDifferentHeaders)
        XCTAssertEqual(p.observations[0].lines[0].headersToken, p.observations[1].lines[0].headersToken)
    }
    func testDescriptionsNeverPrintSecrets() throws {
        var raw: [LiveParserObservation] = []
        let input = Data(("#EXTM3U\n" + entry(extra: "#EXTHTTP:{\"Authorization\":\"SECRET_TOKEN_DO_NOT_PERSIST\"}\n")).utf8)
        _ = try LiveSourceParser().parseObserving(input) { raw.append($0) }
        for value in [String(describing: raw[0]), String(reflecting: raw[0]), String(describing: try ImportedPreMergeEvidence.parse(input).observations[0])] {
            XCTAssertFalse(value.contains("SECRET_TOKEN_DO_NOT_PERSIST")); XCTAssertFalse(value.contains("https://"))
        }
    }
    func testHeaderTokensArePerRunAndNotPublished() throws {
        let e = entry(extra: "#EXTHTTP:{\"Authorization\":\"SECRET_TOKEN_DO_NOT_PERSIST\",\"Cookie\":\"CANARY\"}\n")
        let p = try parsed([e]), q = try parsed([e])
        XCTAssertNotEqual(p.observations[0].lines[0].headersToken, q.observations[0].lines[0].headersToken)
        let report = String(decoding: try plan(p).json(), as: UTF8.self)
        XCTAssertFalse(report.contains(p.observations[0].lines[0].headersToken))
        XCTAssertFalse(report.contains("SECRET_TOKEN_DO_NOT_PERSIST")); XCTAssertFalse(report.contains("CANARY"))
        XCTAssertFalse(report.contains("Authorization")); XCTAssertFalse(report.contains("Cookie")); XCTAssertFalse(report.contains("https://"))
        XCTAssertEqual(try plan(p).json(), try plan(q).json())
    }
    func testParsedDiagnosticDescriptionOmitsPlaylist() throws {
        let p = try parsed([entry(url: "https://fixture.invalid/SECRET_TOKEN_DO_NOT_PERSIST")])
        XCTAssertFalse(String(reflecting: p).contains("SECRET_TOKEN_DO_NOT_PERSIST"))
        XCTAssertFalse(String(describing: p).contains("https://"))
    }
    func testSingleCompleteObservationEligible() throws {
        XCTAssertEqual(try plan(parsed([entry()])).channels[0].classification, .allocateNew)
    }
    func testSplitRiskBlocksHiddenMigration() throws {
        XCTAssertEqual(try plan(parsed([entry(), entry(id: "other")]), hidden: true).references[0].classification, .futureSplitRisk)
    }
    func testSingleHiddenCanBeSafeCandidate() throws {
        XCTAssertEqual(try plan(parsed([entry()]), hidden: true).references[0].classification, .safeLegacyMigrationCandidate)
    }
    func testJSONOneRawEntryMultipleLines() throws {
        let p = try ImportedPreMergeEvidence.parse(Data(ParserOutputEquivalence.fixtures["json"]!.utf8))
        XCTAssertEqual(p.observations.count, 2); XCTAssertEqual(p.observations[0].lines.count, 2)
        XCTAssertEqual(channels(p).count, 2); XCTAssertEqual(report(p).counts["duplicateRuntimeChannelIDGroups"], 1)
    }
    func testNoCCTVOrHDNormalizationInMergeEvidence() throws {
        let p = try parsed([entry(name: "CCTV-1"), entry(name: "CCTV1"), entry(name: "CCTV1 HD")])
        XCTAssertEqual(report(p).singleRecordChannels, 3); XCTAssertEqual(report(p).counts["multiRecordGroups"], 0)
    }
    func testLineFormatDivergence() throws {
        let p = try parsed([entry(extra: "format=m3u8\n"), entry(extra: "format=ts\n")])
        XCTAssertTrue(report(p).groups[0].reasons.contains("lineFormatDivergence"))
    }
    func testDuplicateUpstreamEvidenceOnlyWhenSupported() throws {
        let upstream = ImportedUpstreamEvidence(namespace: "fixture", value: "one", formatSupportsStableID: true)
        let records = ["A", "B"].map { ImportedRawObservation(evidence: ImportedChannelEvidence(group: "G", name: $0, upstream: upstream), locatorToken: $0, headersToken: "same") }
        XCTAssertEqual(ImportedPreMergeEvidence.analyze(records, channels: []).report.counts["duplicateUpstreamIDs"], 1)
    }
}
