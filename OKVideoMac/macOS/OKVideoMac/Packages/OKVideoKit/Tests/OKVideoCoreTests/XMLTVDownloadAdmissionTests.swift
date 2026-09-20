import Foundation
import XCTest
import Darwin
import CryptoKit
@_spi(XMLTVStreaming) @testable import OKVideoCore

/// B1 only. No production callers. Coding observation is explicitly loopback-only.
final class XMLTVDownloadAdmissionTests: XCTestCase {
    private enum Failure: String, Error { case cancelled, response, coding, length, network, file, bodyCallback }
    private enum CancelAt: String { case none, beforeDisposition, conversionWindow, afterReplacement }
    private final class Life: @unchecked Sendable {
        let invalidated = DispatchSemaphore(value: 0), destroyed = DispatchSemaphore(value: 0)
    }
    private final class Probe: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
        let staging: XMLTVStagingFile, life: Life
        let observeCoding: Bool, cancelAt: CancelAt
        let lock = NSLock(), worker = DispatchQueue(label: "xmltv-b1-file-copy")
        var session: URLSession?, original: URLSessionDataTask?, replacement: URLSessionDownloadTask?
        var continuation: CheckedContinuation<XMLTVStagedFile, Error>?
        var error: Failure?, terminal = false, copying = false, copied = false, httpDone = false
        var accepted = false, events: [String] = [], encoding = "absent", declared: Int64 = -1
        var copiedBytes = 0, bodyCallbacks = 0, completions = 0, handoffs = 0
        var temporaryPath: String?

        init(root: String, life: Life, observeCoding: Bool = false, cancelAt: CancelAt = .none) throws {
            staging = try .create(in: root); self.life = life
            self.observeCoding = observeCoding; self.cancelAt = cancelAt
        }
        func run(_ url: URL) async throws -> XMLTVStagedFile {
            guard url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
                  url.user == nil, url.password == nil else { try staging.release(); throw Failure.response }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { next in
                    let config = URLSessionConfiguration.ephemeral
                    config.httpShouldSetCookies = false; config.httpCookieStorage = nil
                    config.httpCookieAcceptPolicy = .never; config.urlCache = nil
                    config.urlCredentialStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
                    config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 30
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    let s = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                    var request = URLRequest(url: url)
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let t = s.dataTask(with: request)
                    lock.lock(); session = s; original = t; continuation = next
                    let stop = error != nil; lock.unlock()
                    t.resume(); if stop { t.cancel() }
                }
            } onCancel: { self.cancel() }
        }
        func cancel() {
            lock.lock()
            guard !terminal else { lock.unlock(); return }
            error = .cancelled; events.append("cancel")
            let a = original, b = replacement
            lock.unlock()
            staging.requestCancellation(); a?.cancel(); b?.cancel()
        }
        private func reject(_ failure: Failure) {
            lock.lock(); if error == nil { error = failure }
            let a = original, b = replacement; lock.unlock()
            a?.cancel(); b?.cancel()
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let h = response as? HTTPURLResponse
            let code = h?.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            lock.lock(); encoding = code ?? "absent"; declared = response.expectedContentLength
            events.append("response"); let stopped = error != nil; lock.unlock()
            let failure: Failure?
            if stopped { failure = .cancelled }
            else if h?.statusCode != 200 || h?.value(forHTTPHeaderField: "Content-Range") != nil { failure = .response }
            else if !observeCoding && code != nil && code != "identity" { failure = .coding }
            else if response.expectedContentLength > 33_554_432 { failure = .length }
            else { failure = nil }
            if let failure { reject(failure); completionHandler(.cancel); return }
            if cancelAt == .beforeDisposition { cancel(); completionHandler(.cancel); return }
            lock.lock(); accepted = true; events.append("becomeDownloadIssued"); lock.unlock()
            completionHandler(.becomeDownload)
            // Serial delegate queue guarantees didBecome cannot execute while
            // this response callback is still running. No timing sleep needed.
            if cancelAt == .conversionWindow { cancel() }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didBecome downloadTask: URLSessionDownloadTask) {
            lock.lock(); replacement = downloadTask; events.append("replacementInstalled")
            let stopped = error != nil; lock.unlock()
            if stopped { downloadTask.cancel() }
            if cancelAt == .afterReplacement { cancel() }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock(); bodyCallbacks += 1; lock.unlock(); reject(.bodyCallback)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > 33_554_432 { reject(.length) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            reject(.response); completionHandler(nil)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            lock.lock(); temporaryPath = location.path
            let stopped = error != nil || terminal; lock.unlock()
            guard !stopped else { return }
            let fd = open(location.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { reject(.file); return }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= 33_554_432 else { close(fd); reject(.length); return }
            lock.lock(); copying = true; events.append("fdPinned"); lock.unlock()
            // Worker owns this fd from dispatch onward. Foundation owns its path.
            worker.async { [self] in
                var failure: Failure?, count = 0
                var buffer = [UInt8](repeating: 0, count: 65_536)
                do {
                    while true {
                        lock.lock(); let stop = error != nil; lock.unlock()
                        if stop { throw Failure.cancelled }
                        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                        if n < 0 { if errno == EINTR { continue }; throw Failure.file }
                        if n == 0 { break }
                        guard count <= 33_554_432 - n else { throw Failure.length }
                        try buffer.withUnsafeBytes { try staging.write(Data(bytes: $0.baseAddress!, count: n)) }
                        count += n
                    }
                    guard count == Int(info.st_size) else { throw Failure.length }
                    if !observeCoding || encoding == "absent" || encoding == "identity" {
                        guard declared < 0 || declared == Int64(count) else { throw Failure.length }
                    }
                } catch let issue as Failure { failure = issue }
                  catch { failure = .file }
                let closed = close(fd)
                lock.lock(); copying = false; copied = failure == nil && closed == 0
                copiedBytes = count; events.append("copyClosed")
                if error == nil { error = failure ?? (closed == 0 ? nil : .file) }
                lock.unlock(); finishIfReady()
            }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError issue: Error?) {
            lock.lock(); httpDone = true; events.append("httpComplete")
            if issue != nil && error == nil { error = .network }
            lock.unlock(); finishIfReady()
        }
        private func finishIfReady() {
            lock.lock()
            guard !terminal, httpDone, !copying else { lock.unlock(); return }
            var reader: XMLTVStagedFile?, failure = error
            if failure == nil && (!accepted || !copied) { failure = .file }
            if failure == nil {
                do { reader = try staging.finishAndTransfer(); handoffs += 1 }
                catch { failure = .file }
            }
            terminal = true; error = failure; completions += 1
            events.append(reader == nil ? "failed" : "transferred")
            let next = continuation, s = session
            continuation = nil; session = nil; original = nil; replacement = nil
            lock.unlock()
            if let reader { s?.finishTasksAndInvalidate(); next?.resume(returning: reader) }
            else {
                do { try staging.release() } catch { XCTFail("B1 explicit cleanup failed") }
                s?.invalidateAndCancel(); next?.resume(throwing: failure ?? .file)
            }
        }
        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { life.invalidated.signal() }
        deinit { life.destroyed.signal() }
        func report() -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            return ["events": events, "encoding": encoding, "declaredLength": declared,
                    "bodyCallbacks": bodyCallbacks, "completions": completions, "handoffs": handoffs,
                    "copiedBytes": copiedBytes, "error": error?.rawValue ?? "none"]
        }
    }
    private func port() throws -> Int {
        guard let n = Int(ProcessInfo.processInfo.environment["OKVIDEO_B1_PORT"] ?? ""),
              (1...65535).contains(n) else { throw XCTSkip("Explicit B1 loopback harness only") }
        return n
    }
    private func exercise(_ name: String, port: Int, observe: Bool = false, cancel: CancelAt = .none) async throws -> [String: Any] {
        let fixture = try XMLTVStagingFileTests.Fixture(), life = Life()
        defer { do { try fixture.clean() } catch { XCTFail("Fixture cleanup failed") } }
        var probe: Probe? = try Probe(root: fixture.path, life: life, observeCoding: observe, cancelAt: cancel)
        let child = probe!.staging.testReceipt.directoryName
        var outcome: [String: Any] = ["fixture": name, "diagnostic": observe, "cancelAt": cancel.rawValue]
        do {
            let reader = try await probe!.run(URL(string: "http://127.0.0.1:\(port)/\(name)")!)
            defer { do { try reader.release() } catch { XCTFail("Caller release failed") } }
            var sha = SHA256(), count = 0
            while true { let data = try reader.read(); if data.isEmpty { break }; count += data.count; sha.update(data: data) }
            outcome["sha256"] = sha.finalize().map { String(format: "%02x", $0) }.joined()
            outcome["readBytes"] = count
            // A late cancellation must not revoke the caller's file.
            probe!.cancel()
            XCTAssertTrue(try reader.read().isEmpty)
        } catch let failure as Failure { outcome["failure"] = failure.rawValue }
        XCTAssertEqual(life.invalidated.wait(timeout: .now() + 10), .success)
        let path = probe!.temporaryPath
        outcome.merge(probe!.report()) { _, new in new }
        probe = nil
        XCTAssertEqual(life.destroyed.wait(timeout: .now() + 10), .success)
        var info = stat()
        XCTAssertEqual(lstat(fixture.path + "/" + child, &info), -1); XCTAssertEqual(errno, ENOENT)
        if let path { XCTAssertEqual(lstat(path, &info), -1); XCTAssertEqual(errno, ENOENT) }
        XCTAssertEqual(outcome["completions"] as? Int, 1)
        XCTAssertEqual(outcome["bodyCallbacks"] as? Int, 0)
        return outcome
    }
    func testAdmissionAndCoding() async throws {
        let p = try port(); var rows: [[String: Any]] = []
        for name in ["xml", "gzip", "br", "file.xml.gz", "double.xml.gz", "status404", "status206", "range", "oversize"] {
            let r = try await exercise(name, port: p)
            let allowed = ["xml", "file.xml.gz"].contains(name)
            XCTAssertEqual(r["handoffs"] as? Int, allowed ? 1 : 0)
            XCTAssertEqual((r["events"] as! [String]).contains("replacementInstalled"), allowed)
            if name == "oversize" { XCTAssertEqual(r["failure"] as? String, "length") }
            if ["status404", "status206", "range"].contains(name) { XCTAssertEqual(r["failure"] as? String, "response") }
            rows.append(r)
        }
        // Diagnostic observers are separate operations. Never selectable by production.
        for name in ["gzip", "br", "file.xml.gz", "double.xml.gz"] {
            let r = try await exercise(name, port: p, observe: true)
            XCTAssertEqual(r["handoffs"] as? Int, 1); rows.append(r)
        }
        print("B1_MATRIX " + String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self))
    }
    func testConversionCancellationWindows() async throws {
        let p = try port(); var rows: [[String: Any]] = []
        for at in [CancelAt.beforeDisposition, .conversionWindow, .afterReplacement] {
            for _ in 0..<3 {
                let r = try await exercise("bytes/33554432", port: p, cancel: at)
                XCTAssertEqual(r["failure"] as? String, "cancelled")
                XCTAssertEqual(r["handoffs"] as? Int, 0)
                let e = r["events"] as! [String]
                if at == .beforeDisposition { XCTAssertFalse(e.contains("becomeDownloadIssued")) }
                if at == .conversionWindow {
                    XCTAssertLessThan(e.firstIndex(of: "becomeDownloadIssued")!, e.firstIndex(of: "cancel")!)
                    if let installed = e.firstIndex(of: "replacementInstalled") { XCTAssertLessThan(e.firstIndex(of: "cancel")!, installed) }
                }
                if at == .afterReplacement { XCTAssertLessThan(e.firstIndex(of: "replacementInstalled")!, e.firstIndex(of: "cancel")!) }
                rows.append(r)
            }
        }
        print("B1_CANCEL " + String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self))
    }
    private static func memory() -> [String: UInt64] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        } }
        precondition(code == KERN_SUCCESS)
        var stats = malloc_statistics_t(); malloc_zone_statistics(nil, &stats)
        return ["rss": info.resident_size, "footprint": info.phys_footprint,
                "live": UInt64(stats.size_in_use), "reserved": UInt64(stats.size_allocated)]
    }
    private static func fds() -> Int { Int(proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)) / MemoryLayout<proc_fdinfo>.stride }
    private final class Peaks: @unchecked Sendable {
        let lock = NSLock(); var rss: UInt64 = 0, footprint: UInt64 = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "b1-memory"))
        init() { timer.schedule(deadline: .now(), repeating: .milliseconds(10)); timer.setEventHandler { [weak self] in self?.sample() }; timer.resume() }
        func sample() { let p = XMLTVDownloadAdmissionTests.memory(); lock.lock(); rss = max(rss,p["rss"]!); footprint = max(footprint,p["footprint"]!); lock.unlock() }
        func stop() -> (UInt64,UInt64) { timer.cancel(); sample(); lock.lock(); defer { lock.unlock() }; return (rss,footprint) }
        deinit { timer.cancel() }
    }
    func testConvertedDownloadMemory() async throws {
        let p = try port()
        _ = try await exercise("bytes/65536", port: p)
        try await Task.sleep(nanoseconds: 250_000_000)
        let base = Self.memory(), baseFD = Self.fds(); var rows: [[String:Any]] = []
        for i in 1...8 {
            let start = Self.memory(), began = DispatchTime.now().uptimeNanoseconds, samples = Peaks()
            let r = try await exercise("bytes/33554432", port: p)
            XCTAssertEqual(r["handoffs"] as? Int, 1)
            let peak = samples.stop()
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
            try await Task.sleep(nanoseconds: 250_000_000)
            let settled = Self.memory()
            rows.append(["index": i, "settledRSS": settled["rss"]!, "settledFootprint": settled["footprint"]!,
                "settledLiveMalloc": settled["live"]!, "settledReservedMalloc": settled["reserved"]!, "openFDs": Self.fds(),
                "peakRSSDeltaMiB": max(0,Double(peak.0)-Double(start["rss"]!))/1_048_576,
                "peakFootprintDeltaMiB": max(0,Double(peak.1)-Double(start["footprint"]!))/1_048_576,
                "seconds": seconds, "copiedBytes": r["copiedBytes"]!, "sha256": r["sha256"]!, "foundationTemporaryFileRemoved": true])
        }
        let result: [String:Any] = ["baseline": base, "baselineFDs": baseFD, "bytes": 33_554_432, "results": rows]
        print("B1_MEMORY " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
