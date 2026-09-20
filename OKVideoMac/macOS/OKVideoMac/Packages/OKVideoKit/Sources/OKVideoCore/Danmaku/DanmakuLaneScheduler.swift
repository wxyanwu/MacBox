import Foundation

public struct DanmakuLaneReservation: Equatable, Sendable {
    public var lane: Int
    public var startTime: TimeInterval
    public var textWidth: Double
    public var velocity: Double

    public init(lane: Int, startTime: TimeInterval, textWidth: Double, velocity: Double) {
        self.lane = lane
        self.startTime = startTime
        self.textWidth = textWidth
        self.velocity = velocity
    }
}

/// Allocates scrolling comments without delaying them. If no lane can keep a
/// safe separation, the comment is dropped for that presentation frame.
public struct DanmakuLaneScheduler: Sendable {
    private var reservations: [DanmakuLaneReservation?]

    public init(laneCount: Int) {
        reservations = Array(repeating: nil, count: max(0, laneCount))
    }

    public mutating func reset(laneCount: Int? = nil) {
        if let laneCount {
            reservations = Array(repeating: nil, count: max(0, laneCount))
        } else {
            reservations = Array(repeating: nil, count: reservations.count)
        }
    }

    public mutating func reserve(
        at mediaTime: TimeInterval,
        textWidth: Double,
        viewportWidth: Double,
        lifetime: TimeInterval
    ) -> DanmakuLaneReservation? {
        guard mediaTime.isFinite,
              textWidth.isFinite, textWidth > 0,
              viewportWidth.isFinite, viewportWidth > 0,
              lifetime.isFinite, lifetime > 0 else { return nil }
        let velocity = (viewportWidth + textWidth) / lifetime
        for lane in reservations.indices {
            if canUse(
                reservations[lane],
                at: mediaTime,
                newTextWidth: textWidth,
                viewportWidth: viewportWidth,
                newVelocity: velocity
            ) {
                let reservation = DanmakuLaneReservation(
                    lane: lane,
                    startTime: mediaTime,
                    textWidth: textWidth,
                    velocity: velocity
                )
                reservations[lane] = reservation
                return reservation
            }
        }
        return nil
    }

    private func canUse(
        _ previous: DanmakuLaneReservation?,
        at time: TimeInterval,
        newTextWidth: Double,
        viewportWidth: Double,
        newVelocity: Double
    ) -> Bool {
        guard let previous else { return true }
        let elapsed = max(0, time - previous.startTime)
        let previousRightEdge = viewportWidth + previous.textWidth
            - previous.velocity * elapsed
        // The previous comment must be fully inside the viewport before the
        // next one enters from the right.
        guard previousRightEdge <= viewportWidth else { return false }
        // A faster following comment must not catch the previous one before it
        // has fully left the screen.
        guard newVelocity > previous.velocity else { return true }
        let gap = viewportWidth - previousRightEdge
        let catchTime = gap / (newVelocity - previous.velocity)
        let previousExitTime = max(0, previousRightEdge / previous.velocity)
        return catchTime >= previousExitTime
    }
}
