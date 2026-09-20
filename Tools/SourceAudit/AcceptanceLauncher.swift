// Standalone local-acceptance launcher. Not linked into OKVideoMac.
import AppKit
import CryptoKit
import Darwin
import Foundation

private let acceptanceID = "com.okvideomac.OKVideoMac.acceptance8b3b"
private let fm = FileManager.default
private struct Refusal: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Refusal(message: message) }
}
private func canonical(_ url: URL) throws -> URL {
    guard let pointer = realpath(url.path, nil) else { throw Refusal(message: "路径不存在：\(url.path)") }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer))
}
private func sha(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
private struct FileFact: Codable, Equatable {
    let path: String
    let sha256: String?
    let link: String?
    let executable: Bool
}
private struct Manifest: Decodable {
    let schema: Int
    let phase: String
    let acceptanceOnly: Bool
    let publicReleaseEligible: Bool
    let bundleID: String
    let version: String
    let build: String
    let sourceSHA256: String
    let launcherSHA256: String
    let files: [FileFact]
}
private func inventory(_ root: URL) throws -> [FileFact] {
    var scanError: Error?
    guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                      errorHandler: { _, error in scanError = error; return false }) else {
        throw Refusal(message: "无法读取 App 清单。")
    }
    var result: [FileFact] = []
    for case let url as URL in iterator {
        let a = try fm.attributesOfItem(atPath: url.path)
        let kind = a[.type] as? FileAttributeType
        let path = String(url.path.dropFirst(root.path.count + 1))
        let executable = ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
        if kind == .typeSymbolicLink {
            let target = try canonical(url)
            try require(target.path.hasPrefix(root.path + "/"), "App 含指向外部的链接。")
            result.append(FileFact(path: path, sha256: nil,
                                   link: try fm.destinationOfSymbolicLink(atPath: url.path), executable: executable))
        } else if kind == .typeRegular {
            result.append(FileFact(path: path, sha256: try sha(url), link: nil, executable: executable))
        } else {
            try require(kind == .typeDirectory, "App 含不支持的文件类型。")
        }
    }
    if let scanError { throw scanError }
    return result.sorted { $0.path < $1.path }
}
@discardableResult
private func command(_ executable: String, _ arguments: [String]) throws -> String {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.standardOutput = pipe; task.standardError = pipe
    try task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    try require(task.terminationStatus == 0, "校验失败：\(executable)\n\(output)")
    return output
}
private func verifyApp(_ delivery: URL) throws -> URL {
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: delivery.appendingPathComponent("AcceptanceManifest.json")))
    try require(manifest.schema == 1 && manifest.phase == "8C.2-D" && manifest.acceptanceOnly
                && !manifest.publicReleaseEligible && manifest.bundleID == acceptanceID
                && manifest.version == "0.6.1" && manifest.build == "101", "不是本阶段的隔离验收 manifest。")
    let app = delivery.appendingPathComponent("OKVideoMac.app")
    try require(try canonical(app) == app, "App 必须位于交付目录内，不能是外部链接。")
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
    try require(info?["CFBundleIdentifier"] as? String == manifest.bundleID
                && info?["CFBundleShortVersionString"] as? String == manifest.version
                && info?["CFBundleVersion"] as? String == manifest.build, "App identity/version 不匹配。")
    let index = try JSONSerialization.jsonObject(with: Data(contentsOf: app.appendingPathComponent("Contents/Resources/Legal/Compliance/SOURCE_RELEASE_INDEX.json"))) as? [String: Any]
    let provenance = index?["local_acceptance"] as? [String: Any]
    try require(provenance?["source_sha256"] as? String == manifest.sourceSHA256, "冻结源码摘要不匹配。")
    try require(try sha(delivery.appendingPathComponent("AcceptanceLauncher")) == manifest.launcherSHA256, "Launcher 摘要不匹配。")
    try require(try inventory(app) == manifest.files, "App 文件清单/摘要不匹配，拒绝启动。")
    try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    return app
}
private func verifyWorkspace(_ path: String) throws -> URL {
    let root = URL(fileURLWithPath: path)
    try require(!path.isEmpty && path == root.path && (try canonical(root)) == root
                && root.deletingLastPathComponent().path == "/private/tmp"
                && root.lastPathComponent.hasPrefix("OKVideoMac-8B3B-"), "隔离 root 必须是 /private/tmp/OKVideoMac-8B3B-* 的真实目录。")
    let a = try fm.attributesOfItem(atPath: root.path)
    try require(a[.type] as? FileAttributeType == .typeDirectory
                && (a[.posixPermissions] as? NSNumber)?.intValue == 0o700
                && (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
                && fm.isWritableFile(atPath: root.path), "隔离 root 必须归当前用户所有、权限 0700 且可写。")
    var scanError: Error?
    guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                      errorHandler: { _, error in scanError = error; return false }) else { throw Refusal(message: "隔离目录无法检查。") }
    for case let url as URL in iterator {
        let a = try fm.attributesOfItem(atPath: url.path)
        try require(a[.type] as? FileAttributeType != .typeSymbolicLink
                    && (try canonical(url)).path.hasPrefix(root.path + "/"), "隔离目录包含链接或越界路径。")
        if a[.type] as? FileAttributeType == .typeRegular {
            try require((a[.referenceCount] as? NSNumber)?.intValue == 1, "隔离目录包含硬链接。")
        }
    }
    if let scanError { throw scanError }
    for relative in ["Application Support", "Caches", "Application Support/Database"] {
        let url = root.appendingPathComponent(relative)
        if fm.fileExists(atPath: url.path) {
            let a = try fm.attributesOfItem(atPath: url.path)
            try require(a[.type] as? FileAttributeType == .typeDirectory && fm.isWritableFile(atPath: url.path), "必要目录不可写：\(relative)")
        }
    }
    for suffix in ["", "-wal", "-shm"] {
        let url = root.appendingPathComponent("Application Support/Database/OKVideoMac.sqlite3" + suffix)
        if fm.fileExists(atPath: url.path) {
            let a = try fm.attributesOfItem(atPath: url.path)
            try require(a[.type] as? FileAttributeType == .typeRegular
                        && (a[.posixPermissions] as? NSNumber)?.intValue == 0o600
                        && fm.isWritableFile(atPath: url.path), "验收 DB/WAL/SHM 类型、权限或可写性不符合要求。")
        }
    }
    return root
}
@MainActor
private func rejectRunningInstances() throws {
    // Also detects bare executable launches not registered in LaunchServices.
    let rows = try command("/bin/ps", ["-axo", "pid=,comm="])
    let conflicts = rows.split(separator: "\n").filter {
        let path = $0.trimmingCharacters(in: .whitespaces)
        return path.hasSuffix("/OKVideoMac") || path.hasSuffix("/OKVideoMac.app/Contents/MacOS/OKVideoMac")
    }
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier?.hasPrefix("com.okvideomac.OKVideoMac") == true
    }
    let descriptions = conflicts.map(String.init) + apps.map { "PID \($0.processIdentifier): \($0.executableURL?.path ?? "unknown executable")" }
    try require(descriptions.isEmpty, "已有正式、旧验收或当前验收实例；请自行退出后重试。不会自动关闭：\n" + descriptions.joined(separator: "\n"))
}

@main
struct AcceptanceLauncher {
    @MainActor static func main() async {
        do {
            let executable = try canonical(URL(fileURLWithPath: CommandLine.arguments[0]))
            let delivery = executable.deletingLastPathComponent()
            let args = Array(CommandLine.arguments.dropFirst())
            try require(args == [] || args == ["--initialize"] || args == ["--check"]
                        || (args.count == 2 && args[0] == "--root")
                        || (args.count == 3 && args[0] == "--check" && args[1] == "--root"),
                        "用法：AcceptanceLauncher [--initialize | --check | --root PATH | --check --root PATH]")
            let app = try verifyApp(delivery)
            try rejectRunningInstances()
            let config = delivery.appendingPathComponent("AcceptanceWorkspace.json")
            if args == ["--initialize"] {
                try require(!fm.fileExists(atPath: config.path), "已有隔离目录配置，不覆盖；请使用 Launch-8C2.command。")
                var template = Array("/private/tmp/OKVideoMac-8B3B-RouteD.XXXXXX".utf8CString)
                let path = try template.withUnsafeMutableBufferPointer { buffer -> String in
                    guard let pointer = mkdtemp(buffer.baseAddress) else { throw Refusal(message: "无法创建隔离目录。") }
                    return String(cString: pointer)
                }
                _ = try verifyWorkspace(path)
                let data = try JSONSerialization.data(withJSONObject: ["root": path], options: [.sortedKeys])
                try data.write(to: config, options: [.withoutOverwriting])
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
                print("已创建空的隔离验收目录：\(path)\n未复制私人账号或数据库。现在运行 Launch-8C2.command，再自行导入测试源。")
                return
            }
            let path: String
            if let flag = args.firstIndex(of: "--root") { path = args[flag + 1] }
            else {
                try require(fm.fileExists(atPath: config.path), "尚未配置隔离目录。先运行 Initialize-8C2.command；不会回退到正式数据库。")
                let value = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: String]
                path = value?["root"] ?? ""
            }
            let root = try verifyWorkspace(path)
            print("Gate PASS · 8C.2-D · 0.6.1 (101)\nApp: \(app.path)\nAcceptance root: \(root.path)")
            if args.first == "--check" { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            configuration.environment = ["OKVIDEOMAC_8B3B_ROOT": root.path]
            // No launchctl, inherited-session mutation, process kill, or fallback.
            let running: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: app, configuration: configuration) { instance, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let instance { continuation.resume(returning: instance) }
                    else { continuation.resume(throwing: Refusal(message: "启动没有返回实例。")) }
                }
            }
            let actual = try command("/bin/ps", ["-p", String(running.processIdentifier), "-o", "comm="])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = app.appendingPathComponent("Contents/MacOS/OKVideoMac").path
            try require(actual == expected, "启动后的实际 PID/path 不匹配，验收失败；不会自动杀进程。PID \(running.processIdentifier): \(actual)")
            print("启动已核对：PID \(running.processIdentifier)\nExecutable: \(actual)\n此结果仅证明进程启动；应用内容验收仍需检查窗口。")
        } catch {
            fputs("拒绝启动：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
