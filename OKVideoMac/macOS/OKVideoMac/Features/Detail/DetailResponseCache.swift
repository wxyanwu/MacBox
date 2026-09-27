import Foundation
import OKVideoCore

/// Short-lived, memory-only provider detail snapshots. These are never player
/// resolution results and are never persisted with credentials or signed URLs.
@MainActor final class DetailResponseCache {
    struct Key: Hashable {
        let generation: UUID
        let siteKey: String
        let videoID: String

        var storageKey: NSString {
            // Length-prefix the opaque identifiers; separators can occur in IDs.
            "\(generation.uuidString):\(siteKey.utf8.count):\(siteKey)\(videoID)" as NSString
        }
    }

    private final class Entry {
        let detail: VideoDetail
        let expiresAt: TimeInterval
        init(_ detail: VideoDetail, expiresAt: TimeInterval) {
            self.detail = detail
            self.expiresAt = expiresAt
        }
    }

    private let cache = NSCache<NSString, Entry>()
    private let lifetime: TimeInterval
    private let now: () -> TimeInterval
    private(set) var generation = UUID()

    init(lifetime: TimeInterval = 120,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.lifetime = lifetime
        self.now = now
        cache.countLimit = 24
        cache.totalCostLimit = 12_000
    }

    func key(for summary: VideoSummary) -> Key {
        Key(generation: generation, siteKey: summary.siteKey, videoID: summary.videoID)
    }

    func value(for key: Key) -> VideoDetail? {
        guard key.generation == generation,
              let entry = cache.object(forKey: key.storageKey) else { return nil }
        guard entry.expiresAt > now() else {
            cache.removeObject(forKey: key.storageKey)
            return nil
        }
        return entry.detail
    }

    func insert(_ detail: VideoDetail, for key: Key) {
        guard key.generation == generation,
              detail.summary.siteKey == key.siteKey,
              detail.summary.resolvedContentKind == .media,
              detail.playSources.contains(where: { !$0.episodes.isEmpty }) else { return }
        let cost = max(1, detail.playSources.reduce(0) { $0 + $1.episodes.count })
        guard cost <= 12_000 else { return }
        cache.setObject(Entry(detail, expiresAt: now() + lifetime), forKey: key.storageKey, cost: cost)
    }

    func remove(_ key: Key) { cache.removeObject(forKey: key.storageKey) }

    func invalidate() {
        generation = UUID()
        cache.removeAllObjects()
    }
}
