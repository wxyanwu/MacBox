import Foundation
import IOKit.pwr_mgt
import OKVideoCore
import OSLog

/// Owns exactly one system assertion. Releasing the owner also releases it,
/// including when the App's lifecycle is torn down without a final snapshot.
final class PlaybackDisplaySleepLease {
    private let release: () -> Void

    init(release: @escaping () -> Void) { self.release = release }
    deinit { release() }

    static func acquire() -> PlaybackDisplaySleepLease? {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "OKVideoMac video playback" as CFString,
            &assertion
        )
        guard result == kIOReturnSuccess else {
            Logger(subsystem: "com.okvideomac.OKVideoMac", category: "DisplaySleep")
                .error("Display sleep assertion failed: \(result)")
            return nil
        }
        return PlaybackDisplaySleepLease { IOPMAssertionRelease(assertion) }
    }
}

/// App-level policy, independent of fullscreen, seek strategy and media URL.
/// No timer, input simulation, user preference changes or forced-sleep veto.
@MainActor
final class PlaybackDisplaySleepController {
    private let acquire: () -> PlaybackDisplaySleepLease?
    private var lease: PlaybackDisplaySleepLease?
    private(set) var requestID: UUID?
    private var finished = false
    private var hasPlayedVideo = false
    private var attemptedAcquisition = false
    private var suspended = false

    var isPreventingDisplaySleep: Bool { lease != nil }

    init(acquire: @escaping () -> PlaybackDisplaySleepLease? = PlaybackDisplaySleepLease.acquire) {
        self.acquire = acquire
    }

    func beginSession(_ requestID: UUID) {
        guard self.requestID != requestID else { return }
        lease = nil
        self.requestID = requestID
        finished = false
        hasPlayedVideo = false
        attemptedAcquisition = false
    }

    func update(_ snapshot: PlayerSnapshot, requestID: UUID) {
        guard self.requestID == requestID, !finished, !suspended else { return }
        let needsDisplay: Bool
        switch snapshot.status {
        case .playing:
            hasPlayedVideo = (snapshot.videoWidth > 0 && snapshot.videoHeight > 0)
                || snapshot.tracks.contains { $0.type == .video && $0.isSelected }
            needsDisplay = hasPlayedVideo
        case .buffering:
            // Retain protection during an active video's cache refill/seek,
            // but never acquire it for an unconfirmed initial load.
            needsDisplay = hasPlayedVideo && lease != nil
        case .paused, .idle, .loading, .ended:
            hasPlayedVideo = false
            needsDisplay = false
        case .stopped, .failed:
            finishSession(requestID)
            return
        }
        if needsDisplay {
            guard lease == nil, !attemptedAcquisition else { return }
            attemptedAcquisition = true
            lease = acquire()
        } else {
            lease = nil
            attemptedAcquisition = false
        }
    }

    func mediaLoaded(_ requestID: UUID) {
        guard self.requestID == requestID else { return }
        // A retry can load new media under the same request. Only its owned
        // file-loaded boundary, not a late playing snapshot, may rearm it.
        finished = false
        hasPlayedVideo = false
        attemptedAcquisition = false
        lease = nil
    }

    func finishSession(_ requestID: UUID) {
        guard self.requestID == requestID else { return }
        finished = true
        hasPlayedVideo = false
        lease = nil
    }

    func playbackEnded(_ requestID: UUID) {
        // keep-open retains the media: a later seek back can resume this
        // same request without another file-loaded event.
        update(PlayerSnapshot(status: .ended), requestID: requestID)
    }

    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        if suspended {
            lease = nil
            hasPlayedVideo = false
            attemptedAcquisition = false
        }
        // Wake alone must not reacquire; wait for a current playing snapshot.
    }
}
