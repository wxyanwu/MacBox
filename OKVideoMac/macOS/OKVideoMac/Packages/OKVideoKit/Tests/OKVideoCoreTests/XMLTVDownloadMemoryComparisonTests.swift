import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(XMLTVStreaming) @testable import OKVideoCore

/// B1-M only. Direct and converted URLSession downloads share every other
/// lifecycle, copy, ownership, teardown, and measurement path in this file.
final class XMLTVDownloadMemoryComparisonTests: XCTestCase {
    private enum Mode: String, Codable {
        case direct
        case converted
    }

    private enum TrialError: String, Error {
        case response
        case encoding
        case length
        case network
        case cancelled
        case file
        case bodyCallback
    }

    private struct MemoryPoint: Codable {
        let rss: UInt64
        let footprint: UInt64
    }

    private struct MallocPoint: Codable {
        let live: UInt64
        let reserved: UInt64
    }

    private struct PeakPoint: Codable {
        let rss: UInt64
        let footprint: UInt64
        let samples: Int
    }

    private struct ExerciseResult {
        let copiedBytes: Int
        let sha256: String
        let progressUpdates: Int
        let largestProgressWrite: Int
        let foundationTemporaryFileRemoved: Bool
    }

    private struct Cycle: Codable {
        let index: Int
        let copiedBytes: Int
        let sha256: String
        let progressUpdates: Int
        let largestProgressWrite: Int
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

    private struct Report: Codable {
        let protocolVersion: Int
        let mode: Mode
        let runLabel: String
        let bytes: Int
        let cycles: Int
        let sha256: String
        let copyBufferBytes: Int
        let samplingMilliseconds: Int
        let settleMilliseconds: Int
        let baseline: MemoryPoint
        let baselineLiveMalloc: UInt64
        let baselineReservedMalloc: UInt64
        let baselineFDs: Int
        let results: [Cycle]
    }

    private final class Lifecycle: @unchecked Sendable {
        let invalidated = DispatchSemaphore(value: 0)
        let destroyed = DispatchSemaphore(value: 0)
    }

    /// High-frequency sampling intentionally avoids malloc-zone inspection,
    /// dictionaries, JSON, and an ever-growing sample array. stop() executes a
    /// barrier on the private serial queue; later timer deliveries see stopped.
    private final class PeakObserver: @unchecked Sendable {
        let baseline: MemoryPoint
        private let queue = DispatchQueue(label: "xmltv-b1m-memory-observer")
        private let timer: DispatchSourceTimer
        private var peakRSS: UInt64
        private var peakFootprint: UInt64
        private var sampleCount = 0
        private var stopped = false

        init() {
            let point = XMLTVDownloadMemoryComparisonTests.memoryPoint()
            baseline = point
            peakRSS = point.rss
            peakFootprint = point.footprint
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.sampleOnQueue() }
            timer.resume()
        }

        private func sampleOnQueue() {
            guard !stopped else { return }
            let point = XMLTVDownloadMemoryComparisonTests.memoryPoint()
            peakRSS = max(peakRSS, point.rss)
            peakFootprint = max(peakFootprint, point.footprint)
            sampleCount += 1
        }

        func stop() -> PeakPoint {
            queue.sync {
                guard !stopped else {
                    return PeakPoint(rss: peakRSS, footprint: peakFootprint, samples: sampleCount)
                }
                stopped = true
                timer.cancel()
                let point = XMLTVDownloadMemoryComparisonTests.memoryPoint()
                peakRSS = max(peakRSS, point.rss)
                peakFootprint = max(peakFootprint, point.footprint)
                sampleCount += 1
                return PeakPoint(rss: peakRSS, footprint: peakFootprint, samples: sampleCount)
            }
        }

        func recordedSamples() -> Int { queue.sync { sampleCount } }
        deinit { timer.cancel() }
    }

    private final class Trial: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
        private static let byteLimit: Int64 = 32 * 1_024 * 1_024
        private static let copyWorker = DispatchQueue(label: "xmltv-b1m-file-copy", qos: .utility)

        let staging: XMLTVStagingFile
        let lifecycle: Lifecycle
        let mode: Mode
        private let lock = NSLock()
        private var continuation: CheckedContinuation<XMLTVStagedFile, Error>?
        private var session: URLSession?
        private var originalTask: URLSessionTask?
        private var replacementTask: URLSessionDownloadTask?
        private var failure: TrialError?
        private var terminal = false
        private var responseAccepted = false
        private var copying = false
        private var copied = false
        private var httpCompleted = false
        private(set) var copiedBytes = 0
        private(set) var progressUpdates = 0
        private(set) var largestProgressWrite = 0
        private(set) var bodyCallbacks = 0
        private(set) var handoffs = 0
        private(set) var completions = 0
        private(set) var foundationTemporaryPath: String?
        var stagedDirectoryName: String { staging.testReceipt.directoryName }

        init(root: String, lifecycle: Lifecycle, mode: Mode) throws {
            staging = try XMLTVStagingFile.create(in: root)
            self.lifecycle = lifecycle
            self.mode = mode
        }

        func run(_ url: URL) async throws -> XMLTVStagedFile {
            guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
                  url.user == nil, url.password == nil else {
                try staging.release()
                throw TrialError.response
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { next in
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.httpShouldSetCookies = false
                    configuration.httpCookieStorage = nil
                    configuration.httpCookieAcceptPolicy = .never
                    configuration.urlCache = nil
                    configuration.urlCredentialStorage = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    configuration.timeoutIntervalForRequest = 30
                    configuration.timeoutIntervalForResource = 90
                    let delegateQueue = OperationQueue()
                    delegateQueue.name = "xmltv-b1m-url-session"
                    delegateQueue.maxConcurrentOperationCount = 1
                    delegateQueue.qualityOfService = .utility
                    let createdSession = URLSession(
                        configuration: configuration,
                        delegate: self,
                        delegateQueue: delegateQueue
                    )
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let createdTask: URLSessionTask
                    switch mode {
                    case .direct:
                        createdTask = createdSession.downloadTask(with: request)
                    case .converted:
                        createdTask = createdSession.dataTask(with: request)
                    }

                    lock.lock()
                    continuation = next
                    session = createdSession
                    originalTask = createdTask
                    let shouldCancel = failure != nil
                    lock.unlock()

                    createdTask.resume()
                    if shouldCancel { createdTask.cancel() }
                }
            } onCancel: {
                self.cancel()
            }
        }

        func cancel() {
            lock.lock()
            guard !terminal else { lock.unlock(); return }
            if failure == nil { failure = .cancelled }
            let original = originalTask
            let replacement = replacementTask
            lock.unlock()
            staging.requestCancellation()
            original?.cancel()
            replacement?.cancel()
        }

        private func reject(_ issue: TrialError) {
            lock.lock()
            if failure == nil { failure = issue }
            let original = originalTask
            let replacement = replacementTask
            lock.unlock()
            original?.cancel()
            replacement?.cancel()
        }

        private func validate(_ response: URLResponse?) throws {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.value(forHTTPHeaderField: "Content-Range") == nil else {
                throw TrialError.response
            }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard encoding == nil || encoding == "identity" else { throw TrialError.encoding }
            guard response?.expectedContentLength ?? -1 <= Self.byteLimit else { throw TrialError.length }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            do {
                guard mode == .converted else { throw TrialError.response }
                try validate(response)
                lock.lock()
                let stopped = failure != nil || terminal
                if !stopped { responseAccepted = true }
                lock.unlock()
                guard !stopped else { throw TrialError.cancelled }
                completionHandler(.becomeDownload)
            } catch let issue as TrialError {
                reject(issue)
                completionHandler(.cancel)
            } catch {
                reject(.response)
                completionHandler(.cancel)
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didBecome downloadTask: URLSessionDownloadTask
        ) {
            lock.lock()
            replacementTask = downloadTask
            let stopped = failure != nil || terminal
            lock.unlock()
            if stopped { downloadTask.cancel() }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            bodyCallbacks += 1
            lock.unlock()
            reject(.bodyCallback)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            lock.lock()
            progressUpdates += 1
            largestProgressWrite = max(largestProgressWrite, Int(bytesWritten))
            let stopped = failure != nil || terminal
            lock.unlock()
            guard !stopped else { return }
            if totalBytesWritten > Self.byteLimit || totalBytesExpectedToWrite > Self.byteLimit {
                reject(.length)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            reject(.response)
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            do {
                try validate(downloadTask.response)
                lock.lock()
                let stopped = failure != nil || terminal
                if mode == .direct, !stopped { responseAccepted = true }
                foundationTemporaryPath = location.path
                lock.unlock()
                guard !stopped else { throw TrialError.cancelled }

                let descriptor = Darwin.open(location.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw TrialError.file }
                var details = stat()
                guard fstat(descriptor, &details) == 0,
                      details.st_mode & S_IFMT == S_IFREG,
                      details.st_size > 0,
                      details.st_size <= Self.byteLimit else {
                    Darwin.close(descriptor)
                    throw TrialError.length
                }
                lock.lock()
                copying = true
                lock.unlock()

                Self.copyWorker.async { [self] in
                    copyPinnedFile(descriptor, expectedBytes: Int(details.st_size), response: downloadTask.response)
                }
            } catch let issue as TrialError {
                reject(issue)
            } catch {
                reject(.file)
            }
        }

        private func copyPinnedFile(_ descriptor: Int32, expectedBytes: Int, response: URLResponse?) {
            var result: TrialError?
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            do {
                while true {
                    lock.lock()
                    let stopped = failure != nil || terminal
                    lock.unlock()
                    if stopped { throw TrialError.cancelled }
                    let amount = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptor, $0.baseAddress, $0.count)
                    }
                    if amount < 0 {
                        if errno == EINTR { continue }
                        throw TrialError.file
                    }
                    if amount == 0 { break }
                    guard total <= Int(Self.byteLimit) - amount else { throw TrialError.length }
                    try buffer.withUnsafeBytes {
                        try staging.write(Data(bytes: $0.baseAddress!, count: amount))
                    }
                    total += amount
                }
                guard total == expectedBytes else { throw TrialError.length }
                let declared = response?.expectedContentLength ?? -1
                guard declared < 0 || declared == Int64(total) else { throw TrialError.length }
            } catch let issue as TrialError {
                result = issue
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .file
            }
            let closeResult = Darwin.close(descriptor)

            lock.lock()
            copying = false
            copied = result == nil && closeResult == 0
            copiedBytes = total
            if failure == nil { failure = result ?? (closeResult == 0 ? nil : .file) }
            lock.unlock()
            finishIfReady()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            httpCompleted = true
            if error != nil && failure == nil { failure = .network }
            lock.unlock()
            finishIfReady()
        }

        private func finishIfReady() {
            lock.lock()
            guard !terminal, httpCompleted, !copying else { lock.unlock(); return }
            var reader: XMLTVStagedFile?
            var issue = failure
            if issue == nil && (!responseAccepted || !copied) { issue = .file }
            if issue == nil {
                do {
                    reader = try staging.finishAndTransfer()
                    handoffs += 1
                } catch is CancellationError {
                    issue = .cancelled
                } catch {
                    issue = .file
                }
            }
            terminal = true
            failure = issue
            completions += 1
            let next = continuation
            let currentSession = session
            continuation = nil
            session = nil
            originalTask = nil
            replacementTask = nil
            lock.unlock()

            if let reader {
                currentSession?.finishTasksAndInvalidate()
                next?.resume(returning: reader)
            } else {
                do { try staging.release() } catch { XCTFail("B1-M staging cleanup failed") }
                currentSession?.invalidateAndCancel()
                next?.resume(throwing: issue ?? .file)
            }
        }

        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
            lifecycle.invalidated.signal()
        }

        deinit { lifecycle.destroyed.signal() }
    }

    private static func memoryPoint() -> MemoryPoint {
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
        return MemoryPoint(rss: info.resident_size, footprint: info.phys_footprint)
    }

    private static func mallocPoint() -> MallocPoint {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return MallocPoint(live: UInt64(stats.size_in_use), reserved: UInt64(stats.size_allocated))
    }

    private static func openFDCount() -> Int {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes >= 0 else { return -1 }
        return Int(bytes) / MemoryLayout<proc_fdinfo>.stride
    }

    private func assertAbsent(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        var details = stat()
        errno = 0
        XCTAssertEqual(lstat(path, &details), -1, file: file, line: line)
        XCTAssertEqual(errno, ENOENT, file: file, line: line)
    }

    private func exercise(mode: Mode, fixture: XMLTVStagingFileTests.Fixture, url: URL) async throws -> ExerciseResult {
        let lifecycle = Lifecycle()
        var trial: Trial? = try Trial(root: fixture.path, lifecycle: lifecycle, mode: mode)
        let child = trial!.stagedDirectoryName
        let reader = try await trial!.run(url)
        var digest = SHA256()
        var bytes = 0
        while true {
            let data = try reader.read()
            if data.isEmpty { break }
            digest.update(data: data)
            bytes += data.count
        }
        trial!.cancel() // A late cancel cannot revoke transferred ownership.
        XCTAssertTrue(try reader.read().isEmpty)
        try reader.release()
        XCTAssertEqual(lifecycle.invalidated.wait(timeout: .now() + 25), .success)
        let temporaryPath = trial!.foundationTemporaryPath
        let progressUpdates = trial!.progressUpdates
        let largestProgressWrite = trial!.largestProgressWrite
        XCTAssertEqual(trial!.bodyCallbacks, 0)
        XCTAssertEqual(trial!.handoffs, 1)
        XCTAssertEqual(trial!.completions, 1)
        let copiedBytes = trial!.copiedBytes
        trial = nil
        XCTAssertEqual(lifecycle.destroyed.wait(timeout: .now() + 10), .success)
        assertAbsent(fixture.path + "/" + child)
        guard let temporaryPath else { throw TrialError.file }
        assertAbsent(temporaryPath)
        return ExerciseResult(
            copiedBytes: copiedBytes,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            progressUpdates: progressUpdates,
            largestProgressWrite: largestProgressWrite,
            foundationTemporaryFileRemoved: true
        )
    }

    func testObserverStopsSynchronously() async throws {
        let observer = PeakObserver()
        try await Task.sleep(nanoseconds: 30_000_000)
        let stopped = observer.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertGreaterThan(stopped.samples, 0)
        XCTAssertEqual(observer.recordedSamples(), stopped.samples)
    }

    func testCommonLifecycleRepeatedSessionMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = Mode(rawValue: environment["OKVIDEO_B1M_MODE"] ?? ""),
              let port = Int(environment["OKVIDEO_B1M_PORT"] ?? ""),
              let expectedBytes = Int(environment["OKVIDEO_B1M_BYTES"] ?? ""),
              let cycles = Int(environment["OKVIDEO_B1M_CYCLES"] ?? ""),
              let expectedSHA = environment["OKVIDEO_B1M_SHA"],
              let runLabel = environment["OKVIDEO_B1M_RUN"] else {
            throw XCTSkip("Explicit B1-M loopback comparison only")
        }
        guard (1...65_535).contains(port), expectedBytes == 32 * 1_024 * 1_024,
              cycles == 8, !runLabel.isEmpty else { throw TrialError.response }
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("B1-M fixture cleanup failed") } }
        func url(_ bytes: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/bytes/\(bytes)")! }

        let warmup = try await exercise(mode: mode, fixture: fixture, url: url(65_536))
        XCTAssertEqual(warmup.copiedBytes, 65_536)
        try await Task.sleep(nanoseconds: 250_000_000)

        let baseline = Self.memoryPoint()
        let baselineMalloc = Self.mallocPoint()
        let baselineFDs = Self.openFDCount()
        XCTAssertGreaterThanOrEqual(baselineFDs, 0)
        let profilePhases = environment["OKVIDEO_B1M_PROFILE_PHASES"] == "1"
        var rows: [Cycle] = []
        rows.reserveCapacity(cycles)

        for index in 1...cycles {
            let observer = PeakObserver()
            let began = DispatchTime.now().uptimeNanoseconds
            let result = try await exercise(mode: mode, fixture: fixture, url: url(expectedBytes))
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
            let peak = observer.stop()
            try await Task.sleep(nanoseconds: 250_000_000)
            let settled = Self.memoryPoint()
            let settledMalloc = Self.mallocPoint()
            let fds = Self.openFDCount()
            XCTAssertGreaterThan(peak.samples, 0)
            XCTAssertEqual(result.copiedBytes, expectedBytes)
            XCTAssertEqual(result.sha256, expectedSHA)
            XCTAssertGreaterThanOrEqual(fds, 0)
            rows.append(Cycle(
                index: index,
                copiedBytes: result.copiedBytes,
                sha256: result.sha256,
                progressUpdates: result.progressUpdates,
                largestProgressWrite: result.largestProgressWrite,
                seconds: elapsed,
                peakRSSDeltaMiB: Double(peak.rss > observer.baseline.rss ? peak.rss - observer.baseline.rss : 0) / 1_048_576,
                peakFootprintDeltaMiB: Double(peak.footprint > observer.baseline.footprint ? peak.footprint - observer.baseline.footprint : 0) / 1_048_576,
                settledRSS: settled.rss,
                settledFootprint: settled.footprint,
                settledLiveMalloc: settledMalloc.live,
                settledReservedMalloc: settledMalloc.reserved,
                openFDs: fds,
                foundationTemporaryFileRemoved: result.foundationTemporaryFileRemoved
            ))
            if profilePhases, index == 2 || index == 8 {
                print("B1M_PROFILE_PAUSE mode=\(mode.rawValue) cycle=\(index)")
                fflush(stdout)
                XCTAssertEqual(raise(SIGSTOP), 0)
            }
        }

        let report = Report(
            protocolVersion: 1,
            mode: mode,
            runLabel: runLabel,
            bytes: expectedBytes,
            cycles: cycles,
            sha256: expectedSHA,
            copyBufferBytes: 65_536,
            samplingMilliseconds: 10,
            settleMilliseconds: 250,
            baseline: baseline,
            baselineLiveMalloc: baselineMalloc.live,
            baselineReservedMalloc: baselineMalloc.reserved,
            baselineFDs: baselineFDs,
            results: rows
        )
        print("B1M_MEMORY " + String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
    }
}
