import CryptoKit
import Foundation
import OKVideoCore
import OKVideoPersistence
import UniformTypeIdentifiers

extension UTType {
    static let okVideoBackup = UTType(
        exportedAs: "com.okvideomac.backup",
        conformingTo: .json
    )
}

struct PortableBackupManifest: Codable, Equatable, Sendable {
    static let formatIdentifier = "com.okvideomac.portable-backup"
    static let currentSchemaVersion = 4

    var format: String
    var schemaVersion: Int
    var createdAt: Date
    var appVersion: String
    var appBuild: String
    var activeConfigurationID: UUID
    var configurationCount: Int
    var historyCount: Int
    var favoriteCount: Int? = nil
}

struct PortableConfigurationRecord: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var sourceKind: StoredConfigurationSourceKind
    var sourceValue: String?
    var baseURL: URL?
    var rawData: Data
    var rawDataSHA256: String
    var updatedAt: Date

    init(_ record: StoredConfiguration) {
        id = record.id
        name = record.name
        sourceKind = record.sourceKind
        sourceValue = record.sourceValue
        baseURL = record.baseURL
        rawData = record.rawData
        rawDataSHA256 = PortableBackupCodec.sha256Hex(record.rawData)
        updatedAt = record.updatedAt
    }

    var storedConfiguration: StoredConfiguration {
        StoredConfiguration(
            id: id,
            name: name,
            sourceKind: sourceKind,
            sourceValue: sourceValue,
            baseURL: baseURL,
            rawData: rawData,
            updatedAt: updatedAt,
            isActive: true
        )
    }
}

struct PortableBackupPayload: Codable, Equatable, Sendable {
    var configuration: PortableConfigurationRecord
    var history: [HistoryRecord]
    var playbackSkipRules: [PlaybackSkipRule]
    var playbackCompletionMarkers: [PlaybackCompletionMarker]
    var danmakuBindings: [DanmakuBinding]
    var favorites: [FavoriteRecord]?

    init(
        configuration: PortableConfigurationRecord,
        history: [HistoryRecord],
        playbackSkipRules: [PlaybackSkipRule] = [],
        playbackCompletionMarkers: [PlaybackCompletionMarker] = [],
        danmakuBindings: [DanmakuBinding] = [],
        favorites: [FavoriteRecord]? = nil
    ) {
        self.configuration = configuration
        self.history = history
        self.playbackSkipRules = playbackSkipRules
        self.playbackCompletionMarkers = playbackCompletionMarkers
        self.danmakuBindings = danmakuBindings
        self.favorites = favorites
    }

    private enum CodingKeys: String, CodingKey {
        case configuration
        case history
        case playbackSkipRules
        case playbackCompletionMarkers
        case danmakuBindings
        case favorites
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decode(
            PortableConfigurationRecord.self,
            forKey: .configuration
        )
        history = try container.decode(
            [HistoryRecord].self,
            forKey: .history
        )
        playbackSkipRules = try container.decodeIfPresent(
            [PlaybackSkipRule].self,
            forKey: .playbackSkipRules
        ) ?? []
        playbackCompletionMarkers = try container.decodeIfPresent(
            [PlaybackCompletionMarker].self,
            forKey: .playbackCompletionMarkers
        ) ?? []
        favorites = try container.decodeIfPresent([FavoriteRecord].self, forKey: .favorites)
        danmakuBindings = try container.decodeIfPresent(
            [DanmakuBinding].self,
            forKey: .danmakuBindings
        ) ?? []
    }
}

struct PortableBackupEnvelope: Codable, Equatable, Sendable {
    var manifest: PortableBackupManifest
    /// The payload remains a separately encoded byte sequence so its checksum
    /// verifies the exact exported bytes instead of a decoder's re-encoding.
    var payload: Data
    var payloadSHA256: String
}

struct DecodedPortableBackup: Equatable, Sendable {
    var manifest: PortableBackupManifest
    var payload: PortableBackupPayload
}

struct PortableBackupPreview: Identifiable, Equatable, Sendable {
    let id = UUID()
    var fileURL: URL
    var createdAt: Date
    var appVersion: String
    var appBuild: String
    var configurationName: String
    var historyCount: Int
    var favoriteCount: Int = 0
}

struct PortableBackupImportSummary: Equatable, Sendable {
    var configurationName: String
    var historyCount: Int
    var changedHistoryCount: Int
    var safetyBackupURL: URL?
}

enum PortableBackupError: LocalizedError, Equatable {
    case fileTooLarge
    case invalidDocument
    case unsupportedFormat
    case unsupportedSchema(Int)
    case checksumMismatch
    case invalidConfiguration
    case invalidHistory

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return L10n.string("backup.error.too-large", fallback: "The backup file exceeds the allowed size.")
        case .invalidDocument:
            return L10n.string("backup.error.invalid-document", fallback: "This is not a valid OKVideoMac backup file.")
        case .unsupportedFormat:
            return L10n.string("backup.error.unsupported-format", fallback: "The backup file format is unsupported.")
        case .unsupportedSchema(let version):
            return L10n.string("backup.error.unsupported-schema", fallback: "Backup schema version %lld is newer than this app supports.", version)
        case .checksumMismatch:
            return L10n.string("backup.error.checksum", fallback: "Backup verification failed. The file may be damaged or modified.")
        case .invalidConfiguration:
            return L10n.string("backup.error.invalid-configuration", fallback: "The VOD configuration in the backup is incomplete or failed validation.")
        case .invalidHistory:
            return L10n.string("backup.error.invalid-history", fallback: "The history in the backup is incomplete or contains unsafe fields.")
        }
    }
}

enum PortableBackupCodec {
    static let maximumArchiveByteCount = 32 * 1_024 * 1_024
    static let maximumHistoryCount = 50_000

    static func encode(
        configuration: StoredConfiguration,
        history: [HistoryRecord],
        playbackSkipRules: [PlaybackSkipRule] = [],
        playbackCompletionMarkers: [PlaybackCompletionMarker] = [],
        danmakuBindings: [DanmakuBinding] = [],
        favorites: [FavoriteRecord] = [],
        appVersion: String,
        appBuild: String,
        createdAt: Date = Date()
    ) throws -> Data {
        guard !configuration.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
              !configuration.rawData.isEmpty,
              configuration.rawData.count
                <= ConfigurationParser.maximumConfigurationSize else {
            throw PortableBackupError.invalidConfiguration
        }

        let sanitizedHistory = try normalizedHistory(
            history,
            configurationID: configuration.id
        )
        let scopedFavorites = try normalizedFavorites(favorites, configurationID: configuration.id)
        let payload = PortableBackupPayload(
            configuration: PortableConfigurationRecord(configuration),
            history: sanitizedHistory,
            playbackSkipRules: try normalizedPlaybackSkipRules(
                playbackSkipRules,
                configurationID: configuration.id
            ),
            playbackCompletionMarkers:
                try normalizedPlaybackCompletionMarkers(
                    playbackCompletionMarkers,
                    configurationID: configuration.id
                ),
            danmakuBindings: try normalizedDanmakuBindings(
                danmakuBindings,
                configurationID: configuration.id
            ),
            favorites: scopedFavorites
        )
        let payloadData = try encoder().encode(payload)
        let manifest = PortableBackupManifest(
            format: PortableBackupManifest.formatIdentifier,
            schemaVersion: PortableBackupManifest.currentSchemaVersion,
            createdAt: createdAt,
            appVersion: appVersion,
            appBuild: appBuild,
            activeConfigurationID: configuration.id,
            configurationCount: 1,
            historyCount: sanitizedHistory.count,
            favoriteCount: scopedFavorites.count
        )
        let envelope = PortableBackupEnvelope(
            manifest: manifest,
            payload: payloadData,
            payloadSHA256: sha256Hex(payloadData)
        )
        let data = try encoder().encode(envelope)
        guard data.count <= maximumArchiveByteCount else {
            throw PortableBackupError.fileTooLarge
        }
        return data
    }

    private static func normalizedFavorites(_ records: [FavoriteRecord], configurationID: UUID) throws -> [FavoriteRecord] {
        guard records.count <= maximumHistoryCount else { throw PortableBackupError.invalidDocument }
        var identities = Set<FavoriteIdentity>(), ids = Set<String>()
        for record in records {
            guard record.configurationID == configurationID, FavoritePersistencePolicy.isValid(record),
                  identities.insert(record.identity).inserted, ids.insert(record.id).inserted else {
                throw PortableBackupError.invalidDocument
            }
        }
        return records
    }

    static func decode(_ data: Data) throws -> DecodedPortableBackup {
        guard !data.isEmpty, data.count <= maximumArchiveByteCount else {
            throw data.isEmpty
                ? PortableBackupError.invalidDocument
                : PortableBackupError.fileTooLarge
        }
        let envelope: PortableBackupEnvelope
        do {
            envelope = try decoder().decode(
                PortableBackupEnvelope.self,
                from: data
            )
        } catch {
            throw PortableBackupError.invalidDocument
        }
        guard envelope.manifest.format
            == PortableBackupManifest.formatIdentifier else {
            throw PortableBackupError.unsupportedFormat
        }
        guard envelope.manifest.schemaVersion
            <= PortableBackupManifest.currentSchemaVersion else {
            throw PortableBackupError.unsupportedSchema(
                envelope.manifest.schemaVersion
            )
        }
        guard envelope.manifest.schemaVersion > 0,
              envelope.manifest.configurationCount == 1,
              sha256Hex(envelope.payload) == envelope.payloadSHA256 else {
            throw PortableBackupError.checksumMismatch
        }

        let payload: PortableBackupPayload
        do {
            payload = try decoder().decode(
                PortableBackupPayload.self,
                from: envelope.payload
            )
        } catch {
            throw PortableBackupError.invalidDocument
        }
        let configuration = payload.configuration
        guard configuration.id == envelope.manifest.activeConfigurationID,
              !configuration.name.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !configuration.rawData.isEmpty,
              configuration.rawData.count
                <= ConfigurationParser.maximumConfigurationSize,
              sha256Hex(configuration.rawData)
                == configuration.rawDataSHA256 else {
            throw PortableBackupError.invalidConfiguration
        }
        guard payload.history.count == envelope.manifest.historyCount,
              payload.history.count <= maximumHistoryCount else {
            throw PortableBackupError.invalidHistory
        }
        let history = try normalizedHistory(
            payload.history,
            configurationID: configuration.id
        )
        guard history == payload.history else {
            throw PortableBackupError.invalidHistory
        }
        guard try normalizedPlaybackSkipRules(
            payload.playbackSkipRules,
            configurationID: configuration.id
        ) == payload.playbackSkipRules,
              try normalizedPlaybackCompletionMarkers(
                payload.playbackCompletionMarkers,
                configurationID: configuration.id
              ) == payload.playbackCompletionMarkers,
              try normalizedDanmakuBindings(
                payload.danmakuBindings,
                configurationID: configuration.id
              ) == payload.danmakuBindings else {
            throw PortableBackupError.invalidDocument
        }
        if envelope.manifest.schemaVersion >= 4 {
            guard let favorites = payload.favorites, envelope.manifest.favoriteCount == favorites.count,
                  try normalizedFavorites(favorites, configurationID: configuration.id) == favorites else {
                throw PortableBackupError.invalidDocument
            }
        } else if payload.favorites != nil || envelope.manifest.favoriteCount != nil {
            throw PortableBackupError.invalidDocument
        }
        return DecodedPortableBackup(
            manifest: envelope.manifest,
            payload: payload
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedHistory(
        _ history: [HistoryRecord],
        configurationID: UUID
    ) throws -> [HistoryRecord] {
        guard history.count <= maximumHistoryCount else {
            throw PortableBackupError.invalidHistory
        }
        var newestByID: [String: HistoryRecord] = [:]
        for original in history {
            guard original.configurationID == configurationID,
                  isBounded(original.siteKey, maximum: 1_024),
                  isBounded(original.videoID, maximum: 4_096),
                  isBounded(original.title, maximum: 4_096),
                  isBounded(original.sourceKey, maximum: 4_096) else {
                throw PortableBackupError.invalidHistory
            }
            let record = original.sanitizedForPersistence()
            guard record == original else {
                throw PortableBackupError.invalidHistory
            }
            if let existing = newestByID[record.id],
               existing.watchedAt >= record.watchedAt {
                continue
            }
            newestByID[record.id] = record
        }
        return newestByID.values.sorted {
            if $0.watchedAt != $1.watchedAt {
                return $0.watchedAt > $1.watchedAt
            }
            return $0.id < $1.id
        }
    }

    private static func normalizedPlaybackSkipRules(
        _ rules: [PlaybackSkipRule],
        configurationID: UUID
    ) throws -> [PlaybackSkipRule] {
        guard rules.count <= maximumHistoryCount else {
            throw PortableBackupError.invalidDocument
        }
        var newest: [PlaybackSkipRuleIdentity: PlaybackSkipRule] = [:]
        for rule in rules {
            guard rule.identity.configurationID == configurationID,
                  isValid(rule.identity),
                  rule.updatedAt.timeIntervalSince1970.isFinite else {
                throw PortableBackupError.invalidDocument
            }
            for field in [rule.opening, rule.ending] {
                if let seconds = field.seconds,
                   (!seconds.isFinite
                    || seconds < 0
                    || seconds > PlaybackSkipPolicy.maximumSkipDuration) {
                    throw PortableBackupError.invalidDocument
                }
            }
            if let existing = newest[rule.identity],
               existing.updatedAt >= rule.updatedAt {
                continue
            }
            newest[rule.identity] = rule
        }
        return newest.values.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.identity.lineID < $1.identity.lineID
        }
    }

    private static func normalizedPlaybackCompletionMarkers(
        _ markers: [PlaybackCompletionMarker],
        configurationID: UUID
    ) throws -> [PlaybackCompletionMarker] {
        guard markers.count <= maximumHistoryCount else {
            throw PortableBackupError.invalidDocument
        }
        var newest: [PlaybackSkipRuleIdentity: PlaybackCompletionMarker] = [:]
        for marker in markers {
            guard marker.identity.configurationID == configurationID,
                  marker.identity.episodeID != nil,
                  isValid(marker.identity),
                  isBounded(marker.historyRecordID, maximum: 16_384),
                  marker.position.isFinite,
                  marker.duration.isFinite,
                  marker.completedAt.timeIntervalSince1970.isFinite else {
                throw PortableBackupError.invalidDocument
            }
            if let existing = newest[marker.identity],
               existing.completedAt >= marker.completedAt {
                continue
            }
            newest[marker.identity] = marker
        }
        return newest.values.sorted {
            if $0.completedAt != $1.completedAt {
                return $0.completedAt > $1.completedAt
            }
            return $0.identity.lineID < $1.identity.lineID
        }
    }

    private static func normalizedDanmakuBindings(
        _ bindings: [DanmakuBinding],
        configurationID: UUID
    ) throws -> [DanmakuBinding] {
        guard bindings.count <= maximumHistoryCount else {
            throw PortableBackupError.invalidDocument
        }
        var newest: [DanmakuEditionIdentity: DanmakuBinding] = [:]
        for binding in bindings {
            let edition = binding.editionIdentity
            let episode = edition.episode
            let content = episode.content
            let locator = binding.locator
            guard content.configurationID == configurationID,
                  isBounded(content.siteKey, maximum: 1_024),
                  isBounded(content.contentID, maximum: 4_096),
                  content.title.utf8.count <= 4_096,
                  isBounded(episode.episodeID, maximum: 4_096),
                  episode.title.utf8.count <= 4_096,
                  isBounded(edition.editionID, maximum: 4_096),
                  isBounded(locator.provider, maximum: 1_024),
                  isBounded(locator.resourceID, maximum: 16_384),
                  isBounded(locator.displayName, maximum: 4_096),
                  binding.offset.isFinite,
                  abs(binding.offset) <= 21_600,
                  binding.updatedAt.timeIntervalSince1970.isFinite else {
                throw PortableBackupError.invalidDocument
            }
            if let existing = newest[edition],
               existing.updatedAt >= binding.updatedAt {
                continue
            }
            newest[edition] = binding
        }
        return newest.values.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.editionIdentity.editionID
                < $1.editionIdentity.editionID
        }
    }

    private static func isValid(
        _ identity: PlaybackSkipRuleIdentity
    ) -> Bool {
        isBounded(identity.siteKey, maximum: 1_024)
            && isBounded(identity.contentID, maximum: 4_096)
            && isBounded(identity.lineID, maximum: 4_096)
            && identity.episodeID.map {
                isBounded($0, maximum: 4_096)
            } ?? true
    }

    private static func isBounded(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
