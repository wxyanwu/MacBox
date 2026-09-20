import Foundation

public enum PlaybackSkipRuleScope: String, Codable, Sendable {
    case seriesLine
    case episode
}

public enum PlaybackSkipFieldBehavior: String, Codable, Sendable {
    case inherit
    case enabled
    case disabled
}

public struct PlaybackSkipFieldRule: Codable, Equatable, Sendable {
    public var behavior: PlaybackSkipFieldBehavior
    public var seconds: TimeInterval?

    public init(
        behavior: PlaybackSkipFieldBehavior = .inherit,
        seconds: TimeInterval? = nil
    ) {
        self.behavior = behavior
        self.seconds = seconds.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
    }

    public static let inherited = PlaybackSkipFieldRule()
    public static let disabled = PlaybackSkipFieldRule(behavior: .disabled)

    public static func enabled(_ seconds: TimeInterval) -> Self {
        PlaybackSkipFieldRule(behavior: .enabled, seconds: seconds)
    }

    public var enabledSeconds: TimeInterval? {
        guard behavior == .enabled,
              let seconds,
              seconds.isFinite,
              seconds > 0 else { return nil }
        return seconds
    }

    public func settingEnabled(_ enabled: Bool) -> Self {
        guard let seconds, seconds.isFinite, seconds > 0 else {
            return enabled ? self : .disabled
        }
        return PlaybackSkipFieldRule(
            behavior: enabled ? .enabled : .disabled,
            seconds: seconds
        )
    }
}

public struct PlaybackSkipRuleIdentity: Codable, Equatable, Hashable, Sendable {
    public var configurationID: UUID
    public var siteKey: String
    public var contentID: String
    public var lineID: String
    public var episodeID: String?

    public init(
        configurationID: UUID,
        siteKey: String,
        contentID: String,
        lineID: String,
        episodeID: String? = nil
    ) {
        self.configurationID = configurationID
        self.siteKey = siteKey
        self.contentID = contentID
        self.lineID = lineID
        self.episodeID = episodeID
    }

    public var scope: PlaybackSkipRuleScope {
        episodeID == nil ? .seriesLine : .episode
    }

    public var seriesLineIdentity: Self {
        var identity = self
        identity.episodeID = nil
        return identity
    }
}

public struct PlaybackSkipRule: Codable, Equatable, Identifiable, Sendable {
    public var id: PlaybackSkipRuleIdentity { identity }
    public var identity: PlaybackSkipRuleIdentity
    public var opening: PlaybackSkipFieldRule
    public var ending: PlaybackSkipFieldRule
    public var updatedAt: Date

    public init(
        identity: PlaybackSkipRuleIdentity,
        opening: PlaybackSkipFieldRule = .inherited,
        ending: PlaybackSkipFieldRule = .inherited,
        updatedAt: Date = Date()
    ) {
        self.identity = identity
        self.opening = opening
        self.ending = ending
        self.updatedAt = updatedAt
    }
}

public struct EffectivePlaybackSkipRule: Equatable, Sendable {
    public var openingEnd: TimeInterval?
    public var endingDuration: TimeInterval?

    public init(
        openingEnd: TimeInterval? = nil,
        endingDuration: TimeInterval? = nil
    ) {
        self.openingEnd = openingEnd
        self.endingDuration = endingDuration
    }

    public var isEmpty: Bool {
        openingEnd == nil && endingDuration == nil
    }
}

public enum PlaybackSkipRuleResolver {
    public static func resolve(
        line: PlaybackSkipRule?,
        episode: PlaybackSkipRule?
    ) -> EffectivePlaybackSkipRule {
        EffectivePlaybackSkipRule(
            openingEnd: resolve(
                line: line?.opening,
                episode: episode?.opening
            ),
            endingDuration: resolve(
                line: line?.ending,
                episode: episode?.ending
            )
        )
    }

    private static func resolve(
        line: PlaybackSkipFieldRule?,
        episode: PlaybackSkipFieldRule?
    ) -> TimeInterval? {
        if let episode {
            switch episode.behavior {
            case .enabled:
                return episode.enabledSeconds
            case .disabled:
                return nil
            case .inherit:
                break
            }
        }
        guard let line else { return nil }
        switch line.behavior {
        case .enabled:
            return line.enabledSeconds
        case .disabled, .inherit:
            return nil
        }
    }
}

public enum PlaybackSkipPolicy {
    public static let maximumSkipDuration: TimeInterval = 10 * 60
    public static let maximumDurationFraction = 0.20
    public static let minimumMainContentDuration: TimeInterval = 30
    public static let endingPromptWallClockSeconds: TimeInterval = 5

    public static func validated(
        _ rule: EffectivePlaybackSkipRule,
        duration: TimeInterval
    ) -> EffectivePlaybackSkipRule {
        guard duration.isFinite, duration > 0 else {
            return EffectivePlaybackSkipRule()
        }
        let maximum = min(maximumSkipDuration, duration * maximumDurationFraction)
        let opening = rule.openingEnd.flatMap {
            valid($0, maximum: maximum) ? $0 : nil
        }
        let ending = rule.endingDuration.flatMap {
            valid($0, maximum: maximum) ? $0 : nil
        }
        guard let opening, let ending else {
            return EffectivePlaybackSkipRule(
                openingEnd: opening,
                endingDuration: ending
            )
        }
        guard opening + ending + minimumMainContentDuration < duration else {
            return EffectivePlaybackSkipRule()
        }
        return EffectivePlaybackSkipRule(
            openingEnd: opening,
            endingDuration: ending
        )
    }

    public static func startPosition(
        resumePosition: TimeInterval?,
        openingEnd: TimeInterval?,
        canSeek: Bool
    ) -> TimeInterval? {
        let resume = normalized(resumePosition)
        guard canSeek else { return resume }
        let opening = normalized(openingEnd).flatMap {
            $0 <= maximumSkipDuration ? $0 : nil
        }
        return [resume, opening].compactMap { $0 }.max()
    }

    public static func endingBoundary(
        duration: TimeInterval,
        endingDuration: TimeInterval
    ) -> TimeInterval? {
        guard duration.isFinite,
              endingDuration.isFinite,
              duration > 0,
              endingDuration > 0,
              endingDuration < duration else { return nil }
        return duration - endingDuration
    }

    public static func endingPromptStart(
        boundary: TimeInterval,
        speed: Double
    ) -> TimeInterval {
        max(0, boundary - endingPromptWallClockSeconds * max(speed, 0.1))
    }

    private static func normalized(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func valid(
        _ value: TimeInterval,
        maximum: TimeInterval
    ) -> Bool {
        value.isFinite && value > 0 && value <= maximum
    }
}

public enum PlaybackCompletionReason: String, Codable, Sendable {
    case endingSkipped
}

public struct PlaybackCompletionMarker: Codable, Equatable, Identifiable, Sendable {
    public var id: PlaybackSkipRuleIdentity { identity }
    public var identity: PlaybackSkipRuleIdentity
    public var historyRecordID: String
    public var reason: PlaybackCompletionReason
    public var position: TimeInterval
    public var duration: TimeInterval
    public var completedAt: Date

    public init(
        identity: PlaybackSkipRuleIdentity,
        historyRecordID: String,
        reason: PlaybackCompletionReason = .endingSkipped,
        position: TimeInterval,
        duration: TimeInterval,
        completedAt: Date = Date()
    ) {
        self.identity = identity
        self.historyRecordID = historyRecordID
        self.reason = reason
        self.position = position.isFinite ? max(0, position) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.completedAt = completedAt
    }
}
