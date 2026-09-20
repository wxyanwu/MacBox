import CryptoKit
import Foundation

/// Cache identity contains no endpoint, headers or account values.
public struct EPGSourceKey: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case imported, xtream }
    public let kind: Kind
    public let id: UUID

    public init(_ source: LiveSourceID) {
        switch source {
        case .imported(let id): kind = .imported; self.id = id
        case .xtream(let id): kind = .xtream; self.id = id
        }
    }
}

public struct EPGRequestKey: Codable, Hashable, Sendable {
    public let source: EPGSourceKey
    public let revision: String
    /// "xmltv" for a whole imported guide; stream ID for native short EPG.
    public let resource: String

    public init(source: LiveSourceID, revision: String, resource: String) {
        self.source = EPGSourceKey(source)
        self.revision = revision
        self.resource = resource
    }

    public static func revision(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum EPGAvailability: String, Codable, Sendable {
    case fresh, stale, empty, unsupported, failed
}

public enum EPGFetchError: Error, Sendable { case unavailable, malformed }

public struct EPGPayload: Sendable {
    public var guide: XMLTVGuide
    public var unsupported: Bool

    public init(guide: XMLTVGuide, unsupported: Bool = false) {
        self.guide = guide
        self.unsupported = unsupported
    }
}

/// Immutable query result. The large index stays out of ObservableObject state.
public struct EPGSnapshot: Sendable {
    public let key: EPGRequestKey
    public let availability: EPGAvailability
    public let fetchedAt: Date?
    public let retryAfter: Date
    public let programmeCount: Int
    /// Imported table coverage, independent of cache freshness. Computed once,
    /// never by scanning channels or matching names during presentation ticks.
    public let xmltvMaxProgrammeEnd: Date?
    private let index: XMLTVScheduleIndex

    public init(key: EPGRequestKey, availability: EPGAvailability,
                fetchedAt: Date?, retryAfter: Date, guide: XMLTVGuide) {
        self.key = key
        self.availability = availability
        self.fetchedAt = fetchedAt
        self.retryAfter = retryAfter
        programmeCount = guide.programmes.count
        xmltvMaxProgrammeEnd = key.source.kind == .imported ? guide.programmes.lazy.map(\.end).max() : nil
        index = XMLTVScheduleIndex(guide: guide)
    }

    public func nowNext(for channel: LiveChannel, at date: Date) -> EPGNowNextSnapshot {
        var queryChannel = channel
        if key.source.kind == .xtream {
            // Short EPG belongs to the requested stream, never to a name fallback.
            queryChannel.tvgID = key.resource
            queryChannel.tvgName = nil
            queryChannel.name = key.resource
        }
        let result = index.currentAndNext(for: queryChannel, at: date)
        return EPGNowNextSnapshot(current: result.current, next: result.next,
                                  availability: availability == .fresh && date >= retryAfter ? .stale : availability)
    }
}

public struct EPGNowNextSnapshot: Equatable, Sendable {
    public let current: EPGProgramme?
    public let next: EPGProgramme?
    public let availability: EPGAvailability

    public init(current: EPGProgramme? = nil, next: EPGProgramme? = nil,
                availability: EPGAvailability = .empty) {
        self.current = current
        self.next = next
        self.availability = availability
    }

    public func progress(at date: Date) -> Double? {
        guard let current, current.end > current.start else { return nil }
        return min(1, max(0, date.timeIntervalSince(current.start)
                          / current.end.timeIntervalSince(current.start)))
    }
}
