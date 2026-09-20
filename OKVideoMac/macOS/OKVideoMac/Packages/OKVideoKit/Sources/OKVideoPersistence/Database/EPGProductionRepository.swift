import CryptoKit
import Foundation
import OKVideoCore

/// Production EPG facade. XMLTV is resource-scoped and persisted by the 9C.3
/// service; Xtream short EPG remains a separately bounded, channel-scoped cache.
public actor EPGProductionRepository {
    private struct FailureState {
        var count: Int
        var retryAt: Date
    }
    private struct XtreamKey: Hashable {
        let source: EPGSourceKey
        let revision: String
        let account: String
        let server: String
        let streamID: String
    }
    private struct XtreamEntry {
        let key: EPGRequestKey
        let version: String
        let publishedAt: Date
        let expiresAt: Date
        var availability: EPGAvailability
        let programmes: [EPGProgramme]
        let byteCost: Int
        var accessedAt: Date
    }
    private struct XtreamFlight {
        let id: UUID
        let task: Task<XtreamEntry, Error>
    }

    public nonisolated let incarnation: UUID
    private let service: EPGProductionService?
    private let now: @Sendable () -> Date
    private var failures: [EPGRequestKey: FailureState] = [:]
    private var xtreamEntries: [XtreamKey: XtreamEntry] = [:]
    private var xtreamFlights: [XtreamKey: XtreamFlight] = [:]
    private var paused = false
    private var closed = false
    private var terminalCloseComplete = false

    private static let xmltvTTL: TimeInterval = 6 * 3600
    private static let emptyTTL: TimeInterval = 15 * 60
    private static let unsupportedTTL: TimeInterval = 3600
    private static let coverageLead: TimeInterval = 30 * 60
    private static let xtreamTTL: TimeInterval = 5 * 60
    private static let maximumXtreamEntries = 128
    private static let maximumXtreamCacheBytes = 2 * 1_024 * 1_024
    private static let maximumXtreamEntryBytes = 64 * 1_024
    private static let maximumXtreamProgrammes = 16
    private static let maximumXtreamTitleBytes = 4 * 1_024
    private static let maximumXtreamIdentifierBytes = 512

    public init(cacheDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        let identity = UUID()
        incarnation = identity
        service = try? EPGProductionService(cacheDirectory: cacheDirectory, incarnation: identity)
        self.now = now
    }

    init(service: EPGProductionService,
         now: @escaping @Sendable () -> Date = { Date() }) {
        incarnation = service.incarnation
        self.service = service
        self.now = now
    }

    public var isAvailable: Bool { service != nil && !closed }

    public func status(for key: EPGRequestKey) async -> EPGRepositoryStatus {
        let date = now()
        guard !closed, key.source.kind == .imported, key.resource == "xmltv", let service else {
            return failedStatus(key, at: date)
        }
        let summary = try? await service.activeSummary(for: key)
        return status(key: key, summary: summary ?? nil, at: date)
    }

    public func refreshXMLTV(key: EPGRequestKey, url: URL, headers: HTTPHeaders = [:],
                             force: Bool = false) async throws -> EPGRepositoryStatus {
        guard !closed else { throw EPGProductionServiceError.closed }
        guard !paused else { throw EPGProductionServiceError.paused }
        guard key.source.kind == .imported, key.resource == "xmltv", let service else {
            throw EPGProductionServiceError.unavailable
        }
        let date = now()
        let existing = await status(for: key)
        if !force, existing.nextRetryAt > date,
           existing.summary != nil || existing.consecutiveFailures > 0 { return existing }
        do {
            try await service.setSourceEnabled(key.source, enabled: true)
            _ = try await service.refreshXMLTV(key: key, url: url, headers: headers, force: force)
            failures[key] = nil
            return await status(for: key)
        } catch let error as EPGProductionServiceError where error == .cancelled || error == .paused || error == .closed {
            throw error
        } catch {
            let count = min(16, (failures[key]?.count ?? 0) + 1)
            let delay = min(15 * 60, 60 * pow(2, Double(count - 1)))
            failures[key] = FailureState(count: count, retryAt: date.addingTimeInterval(delay))
            return await status(for: key)
        }
    }

    public func queryXMLTVNowNext(_ channels: [LiveChannel], for key: EPGRequestKey,
                                  at date: Date, demandRevision: UUID) async throws -> EPGNowNextBatch {
        guard !closed, let service else { throw EPGProductionServiceError.unavailable }
        let value = try await service.queryNowNext(channels, for: key, at: date,
                                                   demandRevision: demandRevision)
        let current = await status(for: key)
        guard current.summary?.dataVersion == value.token.dataVersion,
              current.summary?.sourceEpoch == value.token.sourceEpoch else {
            throw EPGProductionServiceError.invalidRequest
        }
        return EPGNowNextBatch(token: value.token, items: value.items,
                               availability: current.availability)
    }

    public func queryXMLTVWindow(_ channel: LiveChannel, for key: EPGRequestKey,
                                 from start: Date, to end: Date, limit: Int = 200,
                                 cursor: EPGProductionWindowCursor? = nil,
                                 demandRevision: UUID) async throws -> EPGProductionWindowResult {
        guard !closed, let service else { throw EPGProductionServiceError.unavailable }
        let value = try await service.queryWindow(channel, for: key, from: start, to: end,
            limit: limit, cursor: cursor, demandRevision: demandRevision)
        let current = await status(for: key)
        guard current.summary?.dataVersion == value.page.token.dataVersion,
              current.summary?.sourceEpoch == value.page.token.sourceEpoch else {
            throw EPGProductionServiceError.invalidRequest
        }
        return value
    }

    public func loadXtream(key: EPGRequestKey, accountIdentity: String,
                           serverIdentity: String, configurationRevision: String,
                           at date: Date, demandRevision: UUID, force: Bool = false,
                           fetch: @escaping @Sendable () async throws -> EPGPayload) async throws -> EPGNowNextBatch {
        guard !closed else { throw EPGProductionServiceError.closed }
        guard !paused else { throw EPGProductionServiceError.paused }
        let cacheKey = try xtreamKey(key: key, accountIdentity: accountIdentity,
                                     serverIdentity: serverIdentity,
                                     configurationRevision: configurationRevision)
        if !force, var cached = xtreamEntries[cacheKey], cached.expiresAt > now() {
            cached.accessedAt = now(); xtreamEntries[cacheKey] = cached
            return xtreamBatch(cached, at: date, demandRevision: demandRevision)
        }
        if let flight = xtreamFlights[cacheKey] {
            return try xtreamBatch(await flight.task.value, at: date, demandRevision: demandRevision)
        }
        let id = UUID(), requestKey = key, clock = now
        let task = Task<XtreamEntry, Error> {
            let payload = try await fetch()
            try Task.checkCancellation()
            return try Self.xtreamEntry(payload: payload, requestKey: requestKey,
                                        streamID: cacheKey.streamID, now: clock())
        }
        xtreamFlights[cacheKey] = XtreamFlight(id: id, task: task)
        do {
            let value = try await task.value
            guard xtreamFlights[cacheKey]?.id == id, !closed, !paused else {
                throw EPGProductionServiceError.cancelled
            }
            xtreamFlights[cacheKey] = nil
            rememberXtream(value, for: cacheKey)
            return xtreamBatch(value, at: date, demandRevision: demandRevision)
        } catch {
            if xtreamFlights[cacheKey]?.id == id { xtreamFlights[cacheKey] = nil }
            if !Task.isCancelled, var old = xtreamEntries[cacheKey] {
                old.availability = .stale
                old.accessedAt = now()
                xtreamEntries[cacheKey] = old
                return xtreamBatch(old, at: date, demandRevision: demandRevision)
            }
            if error is CancellationError { throw EPGProductionServiceError.cancelled }
            throw EPGProductionServiceError.unavailable
        }
    }

    public func invalidate(_ source: EPGSourceKey, removePersistentCache: Bool = true) async {
        for (key, flight) in xtreamFlights where key.source == source {
            flight.task.cancel(); xtreamFlights[key] = nil
        }
        xtreamEntries = xtreamEntries.filter { $0.key.source != source }
        failures = failures.filter { $0.key.source != source }
        if removePersistentCache, source.kind == .imported, let service {
            try? await service.setSourceEnabled(source, enabled: false)
        }
    }

    public func prepareImportedSource(_ source: EPGSourceKey) async throws {
        guard source.kind == .imported, let service else { throw EPGProductionServiceError.unavailable }
        try await service.setSourceEnabled(source, enabled: true)
    }

    public func cancelTransientRequests() {
        for flight in xtreamFlights.values { flight.task.cancel() }
        xtreamFlights.removeAll()
    }

    public func pause(deadlineNanoseconds: UInt64 = 750_000_000) async -> Bool {
        paused = true
        cancelTransientRequests()
        guard let service else { return true }
        return await service.pause(deadlineNanoseconds: deadlineNanoseconds)
    }

    public func resume() async throws {
        try Task.checkCancellation()
        guard !closed else { throw EPGProductionServiceError.closed }
        if let service { try await service.resume() }
        try Task.checkCancellation()
        guard !closed else { throw EPGProductionServiceError.closed }
        paused = false
    }

    public func performMaintenance() async throws -> EPGMaintenanceResult {
        guard let service else { throw EPGProductionServiceError.unavailable }
        return try await service.performMaintenance()
    }

    public func close(deadlineNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
        if terminalCloseComplete { return true }
        closed = true; paused = true
        cancelTransientRequests()
        guard let service else { terminalCloseComplete = true; return true }
        let completed = await service.close(deadlineNanoseconds: deadlineNanoseconds)
        if completed { terminalCloseComplete = true }
        return completed
    }

    private func status(key: EPGRequestKey, summary: EPGResourceSummary?, at date: Date) -> EPGRepositoryStatus {
        let failure = failures[key]
        guard let summary else {
            return EPGRepositoryStatus(key: key, availability: .failed, summary: nil,
                freshUntil: nil, refreshDueAt: failure?.retryAt ?? date,
                nextRetryAt: failure?.retryAt ?? date,
                consecutiveFailures: failure?.count ?? 0)
        }
        let freshUntil = summary.publishedAt.addingTimeInterval(
            summary.programmeCount == 0 ? Self.emptyTTL : Self.xmltvTTL)
        let coverageDue = summary.coverageEnd.map {
            max(summary.publishedAt, $0.addingTimeInterval(-Self.coverageLead))
        }
        let due = min(freshUntil, coverageDue ?? freshUntil)
        let availability: EPGAvailability
        if failure != nil || due <= date { availability = .stale }
        else if summary.programmeCount == 0 { availability = .empty }
        else { availability = .fresh }
        return EPGRepositoryStatus(key: key, availability: availability, summary: summary,
            freshUntil: freshUntil, refreshDueAt: due,
            nextRetryAt: failure?.retryAt ?? due,
            consecutiveFailures: failure?.count ?? 0)
    }

    private func failedStatus(_ key: EPGRequestKey, at date: Date) -> EPGRepositoryStatus {
        EPGRepositoryStatus(key: key, availability: .failed, summary: nil,
            freshUntil: nil, refreshDueAt: date, nextRetryAt: date,
            consecutiveFailures: failures[key]?.count ?? 0)
    }

    private func xtreamKey(key: EPGRequestKey, accountIdentity: String,
                           serverIdentity: String, configurationRevision: String) throws -> XtreamKey {
        guard key.source.kind == .xtream, key.resource.utf8.count > 0,
              key.resource.utf8.count <= Self.maximumXtreamIdentifierBytes,
              accountIdentity.utf8.count <= 8_192, serverIdentity.utf8.count <= 8_192,
              configurationRevision.utf8.count <= 8_192 else {
            throw EPGProductionServiceError.invalidRequest
        }
        return XtreamKey(source: key.source,
            revision: Self.digest(key.revision + "\u{0}" + configurationRevision),
            account: Self.digest(accountIdentity), server: Self.digest(serverIdentity),
            streamID: key.resource)
    }

    private static func xtreamEntry(payload: EPGPayload, requestKey: EPGRequestKey,
                                    streamID: String, now: Date) throws -> XtreamEntry {
        let programmes = payload.guide.programmes
        guard programmes.count <= maximumXtreamProgrammes else {
            throw EPGProductionServiceError.resultTooLarge
        }
        var cost = streamID.utf8.count + 256
        var previous: Date?
        for value in programmes {
            let titleBytes = value.title.utf8.count
            guard value.channelID == streamID, !value.title.isEmpty,
                  titleBytes <= maximumXtreamTitleBytes,
                  value.channelID.utf8.count <= maximumXtreamIdentifierBytes,
                  value.start < value.end, value.end.timeIntervalSince(value.start) <= 7 * 86400,
                  previous.map({ $0 < value.start }) ?? true else {
                throw EPGProductionServiceError.invalidRequest
            }
            previous = value.start
            cost += titleBytes + value.channelID.utf8.count + 128
            guard cost <= maximumXtreamEntryBytes else {
                throw EPGProductionServiceError.resultTooLarge
            }
        }
        let availability: EPGAvailability = payload.unsupported ? .unsupported
            : (programmes.isEmpty ? .empty : .fresh)
        let ttl = payload.unsupported ? unsupportedTTL : (programmes.isEmpty ? emptyTTL : xtreamTTL)
        return XtreamEntry(key: requestKey, version: UUID().uuidString,
            publishedAt: now, expiresAt: now.addingTimeInterval(ttl),
            availability: availability, programmes: programmes,
            byteCost: cost, accessedAt: now)
    }

    private func rememberXtream(_ entry: XtreamEntry, for key: XtreamKey) {
        xtreamEntries[key] = entry
        while xtreamEntries.count > Self.maximumXtreamEntries
                || xtreamEntries.values.reduce(0, { $0 + $1.byteCost }) > Self.maximumXtreamCacheBytes,
              let oldest = xtreamEntries.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key {
            xtreamEntries[oldest] = nil
        }
    }

    private func xtreamBatch(_ entry: XtreamEntry, at date: Date,
                             demandRevision: UUID) -> EPGNowNextBatch {
        let current = entry.programmes.first { $0.start <= date && date < $0.end }
        let next = entry.programmes.first { $0.start > date }
        let resource = "xtream:" + Self.digest(entry.key.revision + "\u{0}" + entry.key.resource)
        let token = EPGResultToken(serviceIncarnation: incarnation,
            resourceIdentity: resource, sourceEpoch: entry.key.revision,
            dataVersion: entry.version, demandRevision: demandRevision)
        let match = EPGChannelMatch(kind: .exact, channelID: entry.key.resource)
        let availability: EPGAvailability = entry.expiresAt <= now() && entry.availability == .fresh
            ? .stale : entry.availability
        return EPGNowNextBatch(token: token,
            items: [EPGNowNextItem(match: match, current: current, next: next)],
            availability: availability)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
