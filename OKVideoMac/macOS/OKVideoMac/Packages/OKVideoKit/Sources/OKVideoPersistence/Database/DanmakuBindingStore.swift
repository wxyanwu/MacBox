import Foundation
import OKVideoCore

extension SQLiteStore: DanmakuBindingRepository {
    private static var danmakuBindingSettingKey: String {
        "playback.danmakuBindings.v1"
    }

    public func saveDanmakuBinding(_ binding: DanmakuBinding) throws {
        var bindings = try allDanmakuBindings()
        if let index = bindings.firstIndex(where: {
            $0.editionIdentity == binding.editionIdentity
        }) {
            bindings[index] = binding
        } else {
            bindings.append(binding)
        }
        try persistDanmakuBindings(bindings)
    }

    public func danmakuBindings(
        configurationID: UUID
    ) throws -> [DanmakuBinding] {
        try allDanmakuBindings().filter {
            $0.editionIdentity.episode.content.configurationID
                == configurationID
        }
    }

    public func danmakuBinding(
        for editionIdentity: DanmakuEditionIdentity
    ) throws -> DanmakuBinding? {
        try allDanmakuBindings().first {
            $0.editionIdentity == editionIdentity
        }
    }

    public func deleteDanmakuBinding(
        for editionIdentity: DanmakuEditionIdentity
    ) throws {
        var bindings = try allDanmakuBindings()
        bindings.removeAll { $0.editionIdentity == editionIdentity }
        try persistDanmakuBindings(bindings)
    }

    public func deleteDanmakuBindings(configurationID: UUID) throws {
        var bindings = try allDanmakuBindings()
        bindings.removeAll {
            $0.editionIdentity.episode.content.configurationID
                == configurationID
        }
        try persistDanmakuBindings(bindings)
    }

    private func allDanmakuBindings() throws -> [DanmakuBinding] {
        guard let value = try setting(
            forKey: Self.danmakuBindingSettingKey
        ) else { return [] }
        guard case .string(let encoded) = value,
              let data = encoded.data(using: .utf8) else {
            throw AppError.database("弹幕绑定格式无效")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode([DanmakuBinding].self, from: data)
        } catch {
            throw AppError.database("无法读取弹幕绑定")
        }
    }

    private func persistDanmakuBindings(
        _ bindings: [DanmakuBinding]
    ) throws {
        guard !bindings.isEmpty else {
            try setSetting(nil, forKey: Self.danmakuBindingSettingKey)
            return
        }
        let ordered = bindings.sorted {
            let lhs = $0.editionIdentity
            let rhs = $1.editionIdentity
            if lhs.episode.content.configurationID
                != rhs.episode.content.configurationID {
                return lhs.episode.content.configurationID.uuidString
                    < rhs.episode.content.configurationID.uuidString
            }
            if lhs.episode.content.siteKey != rhs.episode.content.siteKey {
                return lhs.episode.content.siteKey < rhs.episode.content.siteKey
            }
            if lhs.episode.content.contentID != rhs.episode.content.contentID {
                return lhs.episode.content.contentID
                    < rhs.episode.content.contentID
            }
            if lhs.episode.episodeID != rhs.episode.episodeID {
                return lhs.episode.episodeID < rhs.episode.episodeID
            }
            return lhs.editionID < rhs.editionID
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try setSetting(
            .string(String(decoding: try encoder.encode(ordered), as: UTF8.self)),
            forKey: Self.danmakuBindingSettingKey
        )
    }
}
