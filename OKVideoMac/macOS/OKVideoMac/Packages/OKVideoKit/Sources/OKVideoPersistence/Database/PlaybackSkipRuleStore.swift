import Foundation
import OKVideoCore

extension SQLiteStore: PlaybackSkipRuleRepository {
    private static var playbackSkipRuleSettingKey: String {
        "playback.skipRules.v1"
    }

    private static var playbackCompletionMarkerSettingKey: String {
        "playback.completionMarkers.v1"
    }

    public func savePlaybackSkipRule(_ rule: PlaybackSkipRule) throws {
        var rules = try allPlaybackSkipRules()
        if rule.opening.behavior == .inherit,
           rule.ending.behavior == .inherit {
            rules.removeAll { $0.identity == rule.identity }
        } else if let index = rules.firstIndex(where: {
            $0.identity == rule.identity
        }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        try persistPlaybackSkipRules(rules)
    }

    public func playbackSkipRules(
        configurationID: UUID
    ) throws -> [PlaybackSkipRule] {
        try allPlaybackSkipRules().filter {
            $0.identity.configurationID == configurationID
        }
    }

    public func deletePlaybackSkipRule(
        identity: PlaybackSkipRuleIdentity
    ) throws {
        var rules = try allPlaybackSkipRules()
        rules.removeAll { $0.identity == identity }
        try persistPlaybackSkipRules(rules)
    }

    public func deletePlaybackSkipRules(
        configurationID: UUID
    ) throws {
        var rules = try allPlaybackSkipRules()
        rules.removeAll { $0.identity.configurationID == configurationID }
        try persistPlaybackSkipRules(rules)
    }

    public func savePlaybackCompletionMarker(
        _ marker: PlaybackCompletionMarker
    ) throws {
        var markers = try allPlaybackCompletionMarkers()
        if let index = markers.firstIndex(where: {
            $0.identity == marker.identity
        }) {
            markers[index] = marker
        } else {
            markers.append(marker)
        }
        try persistPlaybackCompletionMarkers(markers)
    }

    public func playbackCompletionMarkers(
        configurationID: UUID
    ) throws -> [PlaybackCompletionMarker] {
        try allPlaybackCompletionMarkers().filter {
            $0.identity.configurationID == configurationID
        }
    }

    public func deletePlaybackCompletionMarker(
        identity: PlaybackSkipRuleIdentity
    ) throws {
        var markers = try allPlaybackCompletionMarkers()
        markers.removeAll { $0.identity == identity }
        try persistPlaybackCompletionMarkers(markers)
    }

    public func deletePlaybackCompletionMarkers(
        configurationID: UUID
    ) throws {
        var markers = try allPlaybackCompletionMarkers()
        markers.removeAll { $0.identity.configurationID == configurationID }
        try persistPlaybackCompletionMarkers(markers)
    }

    public func deletePlaybackCompletionMarkers(
        historyRecordIDs: Set<String>
    ) throws {
        guard !historyRecordIDs.isEmpty else { return }
        var markers = try allPlaybackCompletionMarkers()
        markers.removeAll { historyRecordIDs.contains($0.historyRecordID) }
        try persistPlaybackCompletionMarkers(markers)
    }

    private func allPlaybackSkipRules() throws -> [PlaybackSkipRule] {
        guard let value = try setting(
            forKey: Self.playbackSkipRuleSettingKey
        ) else { return [] }
        guard case .string(let encoded) = value,
              let data = encoded.data(using: .utf8) else {
            throw AppError.database("片头片尾设置格式无效")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode([PlaybackSkipRule].self, from: data)
        } catch {
            throw AppError.database("无法读取片头片尾设置")
        }
    }

    private func persistPlaybackSkipRules(
        _ rules: [PlaybackSkipRule]
    ) throws {
        guard !rules.isEmpty else {
            try setSetting(nil, forKey: Self.playbackSkipRuleSettingKey)
            return
        }
        let ordered = rules.sorted {
            if $0.identity.configurationID != $1.identity.configurationID {
                return $0.identity.configurationID.uuidString
                    < $1.identity.configurationID.uuidString
            }
            if $0.identity.siteKey != $1.identity.siteKey {
                return $0.identity.siteKey < $1.identity.siteKey
            }
            if $0.identity.contentID != $1.identity.contentID {
                return $0.identity.contentID < $1.identity.contentID
            }
            if $0.identity.lineID != $1.identity.lineID {
                return $0.identity.lineID < $1.identity.lineID
            }
            return ($0.identity.episodeID ?? "")
                < ($1.identity.episodeID ?? "")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(
            decoding: try encoder.encode(ordered),
            as: UTF8.self
        )
        try setSetting(
            .string(encoded),
            forKey: Self.playbackSkipRuleSettingKey
        )
    }

    private func allPlaybackCompletionMarkers() throws
        -> [PlaybackCompletionMarker] {
        guard let value = try setting(
            forKey: Self.playbackCompletionMarkerSettingKey
        ) else { return [] }
        guard case .string(let encoded) = value,
              let data = encoded.data(using: .utf8) else {
            throw AppError.database("播放完成记录格式无效")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(
                [PlaybackCompletionMarker].self,
                from: data
            )
        } catch {
            throw AppError.database("无法读取播放完成记录")
        }
    }

    private func persistPlaybackCompletionMarkers(
        _ markers: [PlaybackCompletionMarker]
    ) throws {
        guard !markers.isEmpty else {
            try setSetting(
                nil,
                forKey: Self.playbackCompletionMarkerSettingKey
            )
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(
            decoding: try encoder.encode(
                markers.sorted { $0.completedAt > $1.completedAt }
            ),
            as: UTF8.self
        )
        try setSetting(
            .string(encoded),
            forKey: Self.playbackCompletionMarkerSettingKey
        )
    }
}
