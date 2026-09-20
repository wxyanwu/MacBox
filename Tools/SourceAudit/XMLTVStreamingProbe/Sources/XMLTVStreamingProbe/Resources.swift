import Foundation
import Darwin

func safeSyntheticCachePath(_ path: String) -> Bool {
    guard path.hasPrefix("/private/tmp/OKVideoMac-9A."), !path.hasSuffix("/") else { return false }
    func resolved(_ value: String) -> String? {
        guard let pointer = realpath(value, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
    let parent = (path as NSString).deletingLastPathComponent
    guard resolved(parent) == parent else { return false }
    if FileManager.default.fileExists(atPath: path) { return resolved(path) == path }
    return (path as NSString).lastPathComponent.hasPrefix("Cache-")
}

struct ResourcePoint: Codable {
    let rss: UInt64
    let footprint: UInt64
    let processPeakRSS: UInt64
}

func resources() -> ResourcePoint {
    var value = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return ResourcePoint(rss: status == KERN_SUCCESS ? value.resident_size : 0,
                         footprint: status == KERN_SUCCESS ? value.phys_footprint : 0,
                         processPeakRSS: UInt64(max(0, usage.ru_maxrss)))
}

struct Measurement: Codable {
    let milliseconds: Double
    let before: ResourcePoint
    let after: ResourcePoint
    let sampledMaxRSS: UInt64
    let sampledMaxFootprint: UInt64
    let samples: Int
}

/// Dedicated sampler, not MainActor; sampled maxima are lower bounds.
final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var rss: UInt64 = 0
    private var footprint: UInt64 = 0
    private var samples = 0
    private var started: UInt64 = 0
    private var before = resources()
    let baseline = resources()
    var stages: [String: Measurement] = [:]

    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "epg-baseline-sampler"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        begin()
    }
    deinit { timer.cancel() }
    private func sample() {
        let p = resources()
        lock.lock(); defer { lock.unlock() }
        rss = max(rss, p.rss); footprint = max(footprint, p.footprint); samples += 1
    }
    func begin() {
        let p = resources()
        lock.lock()
        rss = p.rss; footprint = p.footprint; samples = 0
        before = p; started = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }
    func end(_ name: String) {
        let end = DispatchTime.now().uptimeNanoseconds, p = resources()
        lock.lock(); defer { lock.unlock() }
        stages[name] = Measurement(milliseconds: Double(end - started) / 1_000_000,
            before: before, after: p, sampledMaxRSS: max(rss, p.rss),
            sampledMaxFootprint: max(footprint, p.footprint), samples: samples)
    }
    func measure<T>(_ name: String, _ action: () throws -> T) rethrows -> T {
        begin(); defer { end(name) }; return try action()
    }
}

struct Distribution: Codable {
    let samples: Int
    let p50ms: Double
    let p95ms: Double
    let maxms: Double
    let checksum: Int
}

func distribution(_ values: [Double], checksum: Int) -> Distribution {
    let sorted = values.sorted()
    func percentile(_ fraction: Double) -> Double {
        sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }
    return Distribution(samples: sorted.count, p50ms: percentile(0.5), p95ms: percentile(0.95),
                        maxms: sorted.last ?? 0, checksum: checksum)
}
