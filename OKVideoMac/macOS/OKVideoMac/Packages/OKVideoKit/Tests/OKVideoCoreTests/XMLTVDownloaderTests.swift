import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(XMLTVStreaming) @testable import OKVideoCore

private final class XMLTVDownloaderURLProtocol: URLProtocol {
    typealias Handler = (XMLTVDownloaderURLProtocol) -> Void
    private static let lock = NSLock()
    private static var storedHandler: Handler?
    private static var storedStopCount = 0

    static func configure(_ handler: @escaping Handler) {
        lock.lock()
        storedHandler = handler
        storedStopCount = 0
        lock.unlock()
    }

    static var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let value = Self.storedHandler
        Self.lock.unlock()
        value?(self)
    }
    override func stopLoading() {
        Self.lock.lock()
        Self.storedStopCount += 1
        Self.lock.unlock()
    }

    func respond(
        status: Int = 200,
        headers: [String: String],
        body: Data,
        finish: Bool = true
    ) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}

final class XMLTVDownloaderTests: XCTestCase {
    typealias Sink = XMLTVStreamingTests.Sink

    private final class DigestSink: XMLTVBatchSink {
        private var digest = SHA256()
        private(set) var count = 0
        private(set) var peakBatchCount = 0
        private var previousOrdinal = -1
        func consumeTentative(_ programmes: [XMLTVStreamedProgramme]) throws {
            peakBatchCount = max(peakBatchCount, programmes.count)
            for item in programmes {
                guard item.ordinal > previousOrdinal else { throw XMLTVStreamError.inputFailure }
                previousOrdinal = item.ordinal
                let value = item.programme
                digest.update(data: Data([80, 0]))
                for field in [
                    value.channelID,
                    value.title,
                    String(Int64(value.start.timeIntervalSince1970)),
                    String(Int64(value.end.timeIntervalSince1970))
                ] {
                    let bytes = Data(field.utf8)
                    var length = UInt64(bytes.count).bigEndian
                    withUnsafeBytes(of: &length) { digest.update(bufferPointer: $0) }
                    digest.update(data: bytes)
                }
                digest.update(data: Data([10]))
                count += 1
            }
        }
        func discardTentative() { count = 0 }
        func hexadecimalDigest() -> String {
            digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct ResourcePoint: Codable {
        let rss: UInt64
        let footprint: UInt64
    }

    private final class ResourceSampler: @unchecked Sendable {
        let baseline = XMLTVDownloaderTests.resourcePoint()
        private let lock = NSLock()
        private let timer: DispatchSourceTimer
        private var peak: ResourcePoint
        init() {
            peak = baseline
            timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "com.okvideomac.xmltv.9b3-rss")
            )
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
        }
        private func sample() {
            let point = XMLTVDownloaderTests.resourcePoint()
            lock.lock()
            peak = ResourcePoint(
                rss: max(peak.rss, point.rss),
                footprint: max(peak.footprint, point.footprint)
            )
            lock.unlock()
        }
        func stop() -> ResourcePoint {
            timer.cancel()
            sample()
            lock.lock()
            defer { lock.unlock() }
            return peak
        }
        deinit { timer.cancel() }
    }

    private static func resourcePoint() -> ResourcePoint {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS)
        return ResourcePoint(rss: info.resident_size, footprint: info.phys_footprint)
    }

    private let xml = """
    <tv><channel id="a"><display-name>A</display-name></channel><programme channel="a" start="20260913235900 +0800" stop="20260914003000 +0800"><title>T</title></programme></tv>
    """

    private func response(
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.invalid/epg.xml")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func downloader(
        root: String,
        maximumBytes: Int = XMLTVDownloader.maximumSupportedBytes
    ) -> XMLTVDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XMLTVDownloaderURLProtocol.self]
        return XMLTVDownloader(
            stagingRootPath: root,
            maximumBytes: maximumBytes,
            configuration: configuration
        )
    }

    func testAdmissionAcceptsIdentityAndKnownLength() throws {
        let result = try XMLTVDownloadAdmission.validate(
            response(headers: [
                "Content-Length": "123",
                "Content-Encoding": " identity ",
                "Content-Type": "application/xml"
            ]),
            maximumBytes: 1_024
        )
        XCTAssertEqual(result.expectedBytes, 123)
        XCTAssertEqual(result.contentType, "application/xml")
    }

    func testAdmissionRejectsUnsafeOrAmbiguousResponses() {
        let cases: [(HTTPURLResponse, XMLTVDownloadError)] = [
            (response(status: 404), .statusCode(404)),
            (response(headers: ["Content-Range": "bytes 0-9/20"]), .partialContent),
            (response(headers: ["Content-Encoding": "gzip"]), .unsupportedContentEncoding),
            (response(headers: ["Content-Encoding": ""]), .unsupportedContentEncoding),
            (response(headers: ["Content-Length": "12, 12"]), .invalidResponse),
            (response(headers: ["Content-Length": "2048"]), .declaredSizeLimit(limit: 1_024, declared: 2_048))
        ]
        for (value, expected) in cases {
            XCTAssertThrowsError(try XMLTVDownloadAdmission.validate(value, maximumBytes: 1_024)) {
                XCTAssertEqual($0 as? XMLTVDownloadError, expected)
            }
        }
    }

    func testNetworkFilePlainParserChainUsesIdentityAndBoundedBatches() async throws {
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("fixture cleanup failed: \(error)") } }
        let body = Data(xml.utf8)
        let requestSeen = expectation(description: "request")
        XMLTVDownloaderURLProtocol.configure { protocolValue in
            XCTAssertEqual(protocolValue.request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            XCTAssertNil(protocolValue.request.value(forHTTPHeaderField: "Range"))
            requestSeen.fulfill()
            protocolValue.respond(
                headers: [
                    "Content-Length": String(body.count),
                    "Content-Type": "application/xml"
                ],
                body: body
            )
        }

        let downloaded = try await downloader(root: fixture.path).download(XMLTVDownloadRequest(
            url: URL(string: "https://example.invalid/epg.xml")!
        ))
        await fulfillment(of: [requestSeen], timeout: 1)
        let sink = Sink()
        let summary = try XMLTVParser().parseDownloadedFile(
            downloaded,
            budget: XMLTVBatchBudget(count: 1, estimatedBytes: 1_024),
            sink: sink
        )
        XCTAssertFalse(summary.wasGzip)
        XCTAssertEqual(summary.download.downloadedBytes, body.count)
        XCTAssertEqual(summary.xml.validProgrammeCount, 1)
        XCTAssertEqual(summary.xml.peakBatchCount, 1)
        XCTAssertEqual(sink.records.map(\.programme.title), ["T"])
        XCTAssertThrowsError(try XMLTVParser().parseDownloadedFile(downloaded, sink: Sink())) {
            XCTAssertEqual($0 as? XMLTVDownloadError, .temporaryFile)
        }
    }

    func testFinalDownloaderCopyFailureAndCopyCancellationReleaseOwnership() async throws {
        for cancel in [false, true] {
            let fixture = try XMLTVStagingFileTests.Fixture()
            defer { try? fixture.clean() }
            let body = Data(xml.utf8)
            XMLTVDownloaderURLProtocol.configure { value in
                value.respond(headers: ["Content-Length": String(body.count)], body: body)
            }
            let transport = downloader(root: fixture.path)
            let entered = expectation(description: "copy entered")
            let gate = DispatchSemaphore(value: 0)
            transport.stagingWriteForTesting = { _, _, _ in
                entered.fulfill()
                if cancel { _ = gate.wait(timeout: .now() + 5) }
                throw POSIXError(.ENOSPC)
            }
            let task = Task { try await transport.download(XMLTVDownloadRequest(url: URL(string: "https://example.invalid/fixture")!)) }
            await fulfillment(of: [entered], timeout: 3)
            if cancel { task.cancel(); gate.signal() }
            do { _ = try await task.value; XCTFail("copy failed but transferred file") }
            catch {
                if !cancel { XCTAssertEqual(error as? XMLTVDownloadError, .staging(.system(ENOSPC))) }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.path).filter { $0.hasPrefix("xmltv-") }, [])
        }
    }

    func testNetworkFileGzipParserChainUsesMagicAndReleasesFile() async throws {
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("fixture cleanup failed: \(error)") } }
        let body = Data(base64Encoded: "H4sIAAAAAAAC/1WO0QrCMAxFf6X0VaSxVXGQBfYP+4HgihbarnRh4N+74Sj4dpJzQy7KSvh8c84+qjD1mjXhFJYS+XPOnDwNaP5mNEecsNT5VTklr47Vfq4W4Sq9tmDv0F2cdbcOQJ3gAbDLuTR3BXDQHKEEiZ5GND9A0x5svBX9AmbDdhWtAAAA")!
        XMLTVDownloaderURLProtocol.configure { protocolValue in
            protocolValue.respond(
                headers: [
                    "Content-Length": String(body.count),
                    "Content-Type": "application/octet-stream"
                ],
                body: body
            )
        }
        let downloaded = try await downloader(root: fixture.path).download(XMLTVDownloadRequest(
            url: URL(string: "https://example.invalid/no-extension")!
        ))
        let sink = Sink()
        let summary = try XMLTVParser().parseDownloadedFile(downloaded, sink: sink)
        XCTAssertTrue(summary.wasGzip)
        XCTAssertEqual(summary.gzipMemberCount, 1)
        XCTAssertEqual(summary.compressedInputBytes, body.count)
        XCTAssertEqual(summary.xml.validProgrammeCount, 1)
        XCTAssertEqual(sink.records.map(\.programme.title), ["T"])
    }

    func testDeclaredOversizeRejectsBeforeOwnershipTransfer() async throws {
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("fixture cleanup failed: \(error)") } }
        XMLTVDownloaderURLProtocol.configure { protocolValue in
            protocolValue.respond(
                headers: ["Content-Length": "2048"],
                body: Data(repeating: 1, count: 8)
            )
        }
        do {
            _ = try await downloader(root: fixture.path, maximumBytes: 1_024).download(
                XMLTVDownloadRequest(url: URL(string: "https://example.invalid/large")!)
            )
            XCTFail("oversize response succeeded")
        } catch {
            XCTAssertEqual(
                error as? XMLTVDownloadError,
                .declaredSizeLimit(limit: 1_024, declared: 2_048)
            )
        }
    }

    func testCancellationDoesNotPublishPartialFile() async throws {
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("fixture cleanup failed: \(error)") } }
        let began = expectation(description: "began")
        XMLTVDownloaderURLProtocol.configure { protocolValue in
            began.fulfill()
            protocolValue.respond(
                headers: ["Content-Length": "1024"],
                body: Data(repeating: 1, count: 64),
                finish: false
            )
        }
        let task = Task {
            try await downloader(root: fixture.path).download(XMLTVDownloadRequest(
                url: URL(string: "https://example.invalid/cancel")!
            ))
        }
        await fulfillment(of: [began], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled response succeeded")
        } catch {
            XCTAssertEqual(error as? XMLTVDownloadError, .cancelled)
        }
        for _ in 0..<100 where XMLTVDownloaderURLProtocol.stopCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThan(XMLTVDownloaderURLProtocol.stopCount, 0)
    }

    func testUnknownLengthOversizeCannotPublishFile() async throws {
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("fixture cleanup failed: \(error)") } }
        XMLTVDownloaderURLProtocol.configure { protocolValue in
            protocolValue.respond(
                headers: ["Content-Type": "application/xml"],
                body: Data(repeating: 1, count: 1_025)
            )
        }
        do {
            _ = try await downloader(root: fixture.path, maximumBytes: 1_024).download(
                XMLTVDownloadRequest(url: URL(string: "https://example.invalid/unknown-large")!)
            )
            XCTFail("unknown-length oversize response succeeded")
        } catch {
            guard case .observedSizeLimit(let limit, let observed) = error as? XMLTVDownloadError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(limit, 1_024)
            XCTAssertGreaterThan(observed, limit)
        }
    }

    func testExplicitReleaseConsumesDownloadedOwnership() async throws {
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("fixture cleanup failed: \(error)") } }
        let body = Data(xml.utf8)
        XMLTVDownloaderURLProtocol.configure { protocolValue in
            protocolValue.respond(
                headers: ["Content-Length": String(body.count)],
                body: body
            )
        }
        let downloaded = try await downloader(root: fixture.path).download(XMLTVDownloadRequest(
            url: URL(string: "https://example.invalid/release")!
        ))
        try downloaded.release()
        try downloaded.release()
        XCTAssertThrowsError(try XMLTVParser().parseDownloadedFile(downloaded, sink: Sink())) {
            XCTAssertEqual($0 as? XMLTVDownloadError, .temporaryFile)
        }
    }

    /// Explicit 9B.3 Release-XCTest harness only. The companion Python runner
    /// supplies a deterministic loopback gzip and a >32 MiB plain control.
    func testRealLoopbackNetworkFileParserChain() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["OKVIDEO_XMLTV_9B3_URL"],
              let url = URL(string: rawURL),
              let mode = environment["OKVIDEO_XMLTV_9B3_MODE"] else {
            throw XCTSkip("Explicit 9B.3 loopback harness only")
        }
        guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
              ["gzip", "plain-reject"].contains(mode) else {
            throw XMLTVDownloadError.invalidRequest
        }
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("fixture cleanup failed: \(error)") } }
        let downloader = XMLTVDownloader(stagingRootPath: fixture.path)

        if mode == "plain-reject" {
            let declared = Int64(environment["OKVIDEO_XMLTV_9B3_DECLARED"] ?? "")!
            XCTAssertGreaterThan(declared, Int64(XMLTVDownloader.maximumSupportedBytes))
            do {
                _ = try await downloader.download(XMLTVDownloadRequest(url: url))
                XCTFail("plain control exceeded 32 MiB but succeeded")
            } catch {
                guard case .declaredSizeLimit(let limit, let actual) = error as? XMLTVDownloadError else {
                    return XCTFail("wrong rejection: \(error)")
                }
                XCTAssertEqual(limit, Int64(XMLTVDownloader.maximumSupportedBytes))
                XCTAssertEqual(actual, declared)
            }
            print("XMLTV_9B3_CHAIN {\"mode\":\"plain-reject\",\"result\":\"PASS\"}")
            return
        }

        let expectedCount = Int(environment["OKVIDEO_XMLTV_9B3_COUNT"] ?? "")!
        let expectedCompressed = Int(environment["OKVIDEO_XMLTV_9B3_COMPRESSED"] ?? "")!
        let expectedExpanded = Int(environment["OKVIDEO_XMLTV_9B3_EXPANDED"] ?? "")!
        let expectedDigest = environment["OKVIDEO_XMLTV_9B3_PROGRAMME_SHA"]!
        let sampler = ResourceSampler()
        let downloaded = try await downloader.download(XMLTVDownloadRequest(
            url: url,
            timeout: 30,
            resourceTimeout: 180
        ))
        let sink = DigestSink()
        let summary = try await Task.detached(priority: .utility) {
            try XMLTVParser().parseDownloadedFile(downloaded, sink: sink)
        }.value
        let peak = sampler.stop()
        XCTAssertTrue(summary.wasGzip)
        XCTAssertEqual(summary.download.downloadedBytes, expectedCompressed)
        XCTAssertEqual(summary.compressedInputBytes, expectedCompressed)
        XCTAssertEqual(summary.xml.inputBytes, expectedExpanded)
        XCTAssertEqual(summary.xml.programmeElementCount, expectedCount)
        XCTAssertEqual(summary.xml.validProgrammeCount, expectedCount)
        XCTAssertEqual(summary.xml.emittedProgrammeCount, expectedCount)
        XCTAssertEqual(sink.count, expectedCount)
        XCTAssertEqual(sink.hexadecimalDigest(), expectedDigest)
        XCTAssertLessThanOrEqual(sink.peakBatchCount, 512)

        struct Report: Codable {
            let mode: String
            let count: Int
            let downloadedBytes: Int
            let expandedBytes: Int
            let peakBatchCount: Int
            let peakBatchEstimatedBytes: Int
            let baseline: ResourcePoint
            let peak: ResourcePoint
        }
        let report = Report(
            mode: mode,
            count: sink.count,
            downloadedBytes: summary.download.downloadedBytes,
            expandedBytes: summary.xml.inputBytes,
            peakBatchCount: summary.xml.peakBatchCount,
            peakBatchEstimatedBytes: summary.xml.peakBatchEstimatedBytes,
            baseline: sampler.baseline,
            peak: peak
        )
        print("XMLTV_9B3_CHAIN " + String(
            decoding: try JSONEncoder().encode(report),
            as: UTF8.self
        ))
    }
}
