import Foundation
import XCTest
import CZlib
@_spi(XMLTVStreaming) @testable import OKVideoCore

final class XMLTVGzipStreamingTests: XCTestCase {
    typealias Sink = XMLTVStreamingTests.Sink
    final class Input: InputStream {
        let data: Data, chunk: Int
        var offset = 0, closed = false, failAt: Int?
        var beforeRead: (() -> Void)?
        init(_ data: Data, chunk: Int = 65_536) {
            self.data = data; self.chunk = chunk; super.init(data: Data())
        }
        override func open() { }
        override func close() { closed = true }
        override var streamError: Error? { nil }
        override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
            beforeRead?()
            if let failAt, offset >= failAt { return -1 }
            let count = min(len, min(chunk, data.count - offset))
            data.copyBytes(to: buffer, from: offset..<offset+count); offset += count
            return count
        }
    }
    var xml: String {
        "<tv><channel id='a'><display-name>频道📺</display-name><display-name>A</display-name></channel>" +
        "<programme channel='a' start='20260913235900 +0800' stop='20260914003000 +0800'><title>晚间é&amp;节目</title></programme></tv>"
    }
    // Fixture compression only: bounded chunks, no network/files/cleanup. The
    // z_stream address remains stable throughout its native lifetime.
    func gzipChunks(_ chunks: [Data], repetitions: Int = 1) throws -> Data {
        let z = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        z.initialize(to: z_stream())
        defer { z.deinitialize(count: 1); z.deallocate() }
        guard deflateInit2_(z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16+MAX_WBITS,
                  8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw XMLTVGzipError.initialization
        }
        defer { deflateEnd(z) }
        var result = Data(), out = [UInt8](repeating: 0, count: 65_536)
        func step(_ flush: Int32) throws -> Int32 {
            var produced = 0
            let status = out.withUnsafeMutableBufferPointer { p -> Int32 in
                z.pointee.next_out = p.baseAddress; z.pointee.avail_out = uInt(p.count)
                defer { z.pointee.next_out = nil }
                let status = deflate(z, flush)
                produced = p.count - Int(z.pointee.avail_out)
                return status
            }
            guard status == Z_OK || status == Z_STREAM_END else { throw XMLTVGzipError.invalidStream }
            result.append(contentsOf: out.prefix(produced))
            return status
        }
        for _ in 0..<repetitions {
            for data in chunks {
                try data.withUnsafeBytes { bytes in
                    z.pointee.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
                    z.pointee.avail_in = uInt(bytes.count)
                    defer { z.pointee.next_in = nil }
                    while z.pointee.avail_in > 0 { _ = try step(Z_NO_FLUSH) }
                }
            }
        }
        while try step(Z_FINISH) != Z_STREAM_END { }
        return result
    }
    func gz(_ text: String) throws -> Data { try gzipChunks([Data(text.utf8)]) }
    func parse(_ data: Data, chunk: Int = 65_536, sink: Sink = Sink()) throws -> XMLTVGzipImportSummary {
        try XMLTVParser().parseGzipStream(Input(data, chunk: chunk), budget: .init(count: 1), sink: sink)
    }
    func rejects(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        let input = Input(data, chunk: 7), sink = Sink()
        XCTAssertThrowsError(try XMLTVParser().parseGzipStream(input, sink: sink), file: file, line: line)
        XCTAssertEqual(sink.discarded, 1, file: file, line: line)
        XCTAssertTrue(sink.records.isEmpty, file: file, line: line)
        XCTAssertTrue(input.closed, file: file, line: line)
    }
    func testSingleMemberMatchesLegacyAcrossFragmentSizes() throws {
        let data = try gz(xml), old = try XMLTVParser().parse(data)
        for chunk in [1,2,3,7,31,64,4096,65_536] {
            let sink = Sink(), r = try parse(data, chunk: chunk, sink: sink)
            XCTAssertEqual(sink.records.map(\.programme), old.programmes)
            XCTAssertEqual(r.xml.channels, old.channels)
            XCTAssertEqual(r.xml.inputBytes, xml.utf8.count)
            XCTAssertEqual(r.compressedInputBytes, data.count); XCTAssertEqual(r.memberCount, 1)
        }
    }
    func testValidXMLSplitAcrossMembersIncludingUTF8ByteBoundary() throws {
        let bytes = Data(xml.utf8), old = try XMLTVParser().parse(bytes)
        let unicodeSplit = bytes.firstIndex(where: { $0 & 0xc0 == 0x80 })!
        for split in [1, 5, unicodeSplit, bytes.count/2, bytes.count-1] {
            let data = try gzipChunks([bytes.prefix(split)]) + gzipChunks([bytes.suffix(bytes.count-split)])
            for chunk in [1,7,65_536] {
                let sink = Sink(), r = try parse(data, chunk: chunk, sink: sink)
                XCTAssertEqual(r.memberCount, 2); XCTAssertEqual(r.xml.inputBytes, bytes.count)
                XCTAssertEqual(sink.records.map(\.programme), old.programmes)
            }
        }
    }
    func testEmptyMembersDoNotProducePrematureEOF() throws {
        let empty = try gz("")
        let data = empty + empty + (try gz(xml)) + empty
        let r = try parse(data, chunk: 1)
        XCTAssertEqual(r.memberCount, 4); XCTAssertEqual(r.xml.validProgrammeCount, 1)
        rejects(empty); rejects(Data())
    }
    func testNonGzipSuffixIncludingPaddingRejectedOnlyByNewSPI() throws {
        let first = try gz(xml)
        for suffix in [Data("garbage".utf8), Data([0]), Data(repeating: 0, count: 100)] {
            XCTAssertEqual(try XMLTVParser().parse(first+suffix).programmes.count, 1)
            rejects(first+suffix)
        }
    }
    func testSecondNonXMLMemberCannotBeSilentlyIgnored() throws {
        let data = try gz(xml) + gz("not XML")
        XCTAssertEqual(try XMLTVParser().parse(data).programmes.count, 1)
        rejects(data)
    }
    func testTwoCompleteXMLDocumentsRejected() throws { rejects(try gz(xml)+gz(xml)) }
    func testTruncatedSecondHeaderAndTrailerRejected() throws {
        let first = try gz(xml), second = try gz("")
        for suffix in [Data([0x1f]), Data([0x1f,0x8b,8,0]), Data(second.dropLast())] {
            rejects(first+suffix)
        }
    }
    func testFirstMemberCRCISIZEAndTruncationFailures() throws {
        let data = try gz(xml)
        for offset in [8,4] {
            var corrupt = data; corrupt[corrupt.count-offset] ^= 1; rejects(corrupt)
        }
        for cut in [1,4,8,data.count/2] { rejects(Data(data.dropLast(cut))) }
    }
    func testLaterMemberCRCFailureDiscardsEarlierBatches() throws {
        let p = "<programme channel='a' start='20260914000000 +0000' stop='20260914010000 +0000'><title>T</title></programme>"
        let first = try gz("<tv>" + String(repeating: p, count: 1000))
        var tail = try gz("</tv>"); tail[tail.count-8] ^= 1
        let sink = Sink()
        XCTAssertThrowsError(try parse(first+tail, chunk: 7, sink: sink))
        XCTAssertFalse(sink.sizes.isEmpty); XCTAssertEqual(sink.discarded, 1)
        XCTAssertTrue(sink.records.isEmpty)
    }
    func testUnderlyingReadFailureIsNotEOF() throws {
        let data = try gz(xml), input = Input(data, chunk: 1), sink = Sink()
        input.failAt = data.count-3
        XCTAssertThrowsError(try XMLTVParser().parseGzipStream(input, sink: sink))
        XCTAssertEqual(sink.discarded, 1); XCTAssertTrue(input.closed)
    }
    func testCompressedLimitIsActualAndGlobalAcrossMembers() throws {
        let data = try gz("<tv>")+gz("</tv>")
        for limit in [data.count-1, data.count] {
            let gzip = XMLTVGzipInputStream(Input(data, chunk: 1), compressedLimit: limit)
            let sink = Sink()
            if limit == data.count {
                XCTAssertEqual(try XMLTVParser().parsePlainStream(gzip, sink: sink).validProgrammeCount, 0)
                XCTAssertEqual(gzip.members, 2)
            } else {
                XCTAssertThrowsError(try XMLTVParser().parsePlainStream(gzip, sink: sink)) {
                    guard case XMLTVGzipError.compressedInputLimit = $0 else { return XCTFail("Wrong limit") }
                }
                XCTAssertEqual(sink.discarded, 1)
            }
        }
    }
    func testExpandedLimitIsGlobalNotPerMember() throws {
        // 64 MiB whitespace without creating a 64 MiB fixture in memory.
        let padding = try gzipChunks([Data(repeating: 32, count: 65_536)], repetitions: 1023)
        let lastSize = 65_536-9 // <tv></tv> consumes nine bytes
        let tail = try gz(String(repeating: " ", count: lastSize)+"</tv>")
        let exact = try gz("<tv>") + padding + tail
        XCTAssertEqual(try parse(exact).xml.inputBytes, 64*1_024*1_024)
        let sink = Sink()
        XCTAssertThrowsError(try parse(exact + gz(" "), sink: sink)) {
            guard case XMLTVStreamError.inputLimit = $0 else { return XCTFail("Wrong expanded limit") }
        }
        XCTAssertEqual(sink.discarded, 1)
    }
    func testMalformedXMLCannotCommitValidatedGzip() throws { rejects(try gz("<tv><broken>")) }
    func testPlainOrZlibWrappedBytesAreNotGzip() { rejects(Data(xml.utf8)); rejects(Data([0x78,0x9c,0,0])) }
    func testSinkErrorDiscardsAndCloses() throws {
        enum Injected: Error { case stop }
        let sink = Sink(), input = Input(try gz(xml))
        sink.action = { throw Injected.stop }
        XCTAssertThrowsError(try XMLTVParser().parseGzipStream(input, sink: sink)) {
            guard case Injected.stop = $0 else { return XCTFail("Lost sink error") }
        }
        XCTAssertEqual(sink.discarded, 1); XCTAssertTrue(input.closed)
    }
    func testCancellationDuringCompressedReadPropagates() async throws {
        let data = try gz(xml)
        let result = await Task.detached { () -> Bool in
            let input = Input(data, chunk: 1), sink = Sink()
            input.beforeRead = { withUnsafeCurrentTask { $0?.cancel() } }
            do { _ = try XMLTVParser().parseGzipStream(input, sink: sink); return false }
            catch is CancellationError { return input.closed && sink.discarded == 1 }
            catch { return false }
        }.value
        XCTAssertTrue(result)
    }
    func testCancellationAfterTentativeBatchCannotCommit() async throws {
        let data = try gz(xml)
        let result = await Task.detached { () -> Bool in
            let sink = Sink(), input = Input(data)
            sink.action = { withUnsafeCurrentTask { $0?.cancel() } }
            do { _ = try XMLTVParser().parseGzipStream(input, sink: sink); return false }
            catch is CancellationError { return input.closed && sink.discarded == 1 }
            catch { return false }
        }.value
        XCTAssertTrue(result)
    }
    func testInvalidBudgetClosesBeforeInflate() throws {
        let input = Input(try gz(xml)), sink = Sink()
        XCTAssertThrowsError(try XMLTVParser().parseGzipStream(input, budget: .init(count: 0), sink: sink))
        XCTAssertTrue(input.closed); XCTAssertEqual(input.offset, 0); XCTAssertEqual(sink.discarded, 1)
    }
}
