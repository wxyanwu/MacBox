import AppKit
import Darwin
import Foundation

private struct RelaunchArguments {
    let parentProcessIdentifier: pid_t
    let bundleURL: URL
    let bundleIdentifier: String
    let handshakeToken: String

    init?(_ arguments: [String]) {
        var values: [String: String] = [:]
        var index = 1
        while index + 1 < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), values[key] == nil else { return nil }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard index == arguments.count,
              let rawPID = values["--parent-pid"],
              let parentProcessIdentifier = pid_t(rawPID),
              parentProcessIdentifier > 0,
              let bundlePath = values["--bundle-path"],
              !bundlePath.isEmpty,
              let bundleIdentifier = values["--bundle-id"],
              !bundleIdentifier.isEmpty,
              let handshakeToken = values["--handshake-token"],
              !handshakeToken.isEmpty else { return nil }
        self.parentProcessIdentifier = parentProcessIdentifier
        bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.handshakeToken = handshakeToken
    }
}

private enum ExitCode: Int32 {
    case invalidArguments = 64
    case invalidParent = 65
    case invalidBundle = 66
    case parentTimeout = 67
    case relaunchFailed = 68
}

private func hasRelaunchedApplication(
    bundleIdentifier: String,
    excluding oldProcessIdentifier: pid_t
) -> Bool {
    NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
    ).contains {
        !$0.isTerminated && $0.processIdentifier != oldProcessIdentifier
    }
}

private func runOpen(bundleURL: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [bundleURL.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    } catch {
        return false
    }
}

private func waitForRelaunchedApplication(
    bundleIdentifier: String,
    excluding oldProcessIdentifier: pid_t,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if hasRelaunchedApplication(
            bundleIdentifier: bundleIdentifier,
            excluding: oldProcessIdentifier
        ) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.10)
    } while Date() < deadline
    return false
}

guard let arguments = RelaunchArguments(ProcessInfo.processInfo.arguments) else {
    exit(ExitCode.invalidArguments.rawValue)
}
guard getppid() == arguments.parentProcessIdentifier,
      let parentApplication = NSRunningApplication(
        processIdentifier: arguments.parentProcessIdentifier
      ),
      parentApplication.bundleIdentifier == arguments.bundleIdentifier else {
    exit(ExitCode.invalidParent.rawValue)
}
guard arguments.bundleURL.pathExtension.lowercased() == "app",
      let applicationBundle = Bundle(url: arguments.bundleURL),
      applicationBundle.bundleIdentifier == arguments.bundleIdentifier else {
    exit(ExitCode.invalidBundle.rawValue)
}

// Arm the process source before acknowledging readiness. The app will not
// request termination until this handshake has been received.
let parentExitMonitor = RelaunchParentExitMonitor(
    processIdentifier: arguments.parentProcessIdentifier
)

let handshake = "READY \(arguments.handshakeToken)\n"
FileHandle.standardOutput.write(Data(handshake.utf8))
try? FileHandle.standardOutput.synchronize()
try? FileHandle.standardOutput.close()

guard parentExitMonitor.waitForExit(timeout: 30) else {
    exit(ExitCode.parentTimeout.rawValue)
}

// The process exit closes the application-wide advisory lock. Give
// LaunchServices one short scheduling turn before requesting the exact bundle.
Thread.sleep(forTimeInterval: 0.15)
for _ in 0..<3 {
    if hasRelaunchedApplication(
        bundleIdentifier: arguments.bundleIdentifier,
        excluding: arguments.parentProcessIdentifier
    ) {
        exit(EXIT_SUCCESS)
    }
    if runOpen(bundleURL: arguments.bundleURL),
       waitForRelaunchedApplication(
        bundleIdentifier: arguments.bundleIdentifier,
        excluding: arguments.parentProcessIdentifier,
        timeout: 5
       ) {
        exit(EXIT_SUCCESS)
    }
    Thread.sleep(forTimeInterval: 0.50)
}
exit(ExitCode.relaunchFailed.rawValue)
