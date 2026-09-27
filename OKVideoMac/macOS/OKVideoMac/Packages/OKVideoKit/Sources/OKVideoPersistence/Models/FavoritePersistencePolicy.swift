import Foundation
import OKVideoCore

public enum FavoritePersistencePolicy {
    /// A favorite is a source locator, not a resolved media-session URL.
    public static func isSafeLocator(_ value: String) -> Bool {
        if PlaybackPersistencePolicy.sanitizedOpaqueLocator(value) == value { return true }
        guard value.utf8.count <= 4096, !value.contains("\n"), !value.contains("\r"),
              let url = URLComponents(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty,
              host != "localhost", host != "::1", !host.hasPrefix("127."),
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        let sensitive = ["token", "cookie", "authorization", "session", "signature", "expires", "password", "secret", "api_key", "apikey"]
        return !(url.queryItems ?? []).contains { item in sensitive.contains { item.name.lowercased().contains($0) } }
    }
    public static func safePoster(_ url: URL?) -> URL? {
        guard let url, isSafeLocator(url.absoluteString) else { return nil }
        return url
    }
    public static func isValid(_ record: FavoriteRecord) -> Bool {
        !record.siteKey.isEmpty && !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isSafeLocator(record.videoID) && record.createdAt.timeIntervalSince1970.isFinite
            && record.sourceFingerprint.utf8.count <= 128
            && (record.posterURL == nil || safePoster(record.posterURL) == record.posterURL)
    }
}
