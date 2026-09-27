import Foundation

public enum DanmakuEcosystem: String, Codable, Equatable, Sendable {
    case tvBox
    case catPaw
    case xtream
    case local
    case unknown
}

public struct DanmakuAutomationPreferences: Codable, Equatable, Sendable {
    public var autoLoadProvidedDanmaku: Bool
    public var autoMatchExternalDanmaku: Bool

    public init(
        autoLoadProvidedDanmaku: Bool = true,
        autoMatchExternalDanmaku: Bool = false
    ) {
        self.autoLoadProvidedDanmaku = autoLoadProvidedDanmaku
        self.autoMatchExternalDanmaku = autoMatchExternalDanmaku
    }

    public static let `default` = DanmakuAutomationPreferences()
}

public struct DanmakuContentIdentity: Codable, Equatable, Hashable, Sendable {
    public var configurationID: UUID
    public var siteKey: String
    public var contentID: String
    public var title: String

    public init(
        configurationID: UUID,
        siteKey: String,
        contentID: String,
        title: String = ""
    ) {
        self.configurationID = configurationID
        self.siteKey = siteKey
        self.contentID = contentID
        self.title = title
    }

    public static func == (
        lhs: DanmakuContentIdentity,
        rhs: DanmakuContentIdentity
    ) -> Bool {
        lhs.configurationID == rhs.configurationID
            && lhs.siteKey == rhs.siteKey
            && lhs.contentID == rhs.contentID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(configurationID)
        hasher.combine(siteKey)
        hasher.combine(contentID)
    }
}

public struct DanmakuEpisodeIdentity: Codable, Equatable, Hashable, Sendable {
    public var content: DanmakuContentIdentity
    public var episodeID: String
    public var title: String
    public var seasonNumber: Int?
    public var episodeNumber: Int?

    public init(
        content: DanmakuContentIdentity,
        episodeID: String,
        title: String,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil
    ) {
        self.content = content
        self.episodeID = episodeID
        self.title = title
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }

    public static func == (
        lhs: DanmakuEpisodeIdentity,
        rhs: DanmakuEpisodeIdentity
    ) -> Bool {
        lhs.content == rhs.content && lhs.episodeID == rhs.episodeID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(content)
        hasher.combine(episodeID)
    }
}

public struct DanmakuEditionIdentity: Codable, Equatable, Hashable, Sendable {
    public var episode: DanmakuEpisodeIdentity
    public var editionID: String

    public init(episode: DanmakuEpisodeIdentity, editionID: String) {
        self.episode = episode
        self.editionID = editionID
    }
}

/// A secret-free locator which may be written to persistent storage.
public struct StableDanmakuLocator: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case providerEpisode
        case providerURLIdentity
        case localBookmark
    }

    public var kind: Kind
    public var provider: String
    public var resourceID: String
    public var displayName: String

    public init(
        kind: Kind,
        provider: String,
        resourceID: String,
        displayName: String
    ) {
        self.kind = kind
        self.provider = provider
        self.resourceID = resourceID
        self.displayName = displayName
    }
}

/// A locator that is valid only for one playback session. It deliberately is
/// not Codable so signed URLs, cookies and loopback runtime leases cannot be
/// accidentally persisted.
public struct RuntimeDanmakuLocator: Equatable, Sendable {
    public var url: URL
    public var headers: HTTPHeaders
    public var runtimeGeneration: UInt64
    public var leaseID: UUID?
    public var inlineData: Data?

    public init(
        url: URL,
        headers: HTTPHeaders = [:],
        runtimeGeneration: UInt64,
        leaseID: UUID? = nil
    ) {
        self.url = url
        self.headers = headers
        self.runtimeGeneration = runtimeGeneration
        self.leaseID = leaseID
    }
}

public struct DanmakuSourceDescriptor: Equatable, Identifiable, Sendable {
    public var id: String { "\(stable.provider)::\(stable.resourceID)" }
    public var stable: StableDanmakuLocator
    public var runtime: RuntimeDanmakuLocator
    public var isPreferred: Bool
    public var match: DanmakuMatchMetadata?

    public init(
        stable: StableDanmakuLocator,
        runtime: RuntimeDanmakuLocator,
        isPreferred: Bool = false
    ) {
        self.stable = stable
        self.runtime = runtime
        self.isPreferred = isPreferred
    }
}

public enum DanmakuSearchCapability: Equatable, Sendable {
    /// A CatPaw-compatible HTTP service. Search is performed against
    /// `/api/v2/search/episodes`; comments use `/api/v2/comment/...`.
    case catPawAPI(baseURL: URL, headers: HTTPHeaders)
    /// A provider-owned page. The WebView/bridge instance owns the callback
    /// capability and must be invalidated when the playback session changes.
    case providerWebPage(url: URL, headers: HTTPHeaders)
    /// A TVBox/FongMi configured endpoint or template.
    case configuredEndpoint(value: String)
}

public struct DanmakuPlaybackContext: Equatable, Sendable {
    public var ecosystem: DanmakuEcosystem
    public var contentIdentity: DanmakuContentIdentity
    public var editionIdentity: DanmakuEditionIdentity
    public var providedSources: [DanmakuSourceDescriptor]
    public var searchCapabilities: [DanmakuSearchCapability]
    public var matchRequest: DanmakuMatchRequest?
    public var upstreamRequestID: UUID?
    public var runtimeGeneration: UInt64

    public init(
        ecosystem: DanmakuEcosystem,
        contentIdentity: DanmakuContentIdentity,
        editionIdentity: DanmakuEditionIdentity,
        providedSources: [DanmakuSourceDescriptor] = [],
        searchCapabilities: [DanmakuSearchCapability] = [],
        runtimeGeneration: UInt64
    ) {
        self.ecosystem = ecosystem
        self.contentIdentity = contentIdentity
        self.editionIdentity = editionIdentity
        self.providedSources = providedSources
        self.searchCapabilities = searchCapabilities
        self.runtimeGeneration = runtimeGeneration
    }
}

public enum DanmakuMode: Int, Codable, Equatable, Sendable {
    case scrolling = 1
    case bottom = 4
    case top = 5
}

public struct DanmakuComment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var time: TimeInterval
    public var mode: DanmakuMode
    public var fontSize: Double
    public var color: UInt32
    public var text: String

    public init(
        id: String,
        time: TimeInterval,
        mode: DanmakuMode,
        fontSize: Double,
        color: UInt32,
        text: String
    ) {
        self.id = id
        self.time = time
        self.mode = mode
        self.fontSize = fontSize
        self.color = color
        self.text = text
    }
}

public struct DanmakuTimeline: Equatable, Sendable {
    public let comments: [DanmakuComment]

    public init(comments: [DanmakuComment]) {
        self.comments = comments.sorted {
            if $0.time == $1.time { return $0.id < $1.id }
            return $0.time < $1.time
        }
    }

    public func comments(from lowerBound: TimeInterval, through upperBound: TimeInterval) -> ArraySlice<DanmakuComment> {
        guard lowerBound.isFinite, upperBound.isFinite, lowerBound <= upperBound else {
            return comments[0..<0]
        }
        let lower = comments.partitioningIndex { $0.time >= lowerBound }
        let upper = comments.partitioningIndex { $0.time > upperBound }
        return comments[lower..<upper]
    }
}

private extension RandomAccessCollection {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Index {
        var low = startIndex
        var high = endIndex
        while low != high {
            let distance = self.distance(from: low, to: high)
            let middle = index(low, offsetBy: distance / 2)
            if predicate(self[middle]) {
                high = middle
            } else {
                low = index(after: middle)
            }
        }
        return low
    }
}

public struct DanmakuBinding: Codable, Equatable, Sendable {
    public var editionIdentity: DanmakuEditionIdentity
    public var locator: StableDanmakuLocator
    public var offset: TimeInterval
    public var updatedAt: Date
    public var verificationVersion: Int?
    public var authority: DanmakuSelectionAuthority?
    public var match: DanmakuMatchMetadata?
    public var previousLocator: StableDanmakuLocator?

    public init(
        editionIdentity: DanmakuEditionIdentity,
        locator: StableDanmakuLocator,
        offset: TimeInterval = 0,
        updatedAt: Date = Date()
    ) {
        self.editionIdentity = editionIdentity
        self.locator = locator
        self.offset = offset.isFinite ? offset : 0
        self.updatedAt = updatedAt
    }
}

public enum DanmakuSelectionAuthority: Int, Codable, Comparable, Sendable {
    case none = 0
    case automaticMatch = 1
    case providedSource = 2
    case savedBinding = 3
    case userSelection = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum DanmakuLoadState: Equatable, Sendable {
    case disabled
    case unavailable
    case resolvingSource
    case awaitingSelection([DanmakuSourceDescriptor])
    case loading(DanmakuSourceDescriptor)
    case ready(DanmakuSourceDescriptor, DanmakuTimeline)
    case empty(DanmakuSourceDescriptor)
    case staleBinding(StableDanmakuLocator)
    case failed(DanmakuSourceDescriptor?, message: String)
}

public enum DanmakuSearchState: Equatable, Sendable {
    case idle
    case searching
    case results([DanmakuSourceDescriptor])
    case empty
    case failed(message: String)
}

public enum DanmakuProvidedSourcePolicy {
    public static func automaticSource(
        from sources: [DanmakuSourceDescriptor]
    ) -> DanmakuSourceDescriptor? {
        guard !sources.isEmpty else { return nil }
        if sources.count == 1 { return sources[0] }
        let preferred = sources.filter(\.isPreferred)
        return preferred.count == 1 ? preferred[0] : nil
    }
}
