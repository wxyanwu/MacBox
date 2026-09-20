import Darwin
import Foundation

/// Errors from the bounded XMLTV download bridge deliberately exclude URLs,
/// headers and transport messages so diagnostics cannot expose provider secrets.
@_spi(XMLTVStreaming) public enum XMLTVDownloadError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case statusCode(Int)
    case partialContent
    case unsupportedContentEncoding
    case declaredSizeLimit(limit: Int64, declared: Int64)
    case observedSizeLimit(limit: Int64, observed: Int64)
    case emptyBody
    case lengthMismatch(expected: Int64, actual: Int64)
    case redirectRejected
    case tooManyRedirects(Int)
    case timeout
    case transport
    case cancelled
    case temporaryFile
    case staging(XMLTVFileError)
}

@_spi(XMLTVStreaming) public struct XMLTVDownloadRequest: Sendable {
    public let url: URL
    public let headers: HTTPHeaders
    public let timeout: TimeInterval
    public let resourceTimeout: TimeInterval
    public let maximumRedirects: Int

    public init(
        url: URL,
        headers: HTTPHeaders = [:],
        timeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 120,
        maximumRedirects: Int = 5
    ) {
        self.url = url
        self.headers = headers
        self.timeout = timeout
        self.resourceTimeout = resourceTimeout
        self.maximumRedirects = maximumRedirects
    }
}

@_spi(XMLTVStreaming) public struct XMLTVDownloadMetrics: Equatable, Sendable {
    public let downloadedBytes: Int
    public let observedBytes: Int64
    public let progressUpdateCount: Int
    public let largestProgressIncrement: Int64
    public let redirectCount: Int
}

/// A single-use ownership token. Parsing or explicit release consumes it.
/// No Foundation temporary path or file descriptor escapes this boundary.
@_spi(XMLTVStreaming) public final class XMLTVDownloadedFile: @unchecked Sendable {
    public let metrics: XMLTVDownloadMetrics
    public let contentType: String?
    private let lock = NSLock()
    private var stagedFile: XMLTVStagedFile?

    init(
        stagedFile: XMLTVStagedFile,
        metrics: XMLTVDownloadMetrics,
        contentType: String?
    ) {
        self.stagedFile = stagedFile
        self.metrics = metrics
        self.contentType = contentType
    }

    func takeFile() throws -> XMLTVStagedFile {
        lock.lock()
        defer { lock.unlock() }
        guard let value = stagedFile else { throw XMLTVDownloadError.temporaryFile }
        stagedFile = nil
        return value
    }

    public func release() throws {
        let value: XMLTVStagedFile?
        lock.lock()
        value = stagedFile
        stagedFile = nil
        lock.unlock()
        try value?.release()
    }

    deinit { try? release() }
}

/// Single-purpose download-to-file transport for the staged 9B.3 pipeline.
/// It is intentionally separate from the buffered HTTPClient used elsewhere.
@_spi(XMLTVStreaming) public final class XMLTVDownloader: @unchecked Sendable {
    public static let maximumSupportedBytes = 32 * 1_024 * 1_024

    private let stagingRootPath: String
    private let maximumBytes: Int
    private let baseConfiguration: URLSessionConfiguration
    private var temporaryByteObserver: ((Int64) -> Void)?
    // Fixed before use by isolated tests; exercises the final copy/join path.
    var stagingWriteForTesting: XMLTVWriteOperation?

    public convenience init(
        stagingRootPath: String,
        maximumBytes: Int = XMLTVDownloader.maximumSupportedBytes,
        temporaryByteObserver: ((Int64) -> Void)? = nil
    ) {
        self.init(
            stagingRootPath: stagingRootPath,
            maximumBytes: maximumBytes,
            configuration: .ephemeral
        )
        self.temporaryByteObserver = temporaryByteObserver
    }

    init(
        stagingRootPath: String,
        maximumBytes: Int,
        configuration: URLSessionConfiguration
    ) {
        self.stagingRootPath = stagingRootPath
        self.maximumBytes = maximumBytes
        self.baseConfiguration = configuration
    }

    public func download(_ request: XMLTVDownloadRequest) async throws -> XMLTVDownloadedFile {
        guard maximumBytes > 0, maximumBytes <= Self.maximumSupportedBytes,
              request.timeout > 0, request.resourceTimeout > 0,
              request.maximumRedirects >= 0,
              ["http", "https"].contains(request.url.scheme?.lowercased() ?? ""),
              request.url.host != nil, request.url.user == nil, request.url.password == nil else {
            throw XMLTVDownloadError.invalidRequest
        }
        let staging: XMLTVStagingFile
        do {
            if let write = stagingWriteForTesting {
                staging = try XMLTVStagingFile.create(in: stagingRootPath, maximumBytes: maximumBytes, write: write)
            } else {
                staging = try XMLTVStagingFile.create(in: stagingRootPath, maximumBytes: maximumBytes)
            }
        } catch let error as XMLTVFileError {
            throw XMLTVDownloadError.staging(error)
        }
        let operation = XMLTVDownloadOperation(
            request: request,
            maximumBytes: maximumBytes,
            staging: staging,
            configuration: baseConfiguration,
            temporaryByteObserver: temporaryByteObserver
        )
        return try await operation.run()
    }

    public func recoverStaleFiles() throws -> XMLTVRecoveryResult {
        try XMLTVStagingFile.recoverStale(in: stagingRootPath)
    }
}

struct XMLTVDownloadAdmission: Equatable {
    let expectedBytes: Int64?
    let contentType: String?

    static func validate(
        _ response: URLResponse?,
        maximumBytes: Int64
    ) throws -> XMLTVDownloadAdmission {
        guard maximumBytes > 0, let http = response as? HTTPURLResponse else {
            throw XMLTVDownloadError.invalidResponse
        }
        guard http.statusCode == 200 else { throw XMLTVDownloadError.statusCode(http.statusCode) }
        guard http.value(forHTTPHeaderField: "Content-Range") == nil else {
            throw XMLTVDownloadError.partialContent
        }
        if let rawEncoding = http.value(forHTTPHeaderField: "Content-Encoding") {
            let encoding = rawEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard encoding == "identity" else {
                throw XMLTVDownloadError.unsupportedContentEncoding
            }
        }

        var expected: Int64?
        if let rawLength = http.value(forHTTPHeaderField: "Content-Length") {
            let value = rawLength.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int64(value) else {
                throw XMLTVDownloadError.invalidResponse
            }
            expected = parsed
        } else if response?.expectedContentLength ?? -1 >= 0 {
            expected = response?.expectedContentLength
        }
        if let expected, expected > maximumBytes {
            throw XMLTVDownloadError.declaredSizeLimit(limit: maximumBytes, declared: expected)
        }
        return XMLTVDownloadAdmission(
            expectedBytes: expected,
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        )
    }
}

private final class XMLTVDownloadOperation: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable {
    private enum CopyState {
        case waiting
        case running
        case succeeded(Int)
        case failed(XMLTVDownloadError)
    }

    private struct Completion {
        let result: Result<(Int, XMLTVDownloadMetrics, String?), XMLTVDownloadError>
        let continuation: CheckedContinuation<XMLTVDownloadedFile, Error>
        let session: URLSession
    }

    private let request: XMLTVDownloadRequest
    private let maximumBytes: Int64
    private let staging: XMLTVStagingFile
    private let configuration: URLSessionConfiguration
    private let temporaryByteObserver: ((Int64) -> Void)?
    private let lock = NSLock()
    private let copyQueue = DispatchQueue(label: "com.okvideomac.xmltv.download-copy", qos: .utility)

    private var continuation: CheckedContinuation<XMLTVDownloadedFile, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var terminal = false
    private var cancellationRequested = false
    private var firstFailure: XMLTVDownloadError?
    private var httpCompleted = false
    private var copyState = CopyState.waiting
    private var admission: XMLTVDownloadAdmission?
    private var progressUpdates = 0
    private var largestProgressIncrement: Int64 = 0
    private var observedBytes: Int64 = 0
    private var redirectCount = 0

    init(
        request: XMLTVDownloadRequest,
        maximumBytes: Int,
        staging: XMLTVStagingFile,
        configuration: URLSessionConfiguration,
        temporaryByteObserver: ((Int64) -> Void)?
    ) {
        self.request = request
        self.maximumBytes = Int64(maximumBytes)
        self.staging = staging
        self.configuration = configuration.copy() as? URLSessionConfiguration ?? configuration
        self.temporaryByteObserver = temporaryByteObserver
    }

    func run() async throws -> XMLTVDownloadedFile {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { next in
                let config = configuration
                config.httpShouldSetCookies = false
                config.httpCookieAcceptPolicy = .never
                config.httpCookieStorage = nil
                config.urlCache = nil
                config.urlCredentialStorage = nil
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = request.timeout
                config.timeoutIntervalForResource = request.resourceTimeout

                let queue = OperationQueue()
                queue.name = "com.okvideomac.xmltv.download-delegate"
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .utility
                let createdSession = URLSession(
                    configuration: config,
                    delegate: self,
                    delegateQueue: queue
                )
                var urlRequest = URLRequest(url: request.url)
                urlRequest.httpMethod = "GET"
                urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
                for (field, value) in request.headers.dictionary {
                    urlRequest.setValue(value, forHTTPHeaderField: field)
                }
                urlRequest.setValue(nil, forHTTPHeaderField: "Range")
                urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let createdTask = createdSession.downloadTask(with: urlRequest)

                lock.lock()
                continuation = next
                session = createdSession
                task = createdTask
                let cancelled = cancellationRequested
                let completion = evaluateLocked()
                lock.unlock()

                if cancelled { createdTask.cancel() } else { createdTask.resume() }
                perform(completion)
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        cancellationRequested = true
        if firstFailure == nil { firstFailure = .cancelled }
        let currentTask = task
        let completion = evaluateLocked()
        lock.unlock()
        staging.requestCancellation()
        currentTask?.cancel()
        perform(completion)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        var failure: XMLTVDownloadError?
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        progressUpdates += 1
        largestProgressIncrement = max(largestProgressIncrement, bytesWritten)
        observedBytes = max(observedBytes, totalBytesWritten)
        if totalBytesWritten > maximumBytes {
            failure = .observedSizeLimit(limit: maximumBytes, observed: totalBytesWritten)
        } else if totalBytesExpectedToWrite > maximumBytes {
            failure = .declaredSizeLimit(limit: maximumBytes, declared: totalBytesExpectedToWrite)
        } else if admission == nil, downloadTask.response != nil {
            do { admission = try XMLTVDownloadAdmission.validate(downloadTask.response, maximumBytes: maximumBytes) }
            catch let error as XMLTVDownloadError { failure = error }
            catch { failure = .invalidResponse }
        }
        if let failure, firstFailure == nil { firstFailure = failure }
        let completion = evaluateLocked()
        lock.unlock()
        temporaryByteObserver?(totalBytesWritten)
        if failure != nil {
            staging.requestCancellation()
            downloadTask.cancel()
        }
        perform(completion)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let validated: XMLTVDownloadAdmission
        do {
            validated = try XMLTVDownloadAdmission.validate(
                downloadTask.response,
                maximumBytes: maximumBytes
            )
        } catch let error as XMLTVDownloadError {
            fail(error, cancelling: downloadTask)
            return
        } catch {
            fail(.invalidResponse, cancelling: downloadTask)
            return
        }

        // Foundation owns and may unlink the path when this callback returns.
        // Pin the inode now; all blocking reads happen later on copyQueue.
        let descriptor = Darwin.open(location.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { fail(.temporaryFile, cancelling: downloadTask); return }
        var details = stat()
        guard fstat(descriptor, &details) == 0,
              details.st_mode & S_IFMT == S_IFREG,
              details.st_uid == geteuid(), details.st_size >= 0 else {
            Darwin.close(descriptor)
            fail(.temporaryFile, cancelling: downloadTask)
            return
        }
        let actual = Int64(details.st_size)
        guard actual > 0 else {
            Darwin.close(descriptor)
            fail(.emptyBody, cancelling: downloadTask)
            return
        }
        guard actual <= maximumBytes else {
            Darwin.close(descriptor)
            fail(.observedSizeLimit(limit: maximumBytes, observed: actual), cancelling: downloadTask)
            return
        }
        if let expected = validated.expectedBytes, expected != actual {
            Darwin.close(descriptor)
            fail(.lengthMismatch(expected: expected, actual: actual), cancelling: downloadTask)
            return
        }

        lock.lock()
        guard !terminal, firstFailure == nil, !cancellationRequested,
              case .waiting = copyState else {
            lock.unlock()
            Darwin.close(descriptor)
            return
        }
        admission = validated
        observedBytes = max(observedBytes, actual)
        copyState = .running
        lock.unlock()

        copyQueue.async { [self] in
            let result = copyPinnedFile(descriptor, expectedBytes: actual)
            copyFinished(result)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let count = redirectCount
        lock.unlock()
        guard count <= self.request.maximumRedirects else {
            completionHandler(nil)
            fail(.tooManyRedirects(self.request.maximumRedirects), cancelling: task)
            return
        }
        guard HTTPRedirectSecurity.isAllowed(
            request.url,
            from: response.url,
            policy: .noDowngrade
        ) else {
            completionHandler(nil)
            fail(.redirectRejected, cancelling: task)
            return
        }
        var headers = self.request.headers
        headers["Accept-Encoding"] = "identity"
        headers["Range"] = nil
        completionHandler(HTTPRedirectSecurity.preparedRequest(
            request,
            originalURL: task.originalRequest?.url,
            redirectedHeaders: headers
        ))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        if let error, firstFailure == nil {
            if cancellationRequested {
                firstFailure = .cancelled
            } else if (error as? URLError)?.code == .timedOut {
                firstFailure = .timeout
            } else {
                firstFailure = .transport
            }
        }
        httpCompleted = true
        let completion = evaluateLocked()
        lock.unlock()
        if error != nil { staging.requestCancellation() }
        perform(completion)
    }

    private func copyPinnedFile(
        _ descriptor: Int32,
        expectedBytes: Int64
    ) -> Result<Int, XMLTVDownloadError> {
        temporaryByteObserver?(expectedBytes)
        defer { Darwin.close(descriptor); temporaryByteObserver?(0) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total = 0
        do {
            while true {
                lock.lock()
                let stop = cancellationRequested || firstFailure != nil || terminal
                lock.unlock()
                if stop { throw CancellationError() }
                let amount = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress!, $0.count)
                }
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw XMLTVDownloadError.temporaryFile
                }
                if amount == 0 { break }
                guard total <= Int(maximumBytes) - amount else {
                    throw XMLTVDownloadError.observedSizeLimit(
                        limit: maximumBytes,
                        observed: Int64(total + amount)
                    )
                }
                try staging.write(Data(bytes: buffer, count: amount))
                total += amount
            }
            guard Int64(total) == expectedBytes else {
                throw XMLTVDownloadError.lengthMismatch(
                    expected: expectedBytes,
                    actual: Int64(total)
                )
            }
            return .success(total)
        } catch let error as XMLTVDownloadError {
            return .failure(error)
        } catch let error as XMLTVFileError {
            return .failure(.staging(error))
        } catch let error as POSIXError {
            return .failure(.staging(.system(error.code.rawValue)))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.temporaryFile)
        }
    }

    private func copyFinished(_ result: Result<Int, XMLTVDownloadError>) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        switch result {
        case .success(let count): copyState = .succeeded(count)
        case .failure(let error):
            copyState = .failed(error)
            if firstFailure == nil { firstFailure = error }
        }
        let completion = evaluateLocked()
        lock.unlock()
        perform(completion)
    }

    private func fail(_ error: XMLTVDownloadError, cancelling task: URLSessionTask) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        if firstFailure == nil { firstFailure = error }
        let completion = evaluateLocked()
        lock.unlock()
        staging.requestCancellation()
        task.cancel()
        perform(completion)
    }

    /// Must be called with lock held. A running copy owns the pinned descriptor,
    /// so even failure waits for that worker to close it before cleanup resumes.
    private func evaluateLocked() -> Completion? {
        guard !terminal, let continuation, let session else { return nil }
        if case .running = copyState { return nil }

        let result: Result<(Int, XMLTVDownloadMetrics, String?), XMLTVDownloadError>
        if let failure = firstFailure {
            result = .failure(failure)
        } else {
            guard httpCompleted else { return nil }
            switch copyState {
            case .succeeded(let count):
                let metrics = XMLTVDownloadMetrics(
                    downloadedBytes: count,
                    observedBytes: observedBytes,
                    progressUpdateCount: progressUpdates,
                    largestProgressIncrement: largestProgressIncrement,
                    redirectCount: redirectCount
                )
                result = .success((count, metrics, admission?.contentType))
            case .waiting, .failed:
                result = .failure(.temporaryFile)
            case .running:
                return nil
            }
        }
        terminal = true
        self.continuation = nil
        self.session = nil
        task = nil
        return Completion(result: result, continuation: continuation, session: session)
    }

    private func perform(_ completion: Completion?) {
        guard let completion else { return }
        switch completion.result {
        case .success((_, let metrics, let contentType)):
            do {
                let reader = try staging.finishAndTransfer()
                completion.session.finishTasksAndInvalidate()
                completion.continuation.resume(returning: XMLTVDownloadedFile(
                    stagedFile: reader,
                    metrics: metrics,
                    contentType: contentType
                ))
            } catch let error as XMLTVFileError {
                try? staging.release()
                completion.session.invalidateAndCancel()
                completion.continuation.resume(throwing: XMLTVDownloadError.staging(error))
            } catch {
                try? staging.release()
                completion.session.invalidateAndCancel()
                completion.continuation.resume(throwing: XMLTVDownloadError.temporaryFile)
            }
        case .failure(let error):
            try? staging.release()
            completion.session.invalidateAndCancel()
            completion.continuation.resume(throwing: error)
        }
    }
}
