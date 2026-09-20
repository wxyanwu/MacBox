import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(XMLTVStreaming) @testable import OKVideoCore

/// B1-N only. Both variants use response-validated data-task conversion. The
/// only intended variable is one URLSession per operation versus one warmed,
/// bounded router/session for the complete sequential run.
final class XMLTVDownloadSharedSessionTests: XCTestCase {
    private enum SessionMode: String, Codable {
        case perOperation
        case sharedSession
    }

    private enum Failure: String, Error {
        case response
        case encoding
        case length
        case network
        case cancelled
        case file
        case bodyCallback
        case closed
    }

    private struct MemoryPoint: Codable {
        let rss: UInt64
        let footprint: UInt64
    }

    private struct MallocPoint: Codable {
        let live: UInt64
        let reserved: UInt64
    }

    private struct PeakPoint {
        let rss: UInt64
        let footprint: UInt64
        let samples: Int
    }

    private struct OperationSnapshot {
        let copiedBytes: Int
        let bodyCallbacks: Int
        let completions: Int
        let handoffs: Int
        let progressUpdates: Int
        let largestProgressWrite: Int
        let temporaryPath: String?
        let failure: Failure?
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
        let mode: SessionMode
        let runLabel: String
        let bytes: Int
        let cycles: Int
        let sha256: String
        let copyBufferBytes: Int
        let baseline: MemoryPoint
        let baselineLiveMalloc: UInt64
        let baselineReservedMalloc: UInt64
        let baselineFDs: Int
        let results: [Cycle]
        let afterSessionClose: MemoryPoint
        let afterSessionCloseLiveMalloc: UInt64
        let afterSessionCloseReservedMalloc: UInt64
        let afterSessionCloseFDs: Int
    }

    private final class OperationLifecycle: @unchecked Sendable {
        let destroyed = DispatchSemaphore(value: 0)
    }

    private final class RouterLifecycle: @unchecked Sendable {
        let invalidated = DispatchSemaphore(value: 0)
        let destroyed = DispatchSemaphore(value: 0)
    }

    private final class PeakObserver: @unchecked Sendable {
        let baseline: MemoryPoint
        private let queue = DispatchQueue(label: "xmltv-b1n-memory-observer")
        private let timer: DispatchSourceTimer
        private var peakRSS: UInt64
        private var peakFootprint: UInt64
        private var samples = 0
        private var stopped = false

        init() {
            let point = XMLTVDownloadSharedSessionTests.memoryPoint()
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
            let point = XMLTVDownloadSharedSessionTests.memoryPoint()
            peakRSS = max(peakRSS, point.rss)
            peakFootprint = max(peakFootprint, point.footprint)
            samples += 1
        }

        func stop() -> PeakPoint {
            queue.sync {
                stopped = true
                timer.cancel()
                let point = XMLTVDownloadSharedSessionTests.memoryPoint()
                peakRSS = max(peakRSS, point.rss)
                peakFootprint = max(peakFootprint, point.footprint)
                samples += 1
                return PeakPoint(rss: peakRSS, footprint: peakFootprint, samples: samples)
            }
        }

        deinit { timer.cancel() }
    }

    private final class DownloadOperation: @unchecked Sendable {
        private static let byteLimit: Int64 = 32 * 1_024 * 1_024
        private static let copyWorker = DispatchQueue(label: "xmltv-b1n-file-copy", qos: .utility)

        let staging: XMLTVStagingFile
        let lifecycle: OperationLifecycle
        let cancelAfterDisposition: Bool
        private let lock = NSLock()
        private var continuation: CheckedContinuation<XMLTVStagedFile, Error>?
        private var originalTask: URLSessionTask?
        private var replacementTask: URLSessionDownloadTask?
        private var unregister: (() -> Void)?
        private var failure: Failure?
        private var terminal = false
        private var accepted = false
        private var copying = false
        private var copied = false
        private var httpCompleted = false
        private var copiedBytes = 0
        private var bodyCallbacks = 0
        private var completions = 0
        private var handoffs = 0
        private var progressUpdates = 0
        private var largestProgressWrite = 0
        private var temporaryPath: String?
        var stagedDirectoryName: String { staging.testReceipt.directoryName }

        init(root: String, lifecycle: OperationLifecycle, cancelAfterDisposition: Bool = false) throws {
            staging = try XMLTVStagingFile.create(in: root)
            self.lifecycle = lifecycle
            self.cancelAfterDisposition = cancelAfterDisposition
        }

        func run(_ url: URL, router: SessionRouter) async throws -> XMLTVStagedFile {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { next in
                    lock.lock()
                    continuation = next
                    lock.unlock()
                    do { try router.start(self, url: url) }
                    catch let issue as Failure { completeWithoutTask(issue) }
                    catch { completeWithoutTask(.file) }
                }
            } onCancel: {
                self.cancel()
            }
        }

        func install(original task: URLSessionTask, unregister: @escaping () -> Void) {
            lock.lock()
            originalTask = task
            self.unregister = unregister
            let stopped = failure != nil || terminal
            lock.unlock()
            if stopped { task.cancel() }
        }

        func install(replacement task: URLSessionDownloadTask) {
            lock.lock()
            replacementTask = task
            let stopped = failure != nil || terminal
            lock.unlock()
            if stopped { task.cancel() }
        }

        func responseDisposition(_ response: URLResponse) -> URLSession.ResponseDisposition {
            do {
                try Self.validate(response)
                lock.lock()
                guard failure == nil, !terminal else { lock.unlock(); return .cancel }
                accepted = true
                lock.unlock()
                return .becomeDownload
            } catch let issue as Failure {
                reject(issue)
                return .cancel
            } catch {
                reject(.response)
                return .cancel
            }
        }

        func receivedBodyData() {
            lock.lock()
            bodyCallbacks += 1
            lock.unlock()
            reject(.bodyCallback)
        }

        func progress(bytesWritten: Int64, total: Int64, expected: Int64) {
            lock.lock()
            progressUpdates += 1
            largestProgressWrite = max(largestProgressWrite, Int(bytesWritten))
            let stopped = failure != nil || terminal
            lock.unlock()
            guard !stopped else { return }
            if total > Self.byteLimit || expected > Self.byteLimit { reject(.length) }
        }

        func downloaded(to location: URL, response: URLResponse?) {
            do {
                try Self.validate(response)
                lock.lock()
                temporaryPath = location.path
                let stopped = failure != nil || terminal
                lock.unlock()
                guard !stopped else { throw Failure.cancelled }

                let descriptor = Darwin.open(location.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw Failure.file }
                var details = stat()
                guard fstat(descriptor, &details) == 0,
                      details.st_mode & S_IFMT == S_IFREG,
                      details.st_size > 0,
                      details.st_size <= Self.byteLimit else {
                    Darwin.close(descriptor)
                    throw Failure.length
                }
                lock.lock()
                copying = true
                lock.unlock()
                Self.copyWorker.async { [self] in
                    copyPinnedFile(descriptor, expectedBytes: Int(details.st_size), response: response)
                }
            } catch let issue as Failure {
                reject(issue)
            } catch {
                reject(.file)
            }
        }

        func completed(_ error: Error?) {
            lock.lock()
            httpCompleted = true
            if error != nil && failure == nil { failure = .network }
            lock.unlock()
            finishIfReady()
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

        func snapshot() -> OperationSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return OperationSnapshot(
                copiedBytes: copiedBytes,
                bodyCallbacks: bodyCallbacks,
                completions: completions,
                handoffs: handoffs,
                progressUpdates: progressUpdates,
                largestProgressWrite: largestProgressWrite,
                temporaryPath: temporaryPath,
                failure: failure
            )
        }

        private static func validate(_ response: URLResponse?) throws {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.value(forHTTPHeaderField: "Content-Range") == nil else {
                throw Failure.response
            }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard encoding == nil || encoding == "identity" else { throw Failure.encoding }
            guard response?.expectedContentLength ?? -1 <= byteLimit else { throw Failure.length }
        }

        private func reject(_ issue: Failure) {
            lock.lock()
            if failure == nil { failure = issue }
            let original = originalTask
            let replacement = replacementTask
            lock.unlock()
            original?.cancel()
            replacement?.cancel()
        }

        private func copyPinnedFile(_ descriptor: Int32, expectedBytes: Int, response: URLResponse?) {
            var issue: Failure?
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            do {
                while true {
                    lock.lock()
                    let stopped = failure != nil || terminal
                    lock.unlock()
                    if stopped { throw Failure.cancelled }
                    let amount = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptor, $0.baseAddress, $0.count)
                    }
                    if amount < 0 {
                        if errno == EINTR { continue }
                        throw Failure.file
                    }
                    if amount == 0 { break }
                    guard total <= Int(Self.byteLimit) - amount else { throw Failure.length }
                    try buffer.withUnsafeBytes {
                        try staging.write(Data(bytes: $0.baseAddress!, count: amount))
                    }
                    total += amount
                }
                guard total == expectedBytes else { throw Failure.length }
                let declared = response?.expectedContentLength ?? -1
                guard declared < 0 || declared == Int64(total) else { throw Failure.length }
            } catch let caught as Failure {
                issue = caught
            } catch is CancellationError {
                issue = .cancelled
            } catch {
                issue = .file
            }
            let closeResult = Darwin.close(descriptor)
            lock.lock()
            copying = false
            copied = issue == nil && closeResult == 0
            copiedBytes = total
            if failure == nil { failure = issue ?? (closeResult == 0 ? nil : .file) }
            lock.unlock()
            finishIfReady()
        }

        private func finishIfReady() {
            lock.lock()
            guard !terminal, httpCompleted, !copying else { lock.unlock(); return }
            var reader: XMLTVStagedFile?
            var issue = failure
            if issue == nil && (!accepted || !copied) { issue = .file }
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
            let remove = unregister
            continuation = nil
            unregister = nil
            originalTask = nil
            replacementTask = nil
            lock.unlock()

            remove?()
            if let reader { next?.resume(returning: reader) }
            else {
                do { try staging.release() } catch { XCTFail("B1-N staging cleanup failed") }
                next?.resume(throwing: issue ?? .file)
            }
        }

        private func completeWithoutTask(_ issue: Failure) {
            lock.lock()
            guard !terminal else { lock.unlock(); return }
            terminal = true
            failure = issue
            completions += 1
            let next = continuation
            continuation = nil
            lock.unlock()
            do { try staging.release() } catch { XCTFail("B1-N setup cleanup failed") }
            next?.resume(throwing: issue)
        }

        deinit { lifecycle.destroyed.signal() }
    }

    private final class SessionRouter: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
        let lifecycle: RouterLifecycle
        private let lock = NSLock()
        private var session: URLSession!
        private var accepting = true
        private var operations: [Int: DownloadOperation] = [:]

        init(lifecycle: RouterLifecycle) {
            self.lifecycle = lifecycle
            super.init()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 90
            let queue = OperationQueue()
            queue.name = "xmltv-b1n-url-session"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .utility
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        }

        func start(_ operation: DownloadOperation, url: URL) throws {
            guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
                  url.user == nil, url.password == nil else { throw Failure.response }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let task = session.dataTask(with: request)
            lock.lock()
            guard accepting else { lock.unlock(); throw Failure.closed }
            operations[task.taskIdentifier] = operation
            lock.unlock()
            operation.install(original: task) { [weak self, weak operation] in
                guard let operation else { return }
                self?.unregister(operation)
            }
            task.resume()
        }

        func close() throws {
            lock.lock()
            accepting = false
            let empty = operations.isEmpty
            lock.unlock()
            guard empty else { throw Failure.closed }
            session.finishTasksAndInvalidate()
            guard lifecycle.invalidated.wait(timeout: .now() + 15) == .success else { throw Failure.closed }
            session = nil
        }

        private func operation(for task: URLSessionTask) -> DownloadOperation? {
            lock.lock()
            defer { lock.unlock() }
            return operations[task.taskIdentifier]
        }

        private func unregister(_ operation: DownloadOperation) {
            lock.lock()
            operations = operations.filter { $0.value !== operation }
            lock.unlock()
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let operation = operation(for: dataTask) else {
                completionHandler(.cancel)
                return
            }
            let disposition = operation.responseDisposition(response)
            completionHandler(disposition)
            if disposition == .becomeDownload, operation.cancelAfterDisposition { operation.cancel() }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didBecome downloadTask: URLSessionDownloadTask
        ) {
            guard let operation = operation(for: dataTask) else {
                downloadTask.cancel()
                return
            }
            lock.lock()
            operations[downloadTask.taskIdentifier] = operation
            lock.unlock()
            operation.install(replacement: downloadTask)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            operation(for: dataTask)?.receivedBodyData()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            operation(for: downloadTask)?.progress(
                bytesWritten: bytesWritten,
                total: totalBytesWritten,
                expected: totalBytesExpectedToWrite
            )
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            operation(for: task)?.cancel()
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            operation(for: downloadTask)?.downloaded(to: location, response: downloadTask.response)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            operation(for: task)?.completed(error)
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
        precondition(status == KERN_SUCCESS)
        return MemoryPoint(rss: info.resident_size, footprint: info.phys_footprint)
    }

    private static func mallocPoint() -> MallocPoint {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return MallocPoint(live: UInt64(statistics.size_in_use), reserved: UInt64(statistics.size_allocated))
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

    private func waitUntilAbsent(_ path: String) -> Bool {
        for _ in 0..<100 {
            var details = stat()
            if lstat(path, &details) == -1, errno == ENOENT { return true }
            usleep(10_000)
        }
        return false
    }

    private func makeRouter() -> (SessionRouter, RouterLifecycle) {
        let lifecycle = RouterLifecycle()
        return (SessionRouter(lifecycle: lifecycle), lifecycle)
    }

    private func invalidate(_ router: inout SessionRouter?) throws {
        guard let current = router else { throw Failure.closed }
        try current.close()
        router = nil
    }

    private func exercise(
        fixture: XMLTVStagingFileTests.Fixture,
        url: URL,
        sharedRouter: SessionRouter? = nil,
        cancelAfterDisposition: Bool = false
    ) async throws -> ExerciseResult {
        var ownedRouter: SessionRouter?
        var ownedLifecycle: RouterLifecycle?
        if let sharedRouter {
            _ = sharedRouter
        } else {
            let created = makeRouter()
            ownedRouter = created.0
            ownedLifecycle = created.1
        }

        let lifecycle = OperationLifecycle()
        var operation: DownloadOperation? = try DownloadOperation(
            root: fixture.path,
            lifecycle: lifecycle,
            cancelAfterDisposition: cancelAfterDisposition
        )
        let child = operation!.stagedDirectoryName
        do {
            let reader = try await operation!.run(url, router: sharedRouter ?? ownedRouter!)
            var digest = SHA256()
            var bytes = 0
            while true {
                let data = try reader.read()
                if data.isEmpty { break }
                digest.update(data: data)
                bytes += data.count
            }
            operation!.cancel()
            XCTAssertTrue(try reader.read().isEmpty)
            try reader.release()
            let snapshot = operation!.snapshot()
            XCTAssertEqual(snapshot.bodyCallbacks, 0)
            XCTAssertEqual(snapshot.completions, 1)
            XCTAssertEqual(snapshot.handoffs, 1)
            operation = nil
            XCTAssertEqual(lifecycle.destroyed.wait(timeout: .now() + 10), .success)
            assertAbsent(fixture.path + "/" + child)
            guard let temporaryPath = snapshot.temporaryPath,
                  waitUntilAbsent(temporaryPath) else { throw Failure.file }
            if ownedRouter != nil {
                try invalidate(&ownedRouter)
                XCTAssertEqual(ownedLifecycle!.destroyed.wait(timeout: .now() + 10), .success)
            }
            return ExerciseResult(
                copiedBytes: snapshot.copiedBytes,
                sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                progressUpdates: snapshot.progressUpdates,
                largestProgressWrite: snapshot.largestProgressWrite,
                foundationTemporaryFileRemoved: true
            )
        } catch {
            let snapshot = operation!.snapshot()
            operation = nil
            XCTAssertEqual(lifecycle.destroyed.wait(timeout: .now() + 10), .success)
            assertAbsent(fixture.path + "/" + child)
            if let temporaryPath = snapshot.temporaryPath { XCTAssertTrue(waitUntilAbsent(temporaryPath)) }
            if ownedRouter != nil {
                try invalidate(&ownedRouter)
                XCTAssertEqual(ownedLifecycle!.destroyed.wait(timeout: .now() + 10), .success)
            }
            throw error
        }
    }

    private func port() throws -> Int {
        guard let port = Int(ProcessInfo.processInfo.environment["OKVIDEO_B1N_PORT"] ?? ""),
              (1...65_535).contains(port) else { throw XCTSkip("Explicit B1-N loopback only") }
        return port
    }

    private func runIsolation(
        router: SessionRouter,
        fixture: XMLTVStagingFileTests.Fixture,
        port: Int
    ) async throws {
        async let cancelled: ExerciseResult = exercise(
            fixture: fixture,
            url: URL(string: "http://127.0.0.1:\(port)/bytes/33554432")!,
            sharedRouter: router,
            cancelAfterDisposition: true
        )
        async let successful: ExerciseResult = exercise(
            fixture: fixture,
            url: URL(string: "http://127.0.0.1:\(port)/bytes/1048576")!,
            sharedRouter: router
        )
        do {
            _ = try await cancelled
            XCTFail("Cancelled operation unexpectedly transferred ownership")
        } catch let issue as Failure {
            XCTAssertEqual(issue, .cancelled)
        }
        let result = try await successful
        XCTAssertEqual(result.copiedBytes, 1_048_576)
    }

    func testSharedRouterIsolatesCancelledOperation() async throws {
        let port = try port()
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("B1-N fixture cleanup failed") } }
        var pair: SessionRouter? = makeRouter().0
        let routerLifecycle = pair!.lifecycle
        try await runIsolation(router: pair!, fixture: fixture, port: port)
        try invalidate(&pair)
        XCTAssertEqual(routerLifecycle.destroyed.wait(timeout: .now() + 10), .success)
    }

    func testConvertedSessionReuseMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = SessionMode(rawValue: environment["OKVIDEO_B1N_MODE"] ?? ""),
              let expectedBytes = Int(environment["OKVIDEO_B1N_BYTES"] ?? ""),
              let cycles = Int(environment["OKVIDEO_B1N_CYCLES"] ?? ""),
              let expectedSHA = environment["OKVIDEO_B1N_SHA"],
              let runLabel = environment["OKVIDEO_B1N_RUN"] else {
            throw XCTSkip("Explicit B1-N memory experiment only")
        }
        let port = try port()
        guard expectedBytes == 32 * 1_024 * 1_024, cycles == 8, !runLabel.isEmpty else {
            throw Failure.response
        }
        let fixture = try XMLTVStagingFileTests.Fixture()
        defer { do { try fixture.clean() } catch { XCTFail("B1-N fixture cleanup failed") } }
        func url(_ bytes: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/bytes/\(bytes)")! }

        var sharedRouter: SessionRouter?
        var sharedLifecycle: RouterLifecycle?
        if mode == .sharedSession {
            let created = makeRouter()
            sharedRouter = created.0
            sharedLifecycle = created.1
        }
        let warmup = try await exercise(fixture: fixture, url: url(65_536), sharedRouter: sharedRouter)
        XCTAssertEqual(warmup.copiedBytes, 65_536)
        try await Task.sleep(nanoseconds: 250_000_000)

        let baseline = Self.memoryPoint()
        let baselineMalloc = Self.mallocPoint()
        let baselineFDs = Self.openFDCount()
        XCTAssertGreaterThanOrEqual(baselineFDs, 0)
        var rows: [Cycle] = []
        rows.reserveCapacity(cycles)
        for index in 1...cycles {
            let observer = PeakObserver()
            let began = DispatchTime.now().uptimeNanoseconds
            let result = try await exercise(fixture: fixture, url: url(expectedBytes), sharedRouter: sharedRouter)
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
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
                seconds: seconds,
                peakRSSDeltaMiB: Double(peak.rss > observer.baseline.rss ? peak.rss - observer.baseline.rss : 0) / 1_048_576,
                peakFootprintDeltaMiB: Double(peak.footprint > observer.baseline.footprint ? peak.footprint - observer.baseline.footprint : 0) / 1_048_576,
                settledRSS: settled.rss,
                settledFootprint: settled.footprint,
                settledLiveMalloc: settledMalloc.live,
                settledReservedMalloc: settledMalloc.reserved,
                openFDs: fds,
                foundationTemporaryFileRemoved: result.foundationTemporaryFileRemoved
            ))
        }

        if sharedRouter != nil {
            try invalidate(&sharedRouter)
            XCTAssertEqual(sharedLifecycle!.destroyed.wait(timeout: .now() + 10), .success)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let afterClose = Self.memoryPoint()
        let afterCloseMalloc = Self.mallocPoint()
        let afterCloseFDs = Self.openFDCount()
        let report = Report(
            protocolVersion: 1,
            mode: mode,
            runLabel: runLabel,
            bytes: expectedBytes,
            cycles: cycles,
            sha256: expectedSHA,
            copyBufferBytes: 65_536,
            baseline: baseline,
            baselineLiveMalloc: baselineMalloc.live,
            baselineReservedMalloc: baselineMalloc.reserved,
            baselineFDs: baselineFDs,
            results: rows,
            afterSessionClose: afterClose,
            afterSessionCloseLiveMalloc: afterCloseMalloc.live,
            afterSessionCloseReservedMalloc: afterCloseMalloc.reserved,
            afterSessionCloseFDs: afterCloseFDs
        )
        print("B1N_MEMORY " + String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
    }
}
