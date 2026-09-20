import XCTest
@testable import OKVideoCore

private final class ProbeURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((ProbeURLProtocol) -> Void)?
    static var stops = 0
    static func configure(_ handler: @escaping (ProbeURLProtocol) -> Void) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; stops = 0
    }
    static var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        handler?(self)
    }
    override func stopLoading() { Self.lock.lock(); Self.stops += 1; Self.lock.unlock() }
    func response(_ status: Int) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream", "X-Content-Type-Options": "nosniff"])!, cacheStoragePolicy: .notAllowed)
    }
}

final class BoundedLiveStreamProberTests: XCTestCase {
    private func prober(deadline: TimeInterval = 1) -> BoundedLiveStreamProber {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProbeURLProtocol.self]
        return .init(configuration: config, byteLimit: 1024, deadline: deadline)
    }
    private func stream(needsParsing: Bool = false) -> LiveStream {
        .init(name: "test", url: URL(string: "https://fixture.invalid/live")!,
              headers: ["X-Test": "explicit"], needsParsing: needsParsing)
    }
    private func assertStopped() async throws {
        for _ in 0..<200 where ProbeURLProtocol.stopCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThan(ProbeURLProtocol.stopCount, 0)
    }
    func testContinuousResponseFinishesAtSampleWithoutEOFAndCancelsTransport() async throws {
        ProbeURLProtocol.configure {
            XCTAssertEqual($0.request.value(forHTTPHeaderField: "Range"), "bytes=0-1023")
            XCTAssertEqual($0.request.value(forHTTPHeaderField: "X-Test"), "explicit")
            $0.response(206)
            $0.client?.urlProtocol($0, didLoad: Data(repeating: 1, count: 1024))
            // Intentionally never didFinishLoading: a continuous live response.
        }
        let result = await prober().probe(stream())
        XCTAssertEqual(result, .reachable); try await assertStopped()
    }
    func testServerIgnoringRangeIsStillCancelledWithoutBufferingWholeResponse() async throws {
        ProbeURLProtocol.configure {
            $0.response(200); $0.client?.urlProtocol($0, didLoad: Data(repeating: 1, count: 512 * 1024))
        }
        let result = await prober().probe(stream())
        XCTAssertEqual(result, .reachable); try await assertStopped()
    }
    func testDefinitiveHTTPErrorDoesNotWaitForBodyOrEOF() async throws {
        ProbeURLProtocol.configure {
            $0.response(403)
            // Foundation's URLProtocol bridge may buffer headers until initial
            // data. Do not finish the response or supply the complete body.
            $0.client?.urlProtocol($0, didLoad: Data(repeating: 1, count: 1024))
        }
        let result = await prober().probe(stream())
        XCTAssertEqual(result, .definitivelyUnavailable); try await assertStopped()
    }
    func testTransientHTTPErrorIsInconclusiveEvenIfItHasBytes() async {
        ProbeURLProtocol.configure {
            $0.response(503); $0.client?.urlProtocol($0, didLoad: Data(repeating: 1, count: 1024))
        }
        let result = await prober().probe(stream())
        XCTAssertEqual(result, .inconclusive)
    }
    func testNoResponseDeadlineCancelsUnderlyingRequest() async throws {
        ProbeURLProtocol.configure { _ in }
        let result = await prober(deadline: 0.03).probe(stream())
        XCTAssertEqual(result, .inconclusive); try await assertStopped()
    }
    func testPartialContinuousResponseDeadlineRemainsInconclusive() async throws {
        ProbeURLProtocol.configure {
            $0.response(200); $0.client?.urlProtocol($0, didLoad: Data(repeating: 1, count: 3))
        }
        let result = await prober(deadline: 0.04).probe(stream())
        XCTAssertEqual(result, .inconclusive); try await assertStopped()
    }
    func testTaskCancellationPropagatesToUnderlyingRequest() async throws {
        let started = expectation(description: "request started")
        ProbeURLProtocol.configure { _ in started.fulfill() }
        let task = Task { await self.prober().probe(self.stream()) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .inconclusive); try await assertStopped()
    }
    func testSmallFiniteSuccessfulResponseMayEndNormally() async {
        ProbeURLProtocol.configure {
            $0.response(200); $0.client?.urlProtocol($0, didLoad: Data([1]))
            $0.client?.urlProtocolDidFinishLoading($0)
        }
        let result = await prober().probe(stream())
        XCTAssertEqual(result, .reachable)
    }
    func testNonHTTPResponseCannotBeMadeReachableByBytes() async {
        ProbeURLProtocol.configure {
            $0.client?.urlProtocol($0, didReceive: URLResponse(url: $0.request.url!, mimeType: nil,
                expectedContentLength: 2048, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        }
        let result = await prober().probe(stream())
        XCTAssertEqual(result, .inconclusive)
    }
    func testNetworkErrorNeverBecomesDefinitiveFailure() async {
        ProbeURLProtocol.configure { $0.client?.urlProtocol($0, didFailWithError: URLError(.timedOut)) }
        let result = await prober().probe(stream())
        XCTAssertEqual(result, .inconclusive)
    }
    func testParsingRequiredDoesNotUseHTTPProbe() async {
        ProbeURLProtocol.configure { _ in XCTFail("must not request") }
        let result = await prober().probe(stream(needsParsing: true))
        XCTAssertEqual(result, .inconclusive)
    }
}
