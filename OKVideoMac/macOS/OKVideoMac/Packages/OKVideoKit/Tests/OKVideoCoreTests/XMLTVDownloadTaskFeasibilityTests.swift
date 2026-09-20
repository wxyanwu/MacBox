import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(XMLTVStreaming) @testable import OKVideoCore

/// R3 is a developer-only feasibility experiment. Foundation downloads to its
/// own temporary file, then this test copies through a fixed 64 KiB buffer into
/// frozen Change A ownership. It is not a production downloader.
final class XMLTVDownloadTaskFeasibilityTests: XCTestCase {
    private enum TrialError: Error { case response, encoding, length, network, cancelled, file }

    private struct Point: Codable {
        let nanoseconds: UInt64
        let rss: UInt64
        let footprint: UInt64
        let peakRSS: UInt64
    }

    private static func point() -> Point {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS, "Memory measurement unavailable")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Point(
            nanoseconds: DispatchTime.now().uptimeNanoseconds,
            rss: info.resident_size,
            footprint: info.phys_footprint,
            peakRSS: UInt64(max(0, usage.ru_maxrss))
        )
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
        let baseline = XMLTVDownloadTaskFeasibilityTests.point()
        private let lock = NSLock()
        private let timer: DispatchSourceTimer
        private var rows: [Point] = []
        private var stopped = false

        init() {
            rows.reserveCapacity(12_000)
            timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "xmltv-download-task-rss")
            )
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
        }

        private func sample() {
            let row = XMLTVDownloadTaskFeasibilityTests.point()
            lock.lock()
            defer { lock.unlock() }
            if !stopped, rows.count < 12_000 { rows.append(row) }
        }

        func stop() -> [Point] {
            timer.cancel()
            let final = XMLTVDownloadTaskFeasibilityTests.point()
            lock.lock()
            defer { lock.unlock() }
            stopped = true
            if rows.count < 12_000 { rows.append(final) }
            return rows
        }

        deinit { timer.cancel() }
    }

    private final class Lifecycle: @unchecked Sendable {
        let invalidated = DispatchSemaphore(value: 0)
        let destroyed = DispatchSemaphore(value: 0)
    }

    private final class DownloadTrial: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private static let byteLimit: Int64 = 32 * 1_024 * 1_024

        let file: XMLTVStagingFile
        let lifecycle: Lifecycle
        private let lock = NSLock()
        private var continuation: CheckedContinuation<XMLTVStagedFile, Error>?
        private var session: URLSession?
        private var task: URLSessionDownloadTask?
        private var pendingReader: XMLTVStagedFile?
        private var terminal = false
        private var cancelled = false
        private(set) var copiedBytes = 0
        private(set) var progressUpdates = 0
        private(set) var largestProgressWrite = 0
        private(set) var foundationTemporaryPath: String?
        var stagedDirectoryName: String { file.testReceipt.directoryName }

        init(root: String, lifecycle: Lifecycle) throws {
            file = try XMLTVStagingFile.create(in: root)
            self.lifecycle = lifecycle
        }

        func run(_ url: URL) async throws -> XMLTVStagedFile {
            guard url.scheme == "http", url.host == "127.0.0.1", url.user == nil,
                  url.password == nil, url.port != nil else {
                try file.release()
                throw TrialError.response
            }
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
                    queue.name = "xmltv-download-task-feasibility"
                    queue.maxConcurrentOperationCount = 1
                    queue.qualityOfService = .utility
                    let createdSession = URLSession(
                        configuration: config,
                        delegate: self,
                        delegateQueue: queue
                    )
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let createdTask = createdSession.downloadTask(with: request)

                    lock.lock()
                    continuation = next
                    session = createdSession
                    task = createdTask
                    let shouldStop = cancelled
                    lock.unlock()

                    createdTask.resume()
                    if shouldStop {
                        file.requestCancellation()
                        createdTask.cancel()
                    }
                }
            } onCancel: {
                self.lock.lock()
                self.cancelled = true
                let currentTask = self.task
                self.lock.unlock()
                self.file.requestCancellation()
                currentTask?.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard !terminal else { return }
            progressUpdates += 1
            largestProgressWrite = max(largestProgressWrite, Int(bytesWritten))
            if totalBytesWritten > Self.byteLimit || totalBytesExpectedToWrite > Self.byteLimit {
                downloadTask.cancel()
                fail(TrialError.length)
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            guard !terminal else { return }
            do {
                try validate(downloadTask.response)
                foundationTemporaryPath = location.path
                copiedBytes = try copyFoundationFile(at: location)
                guard copiedBytes > 0 else { throw TrialError.length }
                if let expected = downloadTask.response?.expectedContentLength,
                   expected >= 0, expected != Int64(copiedBytes) {
                    throw TrialError.length
                }
                let reader = try file.finishAndTransfer()
                lock.lock()
                if terminal || cancelled {
                    lock.unlock()
                    try reader.release()
                    fail(TrialError.cancelled)
                    return
                }
                pendingReader = reader
                lock.unlock()
            } catch {
                fail(error is CancellationError ? TrialError.cancelled : error)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
            fail(TrialError.response)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            guard !terminal else { lock.unlock(); return }
            guard error == nil, !cancelled, let reader = pendingReader else {
                lock.unlock()
                fail(error == nil ? TrialError.file : TrialError.network)
                return
            }
            terminal = true
            pendingReader = nil
            let next = continuation
            continuation = nil
            self.task = nil
            self.session = nil
            lock.unlock()

            session.finishTasksAndInvalidate()
            next?.resume(returning: reader)
        }

        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
            lifecycle.invalidated.signal()
        }

        deinit { lifecycle.destroyed.signal() }

        private func validate(_ response: URLResponse?) throws {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.value(forHTTPHeaderField: "Content-Range") == nil else {
                throw TrialError.response
            }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard encoding == nil || encoding == "identity" else { throw TrialError.encoding }
            let expected = response?.expectedContentLength ?? -1
            guard expected <= Self.byteLimit else { throw TrialError.length }
        }

        private func copyFoundationFile(at location: URL) throws -> Int {
            let descriptor = open(location.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw TrialError.file }
            defer { _ = close(descriptor) }
            var details = stat()
            guard fstat(descriptor, &details) == 0,
                  details.st_mode & S_IFMT == S_IFREG,
                  details.st_size >= 0,
                  details.st_size <= Self.byteLimit else { throw TrialError.file }

            var buffer = [UInt8](repeating: 0, count: 65_536)
            var total = 0
            while true {
                if cancelled { throw TrialError.cancelled }
                let amount = Darwin.read(descriptor, &buffer, buffer.count)
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw TrialError.file
                }
                if amount == 0 { break }
                guard total <= Int(Self.byteLimit) - amount else { throw TrialError.length }
                let chunk = Data(bytes: buffer, count: amount)
                try file.write(chunk)
                total += amount
            }
            return total
        }

        private func fail(_ error: Error) {
            lock.lock()
            guard !terminal else { lock.unlock(); return }
            terminal = true
            let next = continuation
            continuation = nil
            let reader = pendingReader
            pendingReader = nil
            let currentSession = session
            session = nil
            task = nil
            lock.unlock()

            do {
                if let reader { try reader.release() } else { try file.release() }
            } catch {
                XCTFail("R3 cleanup refused; no fallback deletion")
            }
            currentSession?.invalidateAndCancel()
            next?.resume(throwing: error)
        }
    }

    private func consume(_ reader: XMLTVStagedFile) throws -> (Int, String) {
        var digest = SHA256()
        var count = 0
        while true {
            let data = try reader.read()
            if data.isEmpty { break }
            digest.update(data: data)
            count += data.count
        }
        try reader.release()
        return (count, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func assertAbsent(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        var details = stat()
        errno = 0
        XCTAssertEqual(lstat(path, &details), -1, file: file, line: line)
        XCTAssertEqual(errno, ENOENT, file: file, line: line)
    }

    func testDownloadTaskRepeatedSessionStability() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = Int(env["OKVIDEO_XMLTV_TRIAL_PORT"] ?? ""),
              let count = Int(env["OKVIDEO_XMLTV_TRIAL_BYTES"] ?? ""),
              let cycles = Int(env["OKVIDEO_XMLTV_REPEAT_CYCLES"] ?? ""),
              let expectedSHA = env["OKVIDEO_XMLTV_TRIAL_SHA"] else {
            throw XCTSkip("Explicit R3 loopback review only")
        }
        guard count == 32 * 1_024 * 1_024, cycles == 8,
              (1...65_535).contains(port) else { throw TrialError.response }

        struct Cycle: Codable {
            let index: Int
            let progressUpdates: Int
            let largestProgressWrite: Int
            let copiedBytes: Int
            let seconds: Double
            let peakRSSDeltaMiB: Double
            let peakFootprintDeltaMiB: Double
            let settledRSS: UInt64
            let settledFootprint: UInt64
            let settledLiveMalloc: UInt64
            let settledReservedMalloc: UInt64
            let openFDs: Int
            let foundationTemporaryFileRemoved: Bool
        }

        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("Explicit fixture cleanup failed") } }
        func url(_ bytes: Int) -> URL {
            URL(string: "http://127.0.0.1:\(port)/bytes/\(bytes)")!
        }

        let warmLifecycle = Lifecycle()
        var warmup: DownloadTrial? = try DownloadTrial(root: fixture.path, lifecycle: warmLifecycle)
        let warmReader = try await warmup!.run(url(65_536))
        let warmTemp = warmup!.foundationTemporaryPath
        _ = try consume(warmReader)
        XCTAssertEqual(warmLifecycle.invalidated.wait(timeout: .now() + 10), .success)
        warmup = nil
        XCTAssertEqual(warmLifecycle.destroyed.wait(timeout: .now() + 10), .success)
        if let warmTemp { assertAbsent(warmTemp) } else { XCTFail("Foundation temporary file not observed") }
        try await Task.sleep(nanoseconds: 250_000_000)

        let runBaseline = Self.point()
        let baselineMalloc = Self.mallocUsage()
        let baselineFDs = Self.openFDCount()
        var reports: [Cycle] = []
        reports.reserveCapacity(cycles)

        for index in 1...cycles {
            let lifecycle = Lifecycle()
            var trial: DownloadTrial? = try DownloadTrial(root: fixture.path, lifecycle: lifecycle)
            let child = trial!.stagedDirectoryName
            let samples = Samples()
            let reader = try await trial!.run(url(count))
            let transfer = Self.point()
            let sampleRows = samples.stop()
            XCTAssertEqual(lifecycle.invalidated.wait(timeout: .now() + 25), .success)
            let foundationTemp = trial!.foundationTemporaryPath
            let (readBytes, digest) = try consume(reader)
            XCTAssertEqual(readBytes, count)
            XCTAssertEqual(trial!.copiedBytes, count)
            XCTAssertEqual(digest, expectedSHA)
            let updates = trial!.progressUpdates
            let largestWrite = trial!.largestProgressWrite
            trial = nil
            XCTAssertEqual(lifecycle.destroyed.wait(timeout: .now() + 10), .success)
            try await Task.sleep(nanoseconds: 250_000_000)

            assertAbsent(fixture.path + "/" + child)
            guard let foundationTemp else {
                XCTFail("Foundation temporary file not observed")
                throw TrialError.file
            }
            assertAbsent(foundationTemp)
            let settled = Self.point()
            let malloc = Self.mallocUsage()
            let fds = Self.openFDCount()
            let points = sampleRows + [transfer]
            reports.append(Cycle(
                index: index,
                progressUpdates: updates,
                largestProgressWrite: largestWrite,
                copiedBytes: readBytes,
                seconds: Double(transfer.nanoseconds - samples.baseline.nanoseconds) / 1e9,
                peakRSSDeltaMiB: Double(max(0, points.map(\.rss).max()! - samples.baseline.rss)) / 1_048_576,
                peakFootprintDeltaMiB: Double(max(0, points.map(\.footprint).max()! - samples.baseline.footprint)) / 1_048_576,
                settledRSS: settled.rss,
                settledFootprint: settled.footprint,
                settledLiveMalloc: malloc.live,
                settledReservedMalloc: malloc.reserved,
                openFDs: fds,
                foundationTemporaryFileRemoved: true
            ))
        }

        struct Report: Codable {
            let variant: String
            let bytes: Int
            let cycles: Int
            let sha256: String
            let downloadTaskUsed: Bool
            let dataDelegateUsed: Bool
            let copyBufferBytes: Int
            let baseline: Point
            let baselineLiveMalloc: UInt64
            let baselineReservedMalloc: UInt64
            let baselineFDs: Int
            let results: [Cycle]
        }
        let report = Report(
            variant: "R3",
            bytes: count,
            cycles: cycles,
            sha256: expectedSHA,
            downloadTaskUsed: true,
            dataDelegateUsed: false,
            copyBufferBytes: 65_536,
            baseline: runBaseline,
            baselineLiveMalloc: baselineMalloc.live,
            baselineReservedMalloc: baselineMalloc.reserved,
            baselineFDs: baselineFDs,
            results: reports
        )
        print("XMLTV_DOWNLOAD_TASK_STABILITY " + String(
            decoding: try JSONEncoder().encode(report),
            as: UTF8.self
        ))
    }
}
