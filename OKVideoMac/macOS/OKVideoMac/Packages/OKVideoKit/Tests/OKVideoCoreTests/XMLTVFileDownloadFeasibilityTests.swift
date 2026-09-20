import Foundation
import XCTest
import Darwin
import CryptoKit
@_spi(XMLTVStreaming) @testable import OKVideoCore

/// B's first gate, NOT a shippable downloader. Real loopback URLSession + frozen
/// Change A, no mock URLProtocol, no parser, no production caller. Stop here if
/// serialized synchronous writes still allow Foundation to buffer the full body.
final class XMLTVFileDownloadFeasibilityTests: XCTestCase {
    // Explicit diagnostic variants, never selected by production code.
    private enum Variant: String { case R0, R1, R2 }
    private struct Phase: Codable {
        let name: String, point: Point
        let liveMallocBytes: UInt64, mallocReservedBytes: UInt64
        let written: Int, callbackBytes: Int
    }
    private final class Lifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [Phase] = []
        let invalidated = DispatchSemaphore(value: 0)
        let destroyed = DispatchSemaphore(value: 0)
        let pause: String
        private var didPause = false
        init(pause: String = "") { self.pause = pause; records.reserveCapacity(16) }
        func mark(_ name: String, written: Int = 0, callbackBytes: Int = 0) {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            let row = Phase(name: name, point: XMLTVFileDownloadFeasibilityTests.point(),
                liveMallocBytes: UInt64(stats.size_in_use), mallocReservedBytes: UInt64(stats.size_allocated),
                written: written, callbackBytes: callbackBytes)
            lock.lock(); records.append(row)
            let stop = pause == name && !didPause
            if stop { didPause = true }; lock.unlock()
            if stop {
                // Diagnostic-only barrier: one per process, external capture,
                // bounded wait. Never waits for work on the delegate queue.
                print("XMLTV_PAUSE \(name) \(written) \(callbackBytes)"); fflush(stdout)
                let begin = DispatchTime.now().uptimeNanoseconds
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 15_000)
                var byte: UInt8 = 0
                let resumed = ready > 0 && Darwin.read(STDIN_FILENO, &byte, 1) == 1 && byte == 10
                print("XMLTV_RESUMED \(name) \(resumed) \(DispatchTime.now().uptimeNanoseconds - begin)")
                XCTAssertTrue(resumed, "Diagnostic barrier timed out or lost its controller")
            }
        }
        func rows() -> [Phase] { lock.lock(); defer { lock.unlock() }; return records }
    }
    private enum TrialError: Error { case response, encoding, length, network, cancelled }
    private final class Trial: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let file: XMLTVStagingFile
        let bytesPerSecond: Int
        private let variant: Variant
        private let lifecycle: Lifecycle?
        private var markedCallback = false
        private let lock = NSLock()
        private var continuation: CheckedContinuation<XMLTVStagedFile, Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var cancelled = false
        private var finished = false
        private var accepted = false
        private var declared: Int64 = -1
        private(set) var written = 0
        private(set) var callbacks = 0
        private(set) var largestCallback = 0
        var stagedDirectoryName: String { file.testReceipt.directoryName }

        init(root: String, rate: Int, variant: Variant = .R0, lifecycle: Lifecycle? = nil) throws {
            self.variant = variant; self.lifecycle = lifecycle
            if variant == .R0 {
                file = try XMLTVStagingFile.create(in: root)
            } else {
                // R1 only moves the same proportional sleep to the frozen A
                // low-level write hook. R2 shares this identical hook.
                file = try XMLTVStagingFile.create(in: root, write: { fd, pointer, count in
                    if rate > 0 { Thread.sleep(forTimeInterval: Double(count) / Double(rate)) }
                    let result = Darwin.write(fd, pointer, count)
                    if result < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    return result
                })
            }
            bytesPerSecond = rate
        }
        func run(_ url: URL) async throws -> XMLTVStagedFile {
            // The trial is strictly loopback-only. General redirect/authentication
            // policy is intentionally not implemented before the memory gate.
            guard url.scheme == "http", url.host == "127.0.0.1", url.user == nil,
                  url.password == nil, url.port != nil else { try file.release(); throw TrialError.response }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { next in
                    let config = URLSessionConfiguration.ephemeral
                    config.httpShouldSetCookies = false
                    config.httpCookieAcceptPolicy = .never
                    config.httpCookieStorage = nil
                    config.urlCache = nil
                    config.urlCredentialStorage = nil
                    config.requestCachePolicy = .reloadIgnoringLocalCacheData
                    config.timeoutIntervalForRequest = 30
                    config.timeoutIntervalForResource = 90
                    let queue = OperationQueue()
                    queue.name = "xmltv-download-feasibility"
                    queue.maxConcurrentOperationCount = 1
                    queue.qualityOfService = .utility
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let task = session.dataTask(with: request)
                    lock.lock()
                    self.continuation = next; self.session = session; self.task = task
                    let stop = cancelled
                    lock.unlock()
                    task.resume()
                    if stop { file.requestCancellation(); task.cancel() }
                }
            } onCancel: {
                self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock()
                self.file.requestCancellation()
                task?.cancel()
            }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.value(forHTTPHeaderField: "Content-Range") == nil else {
                completionHandler(.cancel); fail(TrialError.response); return
            }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard encoding == nil || encoding == "identity" else {
                completionHandler(.cancel); fail(TrialError.encoding); return
            }
            declared = response.expectedContentLength
            guard declared <= 32 * 1_024 * 1_024 else {
                completionHandler(.cancel); fail(TrialError.length); return
            }
            accepted = true
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !finished, accepted else { return }
            callbacks += 1; largestCallback = max(largestCallback, data.count)
            do {
                if variant == .R2 {
                    try file.write(data)
                    written += data.count
                    markCallback(data.count)
                    return
                }
                // No Task per chunk, no async body queue, no full Data append.
                // Delay is proportional to bytes, not callback count. Subchunks
                // bound the injected sleep to 31.25ms at the 2 MiB/s test rate.
                var offset = 0
                while offset < data.count {
                    let count = min(65_536, data.count - offset)
                    if variant == .R0 && bytesPerSecond > 0 {
                        Thread.sleep(forTimeInterval: Double(count) / Double(bytesPerSecond))
                    }
                    try file.write(data.subdata(in: offset..<(offset + count)))
                    offset += count; written += count
                    markCallback(data.count)
                }
            } catch { fail(error is CancellationError ? TrialError.cancelled : error) }
        }
        private func markCallback(_ count: Int) {
            // First completed write at/after 512 KiB; record actual progress
            // because callback size is not controlled by this downloader.
            if !markedCallback && written >= 524_288 {
                markedCallback = true
                lifecycle?.mark("callback", written: written, callbackBytes: count)
            }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil); fail(TrialError.response)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !finished else { return }
            guard error == nil, accepted else { fail(TrialError.network); return }
            guard written > 0, declared < 0 || declared == Int64(written) else { fail(TrialError.length); return }
            lifecycle?.mark("completion", written: written)
            do {
                lock.lock()
                if cancelled { lock.unlock(); fail(TrialError.cancelled); return }
                let value: XMLTVStagedFile
                do { value = try file.finishAndTransfer() }
                catch { lock.unlock(); throw error }
                finished = true
                let next = continuation; continuation = nil
                self.task = nil; self.session = nil
                lock.unlock()
                session.finishTasksAndInvalidate()
                next?.resume(returning: value)
            } catch { fail(error) }
        }
        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
            lifecycle?.mark("invalidated", written: written)
            lifecycle?.invalidated.signal()
        }
        deinit { lifecycle?.mark("delegateDestroyed", written: written); lifecycle?.destroyed.signal() }
        private func fail(_ error: Error) {
            guard !finished else { return }; finished = true
            do { try file.release() } catch { XCTFail("Trial cleanup refused; no fallback deletion") }
            lock.lock()
            let next = continuation; continuation = nil
            let session = self.session; self.session = nil; task = nil
            lock.unlock()
            session?.invalidateAndCancel()
            next?.resume(throwing: error)
        }
    }

    private struct Point: Codable {
        let nanoseconds: UInt64
        let rss: UInt64
        let footprint: UInt64
        let peakRSS: UInt64
    }
    private static func point() -> Point {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS, "Memory measurement unavailable")
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Point(nanoseconds: DispatchTime.now().uptimeNanoseconds, rss: info.resident_size,
                     footprint: info.phys_footprint, peakRSS: UInt64(max(0, usage.ru_maxrss)))
    }
    private static func mallocUsage() -> (live: UInt64, reserved: UInt64) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (UInt64(stats.size_in_use), UInt64(stats.size_allocated))
    }
    private static func openFDCount() -> Int {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes >= 0 else { return -1 }
        return Int(bytes) / MemoryLayout<proc_fdinfo>.stride
    }
    private final class Samples: @unchecked Sendable {
        let baseline = XMLTVFileDownloadFeasibilityTests.point()
        private let lock = NSLock()
        private let timer: DispatchSourceTimer
        private var rows: [Point] = []
        private var stopped = false
        init() {
            // Fixed observer capacity, independent of response size; no growing
            // measurement buffer while trying to measure the network buffer.
            rows.reserveCapacity(12_000)
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "xmltv-download-rss"))
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
        }
        func sample() {
            let row = XMLTVFileDownloadFeasibilityTests.point()
            lock.lock(); defer { lock.unlock() }
            if !stopped && rows.count < 12_000 { rows.append(row) }
        }
        func stop() -> [Point] {
            timer.cancel()
            let final = XMLTVFileDownloadFeasibilityTests.point()
            lock.lock(); defer { lock.unlock() }
            stopped = true
            if rows.count < 12_000 { rows.append(final) }
            return rows // late callbacks cannot mutate/trigger COW after transfer
        }
        deinit { timer.cancel() }
    }
    private func consume(_ reader: XMLTVStagedFile) throws -> (Int, String) {
        var digest = SHA256(), count = 0
        while true {
            let data = try reader.read()
            if data.isEmpty { break }
            digest.update(data: data); count += data.count
        }
        try reader.release()
        return (count, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    func testRealURLSessionMemoryGate() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let portText = env["OKVIDEO_XMLTV_TRIAL_PORT"], let port = Int(portText),
              let countText = env["OKVIDEO_XMLTV_TRIAL_BYTES"], let bytes = Int(countText),
              let rateText = env["OKVIDEO_XMLTV_TRIAL_RATE"], let rate = Int(rateText),
              let expectedSHA = env["OKVIDEO_XMLTV_TRIAL_SHA"] else {
            throw XCTSkip("Explicit loopback feasibility harness only; not a production test invocation")
        }
        XCTAssertTrue((1...32 * 1_024 * 1_024).contains(bytes))
        XCTAssertTrue(rate == 0 || rate == 2 * 1_024 * 1_024)
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("Explicit fixture cleanup failed") } }
        func url(_ count: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/bytes/\(count)")! }
        let warmup = try Trial(root: fixture.path, rate: 0)
        _ = try consume(try await warmup.run(url(65_536)))
        let trial = try Trial(root: fixture.path, rate: rate)
        let samples = Samples()
        let value = try await trial.run(url(bytes))
        let transfer = Self.point()
        let rows = samples.stop()
        let (readBytes, digest) = try consume(value)
        XCTAssertEqual(readBytes, bytes); XCTAssertEqual(trial.written, bytes); XCTAssertEqual(digest, expectedSHA)
        struct Report: Codable {
            let bytes: Int, rate: Int, written: Int, readBytes: Int, sha256: String
            let callbacks: Int, maxCallbackBytes: Int
            let baseline: Point, transfer: Point, released: Point, samples: [Point]
        }
        let report = Report(bytes: bytes, rate: rate, written: trial.written, readBytes: readBytes, sha256: digest,
            callbacks: trial.callbacks, maxCallbackBytes: trial.largestCallback, baseline: samples.baseline,
            transfer: transfer, released: Self.point(), samples: rows)
        let data = try JSONEncoder().encode(report)
        print("XMLTV_DOWNLOAD_TRIAL " + String(decoding: data, as: UTF8.self))
    }

    func testMemoryAttribution() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let variant = Variant(rawValue: env["OKVIDEO_XMLTV_VARIANT"] ?? ""),
              let port = Int(env["OKVIDEO_XMLTV_TRIAL_PORT"] ?? ""),
              let count = Int(env["OKVIDEO_XMLTV_TRIAL_BYTES"] ?? ""),
              let rate = Int(env["OKVIDEO_XMLTV_TRIAL_RATE"] ?? ""),
              let sha = env["OKVIDEO_XMLTV_TRIAL_SHA"] else { throw XCTSkip("Explicit memory attribution only") }
        guard (1...32 * 1_024 * 1_024).contains(count), [0, 2 * 1_024 * 1_024].contains(rate),
              (1...65535).contains(port) else { throw TrialError.response }
        let pause = env["OKVIDEO_XMLTV_PAUSE"] ?? ""
        guard ["", "callback", "completion", "invalidated", "released"].contains(pause) else { throw TrialError.response }
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("Explicit fixture cleanup failed") } }
        func url(_ bytes: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/bytes/\(bytes)")! }
        let warm = Lifecycle()
        var warmup: Trial? = try Trial(root: fixture.path, rate: 0, lifecycle: warm)
        _ = try consume(try await warmup!.run(url(65_536)))
        XCTAssertEqual(warm.invalidated.wait(timeout: .now() + 10), .success)
        warmup = nil
        XCTAssertEqual(warm.destroyed.wait(timeout: .now() + 10), .success)

        let lifecycle = Lifecycle(pause: pause)
        var trial: Trial? = try Trial(root: fixture.path, rate: rate, variant: variant, lifecycle: lifecycle)
        lifecycle.mark("baseline")
        let samples = Samples()
        let reader = try await trial!.run(url(count))
        let transfer = Self.point()
        let rows = samples.stop() // original gate interval; teardown reported separately
        lifecycle.mark("transferred", written: count)
        XCTAssertEqual(lifecycle.invalidated.wait(timeout: .now() + 25), .success)
        let (readBytes, digest) = try consume(reader)
        lifecycle.mark("released", written: readBytes)
        XCTAssertEqual(readBytes, count); XCTAssertEqual(trial!.written, count); XCTAssertEqual(digest, sha)
        let callbacks = trial!.callbacks, maxCallback = trial!.largestCallback
        trial = nil
        XCTAssertEqual(lifecycle.destroyed.wait(timeout: .now() + 10), .success)
        try await Task.sleep(nanoseconds: 250_000_000)
        lifecycle.mark("settled")
        struct Report: Codable {
            let variant: String, pause: String, bytes: Int, rate: Int, written: Int, sha256: String
            let callbacks: Int, maxCallbackBytes: Int
            let baseline: Point, transfer: Point, samples: [Point], phases: [Phase]
        }
        let report = Report(variant: variant.rawValue, pause: pause, bytes: count, rate: rate,
            written: readBytes, sha256: digest, callbacks: callbacks, maxCallbackBytes: maxCallback,
            baseline: samples.baseline, transfer: transfer, samples: rows, phases: lifecycle.rows())
        print("XMLTV_ATTRIBUTION " + String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
    }

    func testRepeatedSessionStability() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let variant = Variant(rawValue: env["OKVIDEO_XMLTV_VARIANT"] ?? ""),
              let port = Int(env["OKVIDEO_XMLTV_TRIAL_PORT"] ?? ""),
              let count = Int(env["OKVIDEO_XMLTV_TRIAL_BYTES"] ?? ""),
              let rate = Int(env["OKVIDEO_XMLTV_TRIAL_RATE"] ?? ""),
              let cycles = Int(env["OKVIDEO_XMLTV_REPEAT_CYCLES"] ?? ""),
              let sha = env["OKVIDEO_XMLTV_TRIAL_SHA"] else { throw XCTSkip("Explicit budget review only") }
        guard [Variant.R0, .R2].contains(variant), count == 32 * 1_024 * 1_024,
              [0, 2 * 1_024 * 1_024].contains(rate), (5...8).contains(cycles),
              (1...65535).contains(port) else { throw TrialError.response }
        struct Cycle: Codable {
            let index: Int, callbacks: Int, maxCallbackBytes: Int, seconds: Double
            let peakRSSDeltaMiB: Double, peakFootprintDeltaMiB: Double
            let settledRSS: UInt64, settledFootprint: UInt64
            let settledLiveMalloc: UInt64, settledReservedMalloc: UInt64, openFDs: Int
        }
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("Explicit fixture cleanup failed") } }
        func url(_ bytes: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/bytes/\(bytes)")! }
        let warm = Lifecycle()
        var warmup: Trial? = try Trial(root: fixture.path, rate: 0, lifecycle: warm)
        _ = try consume(try await warmup!.run(url(65_536)))
        XCTAssertEqual(warm.invalidated.wait(timeout: .now() + 10), .success)
        warmup = nil
        XCTAssertEqual(warm.destroyed.wait(timeout: .now() + 10), .success)
        try await Task.sleep(nanoseconds: 250_000_000)
        let runBaseline = Self.point(), baselineMalloc = Self.mallocUsage(), baselineFDs = Self.openFDCount()
        var reports: [Cycle] = []; reports.reserveCapacity(cycles)
        for index in 1...cycles {
            let lifecycle = Lifecycle()
            var trial: Trial? = try Trial(root: fixture.path, rate: rate, variant: variant, lifecycle: lifecycle)
            let child = trial!.stagedDirectoryName
            let samples = Samples()
            let reader = try await trial!.run(url(count))
            let transfer = Self.point(), rows = samples.stop()
            XCTAssertEqual(lifecycle.invalidated.wait(timeout: .now() + 25), .success)
            let (readBytes, digest) = try consume(reader)
            XCTAssertEqual(readBytes, count); XCTAssertEqual(trial!.written, count); XCTAssertEqual(digest, sha)
            let callbacks = trial!.callbacks, maximum = trial!.largestCallback
            trial = nil
            XCTAssertEqual(lifecycle.destroyed.wait(timeout: .now() + 10), .success)
            try await Task.sleep(nanoseconds: 250_000_000)
            var info = stat()
            XCTAssertEqual(lstat(fixture.path + "/" + child, &info), -1)
            XCTAssertEqual(errno, ENOENT)
            let settled = Self.point(), malloc = Self.mallocUsage(), fds = Self.openFDCount()
            let points = rows + [transfer]
            reports.append(Cycle(index: index, callbacks: callbacks, maxCallbackBytes: maximum,
                seconds: Double(transfer.nanoseconds - samples.baseline.nanoseconds) / 1e9,
                peakRSSDeltaMiB: Double(max(0, points.map(\.rss).max()! - samples.baseline.rss)) / 1_048_576,
                peakFootprintDeltaMiB: Double(max(0, points.map(\.footprint).max()! - samples.baseline.footprint)) / 1_048_576,
                settledRSS: settled.rss, settledFootprint: settled.footprint,
                settledLiveMalloc: malloc.live, settledReservedMalloc: malloc.reserved, openFDs: fds))
        }
        struct Report: Codable {
            let variant: String, bytes: Int, rate: Int, cycles: Int, sha256: String
            let baseline: Point, baselineLiveMalloc: UInt64, baselineReservedMalloc: UInt64, baselineFDs: Int
            let results: [Cycle]
        }
        let report = Report(variant: variant.rawValue, bytes: count, rate: rate, cycles: cycles, sha256: sha,
            baseline: runBaseline, baselineLiveMalloc: baselineMalloc.live,
            baselineReservedMalloc: baselineMalloc.reserved, baselineFDs: baselineFDs, results: reports)
        print("XMLTV_STABILITY " + String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
    }
}
