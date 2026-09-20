import Foundation

/// Identity checked as one value immediately before an asynchronous EPG result
/// reaches presentation state. None of these fields contains an endpoint or credential.
public struct EPGResultToken: Equatable, Hashable, Sendable {
    public let serviceIncarnation: UUID
    public let resourceIdentity: String
    public let sourceEpoch: String
    public let dataVersion: String
    public let demandRevision: UUID

    public init(serviceIncarnation: UUID, resourceIdentity: String, sourceEpoch: String,
                dataVersion: String, demandRevision: UUID) {
        self.serviceIncarnation = serviceIncarnation
        self.resourceIdentity = resourceIdentity
        self.sourceEpoch = sourceEpoch
        self.dataVersion = dataVersion
        self.demandRevision = demandRevision
    }
}

/// Finite metadata about one active resource. It never owns programme rows,
/// channel aliases, a source URL, headers, or account values.
public struct EPGResourceSummary: Equatable, Sendable {
    public let key: EPGRequestKey
    public let resourceIdentity: String
    public let sourceEpoch: String
    public let dataVersion: String
    public let programmeCount: Int
    public let publishedAt: Date
    public let coverageStart: Date?
    public let coverageEnd: Date?

    public init(key: EPGRequestKey, resourceIdentity: String, sourceEpoch: String,
                dataVersion: String, programmeCount: Int, publishedAt: Date,
                coverageStart: Date?, coverageEnd: Date?) {
        self.key = key
        self.resourceIdentity = resourceIdentity
        self.sourceEpoch = sourceEpoch
        self.dataVersion = dataVersion
        self.programmeCount = programmeCount
        self.publishedAt = publishedAt
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
    }
}

public struct EPGNowNextItem: Equatable, Sendable {
    public let match: EPGChannelMatch
    public let current: EPGProgramme?
    public let next: EPGProgramme?

    public init(match: EPGChannelMatch, current: EPGProgramme?, next: EPGProgramme?) {
        self.match = match
        self.current = current
        self.next = next
    }
}

/// Entries preserve the request channel order. The token is validated as a
/// whole at the presentation boundary; callers do not reconstruct identities.
public struct EPGNowNextBatch: Equatable, Sendable {
    public let token: EPGResultToken
    public let items: [EPGNowNextItem]
    public let availability: EPGAvailability

    public init(token: EPGResultToken, items: [EPGNowNextItem],
                availability: EPGAvailability = .fresh) {
        self.token = token
        self.items = items
        self.availability = availability
    }
}

public struct EPGRepositoryStatus: Equatable, Sendable {
    public let key: EPGRequestKey
    public let availability: EPGAvailability
    public let summary: EPGResourceSummary?
    public let freshUntil: Date?
    public let refreshDueAt: Date
    public let nextRetryAt: Date
    public let consecutiveFailures: Int

    public init(key: EPGRequestKey, availability: EPGAvailability,
                summary: EPGResourceSummary?, freshUntil: Date?,
                refreshDueAt: Date, nextRetryAt: Date,
                consecutiveFailures: Int = 0) {
        self.key = key
        self.availability = availability
        self.summary = summary
        self.freshUntil = freshUntil
        self.refreshDueAt = refreshDueAt
        self.nextRetryAt = nextRetryAt
        self.consecutiveFailures = consecutiveFailures
    }
}

public struct EPGWindowPage: Sendable {
    public let token: EPGResultToken
    public let match: EPGChannelMatch
    public let programmes: [EPGProgramme]
    public let hasMore: Bool

    public init(token: EPGResultToken, match: EPGChannelMatch,
                programmes: [EPGProgramme], hasMore: Bool) {
        self.token = token
        self.match = match
        self.programmes = programmes
        self.hasMore = hasMore
    }
}
