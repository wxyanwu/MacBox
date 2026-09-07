import Darwin
import Foundation

/// Arms a kernel-backed process-exit observation before the app begins its
/// cleanup-aware termination. This avoids guessing with a fixed sleep and
/// avoids confusing a reused PID after the original process has exited.
final class RelaunchParentExitMonitor: @unchecked Sendable {
    private let exitSemaphore = DispatchSemaphore(value: 0)
    private let exitSource: DispatchSourceProcess

    init(processIdentifier: pid_t) {
        exitSource = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        exitSource.setEventHandler { [exitSemaphore] in
            exitSemaphore.signal()
        }
        exitSource.resume()

        // The process can exit between argument validation and source setup.
        // Signalling here makes that race an immediate successful wait.
        if !Self.processExists(processIdentifier) {
            exitSemaphore.signal()
        }
    }

    deinit {
        exitSource.cancel()
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        exitSemaphore.wait(timeout: .now() + timeout) == .success
    }

    static func processExists(_ processIdentifier: pid_t) -> Bool {
        if Darwin.kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }
}
