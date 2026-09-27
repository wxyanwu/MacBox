import Foundation

public struct PlaybackAudioPreference: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var volume: Double
    public var muted: Bool
    public init(volume: Double = 100, muted: Bool = false) {
        self.volume = volume.isFinite ? min(130, max(0, volume)) : 100
        self.muted = muted
    }
}

/// User intent is saved synchronously, independently of views and native commands.
@MainActor
public final class PlaybackAudioPreferenceStore {
    public static let key = "player.audio.preference.v1"
    public private(set) var value: PlaybackAudioPreference
    public private(set) var revision: UInt64 = 0
    private let defaults: UserDefaults?

    /// A nil store is deliberately in-memory for isolated clients and tests.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(PlaybackAudioPreference.self, from: data),
           saved.version == 1 {
            value = .init(volume: saved.volume, muted: saved.muted)
        } else { value = .init() }
    }

    public func setVolume(_ volume: Double) {
        guard volume.isFinite else { return }
        var next = value
        next.volume = min(130, max(0, volume))
        if next.volume > 0 { next.muted = false }
        save(next)
    }

    public func setMuted(_ muted: Bool) {
        var next = value
        next.muted = muted
        save(next)
    }

    private func save(_ next: PlaybackAudioPreference) {
        guard next != value else { return }
        value = next
        revision &+= 1
        if let data = try? JSONEncoder().encode(value) { defaults?.set(data, forKey: Self.key) }
    }
}
