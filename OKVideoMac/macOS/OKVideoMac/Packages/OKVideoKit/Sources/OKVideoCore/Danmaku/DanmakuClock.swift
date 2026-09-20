import Foundation

/// Interpolates between authoritative player snapshots. The player owns media
/// time; this clock only smooths drawing between snapshots.
public struct DanmakuClock: Equatable, Sendable {
    public private(set) var generation: UInt64
    public private(set) var mediaTime: TimeInterval
    public private(set) var monotonicTime: TimeInterval
    public private(set) var rate: Double
    public private(set) var isAdvancing: Bool

    public init(
        generation: UInt64 = 0,
        mediaTime: TimeInterval = 0,
        monotonicTime: TimeInterval = 0,
        rate: Double = 1,
        isAdvancing: Bool = false
    ) {
        self.generation = generation
        self.mediaTime = Self.validMediaTime(mediaTime)
        self.monotonicTime = monotonicTime.isFinite ? monotonicTime : 0
        self.rate = Self.validRate(rate)
        self.isAdvancing = isAdvancing
    }

    public mutating func anchor(
        mediaTime: TimeInterval,
        monotonicTime: TimeInterval,
        rate: Double,
        isPlaying: Bool,
        isBuffering: Bool,
        isSeeking: Bool,
        generation: UInt64
    ) {
        self.generation = generation
        self.mediaTime = Self.validMediaTime(mediaTime)
        self.monotonicTime = monotonicTime.isFinite ? monotonicTime : self.monotonicTime
        self.rate = Self.validRate(rate)
        isAdvancing = isPlaying && !isBuffering && !isSeeking
    }

    public func currentTime(at monotonicTime: TimeInterval) -> TimeInterval {
        guard generation > 0, isAdvancing, monotonicTime.isFinite else {
            return mediaTime
        }
        return max(0, mediaTime + max(0, monotonicTime - self.monotonicTime) * rate)
    }

    private static func validMediaTime(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }

    private static func validRate(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }
}
