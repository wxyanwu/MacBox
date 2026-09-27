import Foundation
import CryptoKit
import OKVideoCore
import OKVideoPersistence

@MainActor
struct FavoriteSourceContext: Equatable {
    let configurationID: UUID
    let configurationName: String
    let siteKey: String
    let siteName: String
    let fingerprint: String

    init(configuration: StoredConfiguration, site: SiteConfiguration) {
        configurationID = configuration.id; configurationName = configuration.name
        siteKey = site.key; siteName = site.name
        // Persist only a digest of source authority, never credentials/headers.
        // Display names and refresh dates cannot change a work's namespace.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let authority: [String: JSONValue] = [
            "kind": .string(configuration.sourceKind.rawValue),
            "source": .string(configuration.sourceValue ?? ""),
            "base": .string(configuration.baseURL?.absoluteString ?? ""),
            "api": .string(site.api), "ext": site.ext ?? .null
        ]
        fingerprint = SHA256.hash(data: (try? encoder.encode(authority)) ?? Data())
            .map { String(format: "%02x", $0) }.joined()
    }
    func record(_ detail: VideoDetail) -> FavoriteRecord {
        FavoriteRecord(siteKey: siteKey, videoID: detail.summary.videoID, title: detail.summary.title,
            posterURL: FavoritePersistencePolicy.safePoster(detail.summary.posterURL.map { InlineImageRequest.parse($0).url }), synopsis: detail.synopsis,
            configurationID: configurationID, configurationName: configurationName,
            siteName: siteName, sourceFingerprint: fingerprint, year: detail.summary.year,
            categoryName: detail.summary.categoryName)
    }
    static func matches(_ detail: VideoDetail, favorite: FavoriteRecord) -> Bool {
        guard detail.summary.siteKey == favorite.siteKey,
              AppState.historyContentMatches(detail, record: HistoryRecord(siteKey: favorite.siteKey,
                    videoID: favorite.videoID, title: favorite.title)) else { return false }
        if let year = favorite.year.flatMap { $0.isEmpty ? nil : $0 }, let actual = detail.summary.year.flatMap { $0.isEmpty ? nil : $0 }, year != actual { return false }
        return true
    }
}
