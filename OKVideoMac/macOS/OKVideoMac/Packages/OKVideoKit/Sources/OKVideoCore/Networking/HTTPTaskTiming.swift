import Foundation

/// Opt-in request-scoped URLSession metrics. Contains no URLs, headers or bodies.
public struct HTTPTaskTiming: Sendable {
    public let total: TimeInterval
    public let dns: TimeInterval
    public let connect: TimeInterval
    public let tls: TimeInterval
    public let firstByte: TimeInterval
    public let transfer: TimeInterval
    public let transactions: Int
    public let redirects: Int

    init(_ metrics: URLSessionTaskMetrics) {
        func duration(_ a: Date?, _ b: Date?) -> TimeInterval {
            guard let a, let b else { return 0 }
            return max(0, b.timeIntervalSince(a))
        }
        total = metrics.taskInterval.duration
        transactions = metrics.transactionMetrics.count
        redirects = metrics.redirectCount
        dns = metrics.transactionMetrics.reduce(0) { $0 + duration($1.domainLookupStartDate, $1.domainLookupEndDate) }
        connect = metrics.transactionMetrics.reduce(0) { $0 + duration($1.connectStartDate, $1.connectEndDate) }
        tls = metrics.transactionMetrics.reduce(0) { $0 + duration($1.secureConnectionStartDate, $1.secureConnectionEndDate) }
        firstByte = metrics.transactionMetrics.reduce(0) { $0 + duration($1.requestStartDate, $1.responseStartDate) }
        transfer = metrics.transactionMetrics.reduce(0) { $0 + duration($1.responseStartDate, $1.responseEndDate) }
    }
}

public enum HTTPTaskTimingContext {
    @TaskLocal public static var observer: (@Sendable (HTTPTaskTiming) -> Void)?
}
