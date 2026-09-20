import XCTest
@testable import OKVideoCore

private final class StartupURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((StartupURLProtocol) -> Void)?
    static var stops = 0
    static func configure(_ handler: @escaping (StartupURLProtocol) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; stops = 0
    }
    static var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        handler?(self)
    }
    override func stopLoading() { Self.lock.lock(); Self.stops += 1; Self.lock.unlock() }
    func response(_ status: Int = 200, length: Int? = nil) {
        var headers = ["Content-Type": "application/octet-stream"]
        if let length { headers["Content-Length"] = String(length) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
    }
    func send(_ data: Data) { client?.urlProtocol(self, didLoad: data) }
    func end() { client?.urlProtocolDidFinishLoading(self) }
}

final class LiveHLSStartupPreparerTests: XCTestCase {
    private let url = URL(string: "https://fixture.invalid/live/test/test/202.ts")!
    private let master = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=320x180
    low.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080
    high.m3u8?sig=one%2Ftwo
    """
    private func preparer(deadline: TimeInterval = 1, maximumBytes: Int = 256 * 1024) -> LiveHLSStartupPreparer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StartupURLProtocol.self]
        return .init(configuration: configuration, deadline: deadline, maximumBytes: maximumBytes)
    }
    private func assertStopped() async throws {
        for _ in 0..<200 where StartupURLProtocol.stopCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThan(StartupURLProtocol.stopCount, 0)
    }
    func testTSNamedHLSResponseUsesOneGETWithoutRangeAndSelectsAtEOF() async throws {
        let body = Data(master.utf8)
        StartupURLProtocol.configure {
            XCTAssertEqual($0.request.httpMethod, "GET")
            XCTAssertNil($0.request.value(forHTTPHeaderField: "Range"))
            XCTAssertEqual($0.request.value(forHTTPHeaderField: "User-Agent"), "fixture-agent")
            $0.response(); $0.send(body); $0.end()
        }
        let result = try await preparer().prepare(url: url, headers: ["User-Agent": "fixture-agent"])
        XCTAssertEqual(result?.variantCount, 2)
        XCTAssertEqual(result?.routingURL.absoluteString, "https://fixture.invalid/live/test/test/high.m3u8?sig=one%2Ftwo")
    }
    func testBinaryContinuousTSReturnsWithoutWaitingForEOF() async throws {
        StartupURLProtocol.configure { $0.response(); $0.send(Data([0x47, 0x40, 0, 0x10])) }
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await preparer().prepare(url: url, headers: [:])
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.8)
        try await assertStopped()
    }
    func testChunkedUTF8BOMAndSignatureAreAccepted() async throws {
        let body = Data(master.utf8)
        StartupURLProtocol.configure {
            $0.response()
            for byte in [UInt8(0xef), 0xbb, 0xbf] { $0.send(Data([byte])) }
            for byte in body { $0.send(Data([byte])) }
            $0.end()
        }
        let result = try await preparer().prepare(url: url, headers: [:])
        XCTAssertEqual(result?.variantCount, 2)
    }
    func testTricklingPartialMasterHitsTotalDeadlineAndIsNotSelected() async throws {
        let body = Data(master.utf8)
        StartupURLProtocol.configure { $0.response(); $0.send(body) /* deliberately no EOF */ }
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await preparer(deadline: 0.04).prepare(url: url, headers: [:])
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        try await assertStopped()
    }
    func testOversizedChunkIsCancelledAndNeverUsedAsTruncatedMaster() async throws {
        let body = Data((master + String(repeating: " ", count: 4096)).utf8)
        StartupURLProtocol.configure { $0.response(); $0.send(body) }
        let result = try await preparer(maximumBytes: 1024).prepare(url: url, headers: [:])
        XCTAssertNil(result); try await assertStopped()
    }
    func testHTTPFailureDoesNotBecomeSuccessfulPreparation() async throws {
        let body = Data(master.utf8)
        StartupURLProtocol.configure { $0.response(403); $0.send(body); $0.end() }
        let result = try await preparer().prepare(url: url, headers: [:])
        XCTAssertNil(result)
    }
    func testMediaPlaylistLeavesOriginalPlaybackPath() async throws {
        StartupURLProtocol.configure {
            $0.response(); $0.send(Data("#EXTM3U\n#EXTINF:4,\nsegment.ts\n".utf8)); $0.end()
        }
        let result = try await preparer().prepare(url: url, headers: [:])
        XCTAssertNil(result)
    }
    func testCancellationClosesTransportAndThrowsCancellation() async throws {
        let started = expectation(description: "request started")
        StartupURLProtocol.configure { _ in started.fulfill() }
        let task = Task { try await self.preparer().prepare(url: self.url, headers: [:]) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await assertStopped()
    }
}
