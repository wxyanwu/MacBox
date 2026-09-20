import Foundation
import XCTest
@_spi(XMLTVStreaming) @testable import OKVideoCore

final class XMLTVBoundedMetadataTests: XCTestCase {
    private final class Sink: XMLTVMetadataBatchSink {
        var facts: [EPGChannel] = []
        var programmes: [XMLTVStreamedProgramme] = []
        var discarded = false, cancelled = false
        var batchCount = 0
        func consumeTentative(_ values: [XMLTVStreamedProgramme]) throws {
            try checkCancellation(); programmes += values
        }
        func consumeTentativeChannels(_ values: [EPGChannel]) throws {
            try checkCancellation(); facts += values; batchCount += 1
        }
        func checkCancellation() throws { if cancelled { throw CancellationError() } }
        func discardTentative() { discarded = true }
    }
    func testMetadataFactsPreserveLegacyAliasAndProgrammeSemantics() throws {
        let xml = """
        <tv><programme channel="orphan" start="20260101000000 +0000" stop="20260101010000 +0000"><title>A</title></programme>
        <channel id="café"><display-name>CCTV 1</display-name><display-name>央视一台</display-name></channel>
        <channel id="café"><display-name>CCTV 1</display-name><display-name>新名称</display-name></channel>
        <channel id="other"><display-name>央视一台</display-name></channel></tv>
        """
        let data = Data(xml.utf8), sink = Sink()
        let old = try XMLTVParser().parse(data)
        let result = try XMLTVParser().parsePlainStream(InputStream(data: data),
            budget: XMLTVBatchBudget(count: 2), sink: sink)
        XCTAssertTrue(result.channels.isEmpty)
        XCTAssertTrue(result.programmeChannelIDs.isEmpty)
        XCTAssertEqual(result.emittedChannelRecordCount, 5)
        XCTAssertEqual(result.peakChannelBatchCount, 2)
        XCTAssertEqual(sink.batchCount, 3)
        XCTAssertEqual(sink.programmes.map(\.programme), old.programmes)
        var merged: [String: Set<String>] = [:]
        for fact in sink.facts { merged[fact.id, default: []].insert(fact.displayName) }
        for channel in old.channels {
            XCTAssertEqual(merged[channel.id], Set([channel.displayName] + (channel.aliases ?? [])))
        }
    }
    func testOversizedRelevantFieldFailsButIgnoredTextIsNotRetained() throws {
        let huge = String(repeating: "x", count: 1_048_577)
        let sink = Sink()
        XCTAssertThrowsError(try XMLTVParser().parsePlainStream(InputStream(data:
            Data("<tv><channel id='x'><display-name>\(huge)</display-name></channel></tv>".utf8)), sink: sink))
        XCTAssertTrue(sink.discarded)
        let ignored = try XMLTVParser().parsePlainStream(InputStream(data:
            Data("<tv><desc>\(huge)</desc></tv>".utf8)), sink: Sink())
        XCTAssertEqual(ignored.emittedProgrammeCount, 0)
    }
    func testEmptyValidDocumentAndInvalidProgrammeRemainDistinct() throws {
        XCTAssertEqual(try XMLTVParser().parsePlainStream(InputStream(data: Data("<tv/>".utf8)),
            sink: Sink()).programmeElementCount, 0)
        XCTAssertThrowsError(try XMLTVParser().parsePlainStream(InputStream(data:
            Data("<tv><programme channel='x'><title>bad</title></programme></tv>".utf8)), sink: Sink()))
    }
    func testExplicitCancellationWorksOutsideSwiftTask() {
        let sink = Sink(); sink.cancelled = true
        XCTAssertThrowsError(try XMLTVParser().parsePlainStream(InputStream(data: Data("<tv/>".utf8)), sink: sink)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertTrue(sink.discarded)
    }

    func testManyAliasesRemainBatchedAndSinkFailureStopsProducer() throws {
        final class CountingSink: XMLTVMetadataBatchSink {
            var count = 0, calls = 0, discarded = false
            var failAt: Int?
            func consumeTentative(_ values: [XMLTVStreamedProgramme]) throws {}
            func checkCancellation() throws {}
            func discardTentative() { discarded = true }
            func consumeTentativeChannels(_ values: [EPGChannel]) throws {
                calls += 1
                if calls == failAt { throw XMLTVStreamError.inputFailure }
                XCTAssertLessThanOrEqual(values.count, 64)
                Thread.sleep(forTimeInterval: 0.001) // synchronous backpressure
                count += values.count
            }
        }
        let xml = "<tv><channel id='one'>" + (0..<4096).map {
            "<display-name>Name\($0)</display-name>"
        }.joined() + "</channel></tv>"
        let sink = CountingSink()
        let summary = try XMLTVParser().parsePlainStream(InputStream(data: Data(xml.utf8)),
            budget: XMLTVBatchBudget(count: 64), sink: sink)
        XCTAssertEqual(sink.count, 4096); XCTAssertEqual(sink.calls, 64)
        XCTAssertTrue(summary.channels.isEmpty); XCTAssertEqual(summary.peakChannelBatchCount, 64)
        let failed = CountingSink(); failed.failAt = 3
        XCTAssertThrowsError(try XMLTVParser().parsePlainStream(InputStream(data: Data(xml.utf8)),
            budget: XMLTVBatchBudget(count: 64), sink: failed))
        XCTAssertEqual(failed.calls, 3); XCTAssertEqual(failed.count, 128); XCTAssertTrue(failed.discarded)
    }
}
