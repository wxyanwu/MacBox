import Foundation

/// Reachability only, not playback validation. No player state, shared cookies,
/// payload persistence or general HTTP client behavior is changed.
public struct BoundedLiveStreamProber: LiveStreamProbing {
    private let configuration: URLSessionConfiguration
    private let byteLimit: Int
    private let deadline: TimeInterval
    public init() {
        self.init(configuration: .ephemeral, byteLimit: 1024, deadline: 7)
    }
    init(configuration: URLSessionConfiguration, byteLimit: Int, deadline: TimeInterval) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.byteLimit = max(1, byteLimit); self.deadline = max(0.01, deadline)
    }
    public func probe(_ stream: LiveStream) async -> LiveStreamProbeResult {
        guard case .direct(let url) = stream.target, !stream.needsParsing else { return .inconclusive }
        if url.isFileURL { return FileManager.default.fileExists(atPath: url.path) ? .reachable : .definitivelyUnavailable }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .inconclusive }
        var request = URLRequest(url: url)
        request.timeoutInterval = min(6, deadline)
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-\(byteLimit - 1)", forHTTPHeaderField: "Range")
        return await ProbeLoad(configuration: configuration, byteLimit: byteLimit, deadline: deadline).load(request)
    }
}

private final class ProbeLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let byteLimit: Int
    private let deadline: TimeInterval
    private var continuation: CheckedContinuation<LiveStreamProbeResult, Never>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadlineWork: DispatchWorkItem?
    private var finished = false
    private var cancelled = false
    private var status: Int?
    private var bytes = 0
    private var redirects = 0
    init(configuration: URLSessionConfiguration, byteLimit: Int, deadline: TimeInterval) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.byteLimit = byteLimit; self.deadline = deadline
        self.configuration.httpShouldSetCookies = false
        self.configuration.httpCookieStorage = nil
        self.configuration.urlCredentialStorage = nil
        self.configuration.urlCache = nil
        self.configuration.timeoutIntervalForResource = deadline
        self.configuration.timeoutIntervalForRequest = min(6, deadline)
    }
    func load(_ request: URLRequest) async -> LiveStreamProbeResult {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                let work = DispatchWorkItem { [weak self] in self?.finish(.inconclusive) }
                deadlineWork = work
                let stop = cancelled || Task.isCancelled
                lock.unlock()
                if stop { finish(.inconclusive) }
                else {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline, execute: work)
                    task.resume()
                }
            }
        }, onCancel: {
            self.lock.lock(); self.cancelled = true
            let started = self.continuation != nil; self.lock.unlock()
            if started { self.finish(.inconclusive) }
        })
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.inconclusive); completionHandler(.cancel); return
        }
        lock.lock(); status = http.statusCode; let stop = finished; lock.unlock()
        let outcome = LiveSourceValidationPolicy.result(forHTTPStatus: http.statusCode)
        // Error responses do not need their bodies downloaded. Success requires
        // a valid HTTP response followed by a finite sample or normal EOF.
        if stop || outcome != .reachable {
            // Fix the outcome before URLSession emits its cancellation error.
            finish(outcome); completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bytes += min(data.count, byteLimit - bytes)
        let complete = bytes >= byteLimit
        let code = status
        lock.unlock()
        if complete { finish(code.map(LiveSourceValidationPolicy.result) ?? .inconclusive) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let code = status; lock.unlock()
        finish(error == nil ? code.map(LiveSourceValidationPolicy.result) ?? .inconclusive : .inconclusive)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let count = redirects; lock.unlock()
        guard count <= 10, HTTPRedirectSecurity.isAllowed(request.url, from: response.url, policy: .noDowngrade) else {
            finish(.inconclusive); completionHandler(nil); return
        }
        completionHandler(HTTPRedirectSecurity.preparedRequest(request, originalURL: task.originalRequest?.url, redirectedHeaders: HTTPHeaders()))
    }
    private func finish(_ result: LiveStreamProbeResult) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        let task = self.task; self.task = nil
        let session = self.session; self.session = nil
        let work = deadlineWork; deadlineWork = nil
        let result = cancelled ? LiveStreamProbeResult.inconclusive : result
        lock.unlock()
        work?.cancel(); task?.cancel(); session?.invalidateAndCancel()
        continuation?.resume(returning: result)
    }
}
