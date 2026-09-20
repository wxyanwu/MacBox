import Foundation
import XCTest
@_spi(XMLTVStreaming) @testable import OKVideoCore

final class XMLTVStreamingTests: XCTestCase {
    final class Sink: XMLTVBatchSink {
        var records: [XMLTVStreamedProgramme] = [] // small correctness fixtures only
        var sizes: [Int] = []
        var discarded = 0
        var action: (() throws -> Void)?
        func consumeTentative(_ programmes: [XMLTVStreamedProgramme]) throws {
            try action?()
            sizes.append(programmes.count); records += programmes
        }
        func discardTentative() { discarded += 1; records = [] }
    }
    final class Chunks: InputStream {
        let data: Data, chunk: Int
        var offset = 0, opened = false, closed = false
        var failAt: Int?
        init(_ text: String, chunk: Int) { data = Data(text.utf8); self.chunk = chunk; super.init(data: Data()) }
        override func open() { opened = true }
        override func close() { closed = true }
        override var streamStatus: Stream.Status { closed ? .closed : (offset == data.count ? .atEnd : .open) }
        override var hasBytesAvailable: Bool { offset < data.count }
        override var streamError: Error? { nil }
        override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
            if let failAt, offset >= failAt { return -1 }
            let count = min(chunk, min(len, data.count-offset))
            data.copyBytes(to: buffer, from: offset..<offset+count); offset += count
            return count
        }
        override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                                length len: UnsafeMutablePointer<Int>) -> Bool { false }
    }
    func p(_ title: String = "节目é📺&amp;", channel: String = "a", start: String = "20260913235900 +0800", end: String = "20260914003000 +0800") -> String {
        "<programme channel='\(channel)' start='\(start)' stop='\(end)'><title>\(title)</title></programme>"
    }
    func parse(_ xml: String, chunk: Int = 7, budget: XMLTVBatchBudget = .init(), sink: Sink) throws -> XMLTVImportSummary {
        try XMLTVParser().parsePlainStream(Chunks(xml,chunk:chunk),budget:budget,sink:sink)
    }
    func testAllChunkBoundariesMatchLegacyWithUnicodeEntitiesAndAliases() throws {
        let xml = "<tv><channel id='a'><display-name>CCTV1</display-name><display-name>中央📺</display-name></channel>"+p()+p("next")+"</tv>"
        let old = try XMLTVParser().parse(Data(xml.utf8))
        for chunk in [1,2,3,7,31,64,4096] {
            let sink = Sink(), stream = Chunks(xml,chunk:chunk)
            let summary = try XMLTVParser().parsePlainStream(stream,budget:.init(count:1),sink:sink)
            XCTAssertEqual(sink.records.map(\.programme),old.programmes)
            XCTAssertEqual(summary.channels,old.channels)
            XCTAssertEqual(summary.inputBytes,xml.utf8.count)
            XCTAssertEqual(sink.records.map(\.ordinal),[0,1])
            XCTAssertTrue(stream.closed); XCTAssertEqual(sink.discarded,0)
        }
    }
    func testCountAndByteBudgetAreIndependent() throws {
        let xml = "<tv>"+String(repeating:p("T"),count:9)+"</tv>"
        let count = Sink()
        let a = try parse(xml,budget:.init(count:2),sink:count)
        XCTAssertEqual(count.sizes,[2,2,2,2,1]); XCTAssertEqual(a.peakBatchCount,2)
        let bytes = Sink()
        let b = try parse(xml,budget:.init(count:100,estimatedBytes:132),sink:bytes)
        XCTAssertEqual(bytes.sizes,[2,2,2,2,1]); XCTAssertEqual(b.peakBatchEstimatedBytes,132)
    }
    func testOversizedRecordRejectsOnlyStreamingSPI() throws {
        let xml = "<tv>"+p(String(repeating:"T",count:200))+"</tv>"
        XCTAssertEqual(try XMLTVParser().parse(Data(xml.utf8)).programmes.count,1)
        let sink = Sink()
        XCTAssertThrowsError(try parse(xml,budget:.init(estimatedBytes:100),sink:sink)) {
            guard case XMLTVStreamError.oversizedRecord = $0 else { return XCTFail("Wrong failure") }
        }
        XCTAssertEqual(sink.discarded,1)
    }
    func testEmptyValidVersusAllInvalid() throws {
        XCTAssertEqual(try parse("<tv/>",sink:Sink()).validProgrammeCount,0)
        XCTAssertThrowsError(try parse("<tv>"+p(start:"bad")+"</tv>",sink:Sink()))
        XCTAssertThrowsError(try parse("<notTV/>",sink:Sink()))
    }
    func testInvalidElementsCountAndOriginalOrderSurviveBatching() throws {
        let sink = Sink()
        let result = try parse("<tv>"+p(start:"bad")+p("first")+p("second")+"</tv>",budget:.init(count:1),sink:sink)
        XCTAssertEqual(result.programmeElementCount,3); XCTAssertEqual(result.validProgrammeCount,2)
        XCTAssertEqual(result.emittedProgrammeCount,2); XCTAssertEqual(sink.records.map(\.ordinal),[1,2])
        let guide = XMLTVGuide(channels:result.channels,programmes:sink.records.map(\.programme))
        let channel = LiveChannel(groupName:"G",name:"N",tvgID:"a",streams:[])
        let index = XMLTVScheduleIndex(guide:guide)
        XCTAssertEqual(index.currentAndNext(for:channel,at:result.minProgrammeStart!).current?.title,"second")
        XCTAssertNil(index.currentAndNext(for:channel,at:result.maxProgrammeEnd!).current)
    }
    func testGlobalCoverageAndProgrammeOnlyEvidence() throws {
        let sink = Sink()
        let xml = "<tv><channel id='a'><display-name>CCTV1</display-name></channel>"+p(channel:"CCTV1")+"</tv>"
        let result = try parse(xml,sink:sink)
        XCTAssertEqual(result.programmeChannelIDs,["CCTV1"])
        XCTAssertEqual(result.maxProgrammeEnd!.timeIntervalSince(result.minProgrammeStart!),1860)
        let guide = XMLTVGuide(channels:result.channels,programmes:sink.records.map(\.programme))
        XCTAssertEqual(XMLTVChannelMatcher(guide:guide).match(LiveChannel(groupName:"G",name:"CCTV-1",streams:[])).kind,.ambiguous)
    }
    func testMalformedTailDiscardsPreviouslyEmittedBatches() {
        let sink = Sink()
        XCTAssertThrowsError(try parse("<tv>"+String(repeating:p(),count:5)+"<broken>",budget:.init(count:1),sink:sink))
        XCTAssertFalse(sink.sizes.isEmpty); XCTAssertEqual(sink.discarded,1); XCTAssertTrue(sink.records.isEmpty)
    }
    func testTrailingContentMatchesLegacy() throws {
        for suffix in ["   ","<!--tail-->","<?tail yes?>","garbage","<tv/>"] {
            let xml = "<tv>"+p()+"</tv>"+suffix
            let legacy = Result { try XMLTVParser().parse(Data(xml.utf8)) }
            let streaming = Result { try parse(xml,chunk:1,sink:Sink()) }
            switch (legacy,streaming) {
            case (.success,.success),(.failure,.failure): break
            default: XCTFail("Acceptance changed for trailing content")
            }
        }
    }
    func testInputErrorIsNotSuccessfulEOF() {
        let stream = Chunks("<tv>"+String(repeating:p(),count:8)+"</tv>",chunk:7)
        stream.failAt=400
        let sink=Sink()
        XCTAssertThrowsError(try XMLTVParser().parsePlainStream(stream,budget:.init(count:1),sink:sink))
        XCTAssertEqual(sink.discarded,1); XCTAssertTrue(stream.closed)
    }
    func testSinkFailurePropagatesOriginalErrorAndDiscards() {
        enum Injected: Error { case stop }
        let sink=Sink(); sink.action={ throw Injected.stop }
        XCTAssertThrowsError(try parse("<tv>"+p()+"</tv>",sink:sink)) {
            guard case Injected.stop = $0 else { return XCTFail("Sink error hidden") }
        }
        XCTAssertEqual(sink.discarded,1)
    }
    func testInvalidBudgetClosesInputAndDiscards() {
        for budget in [XMLTVBatchBudget(count:0),.init(estimatedBytes:0),.init(count:Int.max),.init(estimatedBytes:Int.max)] {
            let sink=Sink(),stream=Chunks("<tv/>",chunk:1)
            XCTAssertThrowsError(try XMLTVParser().parsePlainStream(stream,budget:budget,sink:sink))
            XCTAssertTrue(stream.closed); XCTAssertEqual(sink.discarded,1)
        }
    }
    func testCancellationDuringSinkCannotReturnSuccess() async throws {
        let task = Task.detached { () throws -> Bool in
            let sink=Sink()
            sink.action = { withUnsafeCurrentTask { $0?.cancel() } }
            do {
                _ = try XMLTVParser().parsePlainStream(InputStream(data:Data(("<tv>"+self.p()+"</tv>").utf8)),sink:sink)
                XCTFail("Cancelled import succeeded")
            } catch is CancellationError { }
            return sink.discarded==1 && sink.records.isEmpty
        }
        let discarded = try await task.value
        XCTAssertTrue(discarded)
    }
    func testChannelAfterProgrammeAndMultipleTitlesMatchLegacy() throws {
        let xml="<tv>"+p("<b>N</b>")+"<channel id='a'><display-name>A</display-name><display-name>A</display-name><display-name>B</display-name></channel>"+p("one</title><title>two")+"</tv>"
        let sink=Sink(),old=try XMLTVParser().parse(Data(xml.utf8))
        let new=try parse(xml,sink:sink)
        XCTAssertEqual(new.channels,old.channels); XCTAssertEqual(sink.records.map(\.programme),old.programmes)
    }
    func testSlowSinkPausesProducerWithoutQueuedBatches() throws {
        let stream=Chunks("<tv>"+String(repeating:p(),count:100)+"</tv>",chunk:31)
        let sink=Sink()
        var calls=0
        sink.action = {
            let offset=stream.offset
            Thread.sleep(forTimeInterval:0.001)
            XCTAssertEqual(stream.offset,offset)
            calls += 1
        }
        let result=try XMLTVParser().parsePlainStream(stream,budget:.init(count:3),sink:sink)
        XCTAssertEqual(result.emittedProgrammeCount,100); XCTAssertEqual(calls,34)
        XCTAssertEqual(result.peakBatchCount,3)
    }
    func testRawProgrammeLimitCountsInvalidElements() {
        let xml="<tv>"+p()+String(repeating:"<programme/>",count:200_000)+"</tv>"
        let sink=Sink()
        XCTAssertThrowsError(try parse(xml,chunk:4096,budget:.init(count:1),sink:sink))
        XCTAssertEqual(sink.discarded,1)
        XCTAssertThrowsError(try XMLTVParser().parse(Data(xml.utf8)))
    }
    func testAliasLimitIsUnchanged() {
        let xml="<tv><channel id='a'>"+String(repeating:"<display-name>A</display-name>",count:200_001)+"</channel></tv>"
        let sink=Sink()
        XCTAssertThrowsError(try parse(xml,chunk:4096,sink:sink))
        XCTAssertEqual(sink.discarded,1)
    }
    func testPreCancelledImportNeverEmitsAndClosesStream() async throws {
        let result = try await Task.detached { () throws -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            let stream=Chunks("<tv/>",chunk:1),sink=Sink()
            do {
                _=try XMLTVParser().parsePlainStream(stream,sink:sink)
                return false
            } catch is CancellationError {
                return sink.records.isEmpty && sink.discarded==1 && stream.closed
            }
        }.value
        XCTAssertTrue(result)
    }
    func testExpandedByteLimitExactBoundaryWithoutAllocatingWholeInput() throws {
        final class Padding: InputStream {
            var offset=0
            let length: Int
            init(_ length: Int) { self.length=length;super.init(data:Data()) }
            override func open() {}
            override func close() {}
            override var streamError: Error? { nil }
            override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
                let count=min(len,length-offset)
                let prefix=Array("<tv/>".utf8)
                for i in 0..<count { buffer[i] = offset+i<5 ? prefix[offset+i] : 32 }
                offset += count
                return count
            }
        }
        let limit=64*1024*1024
        let valid=try XMLTVParser().parsePlainStream(Padding(limit),sink:Sink())
        XCTAssertEqual(valid.inputBytes,limit)
        let sink=Sink()
        XCTAssertThrowsError(try XMLTVParser().parsePlainStream(Padding(limit+1),sink:sink)) {
            guard case XMLTVStreamError.inputLimit = $0 else { return XCTFail("Byte limit not preserved") }
        }
        XCTAssertEqual(sink.discarded,1)
    }
}
