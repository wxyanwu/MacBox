import Foundation
import XCTest
@testable import AndroidRuntimeKit

final class RuntimeMaintenanceTests: XCTestCase {
    private struct Fixture {
        let support: URL
        let layout: AndroidRuntimeLayout
        let catalog: RuntimeCatalog
        let generation: RuntimeGenerationDescriptor
        let download: String
        var generationPath: String { "Generations/" + generation.generationID.rawValue }
        func service(lifetime: TimeInterval = 120, checkpoint: @escaping @Sendable (String) throws -> Void = { _ in }) -> RuntimeMaintenanceService {
            RuntimeMaintenanceService(applicationSupportDirectory: support, catalog: catalog, planLifetime: lifetime, checkpoint: checkpoint)
        }
        func write(_ relative: String, _ contents: String) throws {
            let url = layout.root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: layout.root.appendingPathComponent(path).path) }
    }
    private func fixture() throws -> Fixture {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedUninstallTests-" + UUID().uuidString).resolvingSymlinksInPath()
        let layout = AndroidRuntimeLayout(applicationSupportDirectory: support)
        let catalog = try BundledRuntimeCatalog.load()
        let generation = try XCTUnwrap(catalog.generations.first)
        let component = try XCTUnwrap(generation.components.first)
        let download = "Downloads/\(component.sha256)-\(component.id).artifact"
        let fixture = Fixture(support: support, layout: layout, catalog: catalog, generation: generation, download: download)
        try fixture.write(fixture.generationPath + "/sdk/emulator/emulator", "owned-runtime")
        try fixture.write(fixture.generationPath + "/jre/bin/java", "owned-java")
        let manifest = RuntimeGenerationManifest(generationID: generation.generationID,
            catalogVersion: catalog.catalogVersion, runtimeSchema: generation.runtimeSchema,
            avdSchema: generation.avdSchema, bridgeSchema: generation.bridgeSchema,
            installedAt: Date(), components: generation.components.map { InstalledRuntimeComponent(id: $0.id, role: $0.role, version: $0.version, relativePath: "sdk/" + $0.id, sha256: $0.sha256) })
        try JSONEncoder().encode(manifest).write(to: layout.generation(generation.generationID).manifest)
        try JSONEncoder().encode(CurrentRuntimePointer(generationID: generation.generationID, activatedAt: Date())).write(to: layout.currentRuntimePointer)
        try fixture.write(download, "cached-download")
        try fixture.write("avd/OKVideoMac_Runtime.avd/userdata-qemu.img", "KEEP-LOGIN")
        try fixture.write("avd/OKVideoMac_Runtime.avd/encryptionkey.img", "KEEP-ENCRYPTION")
        try fixture.write("avd/OKVideoMac_Runtime.ini", "KEEP-DEFINITION")
        try fixture.write("home/.android/adbkey", "KEEP-KEY")
        try fixture.write("Backups/OKVideoMac_Runtime-old/userdata", "KEEP-BACKUP")
        try fixture.write("runtime-selection.json", "{\"schemaVersion\":1,\"mode\":\"external\",\"externalSDKRoot\":\"/external-sdk\",\"revision\":2}")
        addTeardownBlock { try? FileManager.default.removeItem(at: support) }
        return fixture
    }
    private func assertDataKept(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        for (path, value) in [("avd/OKVideoMac_Runtime.avd/userdata-qemu.img", "KEEP-LOGIN"),
                              ("avd/OKVideoMac_Runtime.avd/encryptionkey.img", "KEEP-ENCRYPTION"),
                              ("home/.android/adbkey", "KEEP-KEY"),
                              ("Backups/OKVideoMac_Runtime-old/userdata", "KEEP-BACKUP")] {
            XCTAssertEqual(try String(contentsOf: f.layout.root.appendingPathComponent(path)), value, file: file, line: line)
        }
        XCTAssertTrue(f.exists("runtime-selection.json"), file: file, line: line)
        XCTAssertTrue(f.exists("avd/OKVideoMac_Runtime.ini"), file: file, line: line)
    }
    func testDryRunIsReadOnlyAndExcludesUserDataAndExternalPaths() async throws {
        let f = try fixture(), service = f.service()
        let before = try FileManager.default.subpathsOfDirectory(atPath: f.support.path).sorted()
        let plan = try await service.prepareManagedUninstall()
        XCTAssertEqual(Set(plan.items.map(\.relativePath)), [f.generationPath, f.download, "current-runtime.json"])
        XCTAssertEqual(plan.userDataPolicy, "KEEP")
        XCTAssertEqual(plan.externalSDKPolicy, "EXCLUDED")
        XCTAssertGreaterThan(plan.estimatedReclaimBytes, 0)
        XCTAssertEqual(before, try FileManager.default.subpathsOfDirectory(atPath: f.support.path).sorted())
        let diagnostic = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        XCTAssertFalse(diagnostic.contains(f.support.path))
        XCTAssertFalse(diagnostic.contains("/external-sdk"))
        XCTAssertFalse(diagnostic.contains("KEEP-KEY"))
    }
    func testUninstallKeepsUserDataSelectionAndAVDBackups() async throws {
        let f = try fixture(), service = f.service()
        let selection = try Data(contentsOf: f.layout.root.appendingPathComponent("runtime-selection.json"))
        let plan = try await service.prepareManagedUninstall()
        let result = try await service.execute(planID: plan.id, quiesce: {})
        XCTAssertFalse(result.cleanupPending)
        XCTAssertFalse(f.exists(f.generationPath))
        XCTAssertFalse(f.exists(f.download))
        XCTAssertFalse(f.exists("current-runtime.json"))
        XCTAssertEqual(AndroidRuntimeDetector(layout: f.layout).detect().status, .notInstalled)
        XCTAssertEqual(selection, try Data(contentsOf: f.layout.root.appendingPathComponent("runtime-selection.json")))
        try assertDataKept(f)
        try RuntimeMaintenanceService.requireNoPendingTransaction(layout: f.layout)
        do { _ = try await service.execute(planID: plan.id, quiesce: {}); XCTFail("reused plan") }
        catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .expiredPlan) }
    }
    func testInvalidExternalSelectionCannotPrepareDeletion() async throws {
        for path in [nil, "", "relative/sdk"] as [String?] {
            let f = try fixture(), service = f.service()
            var selection: [String: Any] = ["schemaVersion": 1, "mode": "external"]
            selection["externalSDKRoot"] = path
            try JSONSerialization.data(withJSONObject: selection).write(to: f.layout.root.appendingPathComponent("runtime-selection.json"))
            do { _ = try await service.prepareManagedUninstall(); XCTFail("invalid external selection") }
            catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .unsafePath) }
            XCTAssertTrue(f.exists(f.generationPath))
            XCTAssertFalse(f.exists("Maintenance"))
        }
    }
    func testExpiredPlanCannotExecute() async throws {
        let f = try fixture(), service = f.service(lifetime: -1)
        let plan = try await service.prepareManagedUninstall()
        do { _ = try await service.execute(planID: plan.id, quiesce: {}); XCTFail() }
        catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .expiredPlan) }
        XCTAssertTrue(f.exists(f.generationPath))
    }
    func testChangingFilesOrModeInvalidatesPlanWithoutExpandingIt() async throws {
        for modeChange in [false, true] {
            let f = try fixture(), service = f.service()
            let plan = try await service.prepareManagedUninstall()
            if modeChange { try f.write("runtime-selection.json", "{\"schemaVersion\":1,\"mode\":\"managed\",\"revision\":3}") }
            else { try f.write(f.generationPath + "/sdk/new-file", "new") }
            do { _ = try await service.execute(planID: plan.id, quiesce: {}); XCTFail() }
            catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .changed) }
            XCTAssertTrue(f.exists("current-runtime.json"))
            XCTAssertFalse(f.exists("Maintenance"))
            try assertDataKept(f)
        }
    }
    func testStopFailureNeverMovesOrDeletesFiles() async throws {
        let f = try fixture(), service = f.service()
        let plan = try await service.prepareManagedUninstall()
        do {
            _ = try await service.execute(planID: plan.id) { throw RuntimeMaintenanceError.sessionNotStopped }
            XCTFail()
        } catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .sessionNotStopped) }
        XCTAssertTrue(f.exists(f.generationPath))
        XCTAssertFalse(f.exists("Maintenance"))
        try assertDataKept(f)
    }
    func testInstallerLeaseExcludesUninstallBeforeStop() async throws {
        let f = try fixture(), service = f.service()
        let plan = try await service.prepareManagedUninstall()
        let lease = try RuntimeMaintenanceLease(layout: f.layout)
        defer { withExtendedLifetime(lease) {} }
        do { _ = try await service.execute(planID: plan.id) { XCTFail("must not stop") }; XCTFail() }
        catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .busy) }
        XCTAssertTrue(f.exists(f.download))
    }
    func testRootAndCategorySymlinksCannotReachExternalData() async throws {
        for rootLink in [false, true] {
            let f = try fixture()
            let outside = f.support.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("EXTERNAL".utf8).write(to: outside.appendingPathComponent("sentinel"))
            let target = rootLink ? f.layout.root : f.layout.downloads
            let saved = f.support.appendingPathComponent("Saved-" + UUID().uuidString)
            try FileManager.default.moveItem(at: target, to: saved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            do { _ = try await f.service().prepareManagedUninstall(); XCTFail() }
            catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .unsafePath) }
            XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("sentinel")), "EXTERNAL")
        }
    }
    func testInternalCategoryEscapeSymlinkIsRejected() async throws {
        let f = try fixture()
        try FileManager.default.createSymbolicLink(at: f.layout.root.appendingPathComponent(f.generationPath + "/sdk/userdata-link"), withDestinationURL: f.layout.avdHome)
        do { _ = try await f.service().prepareManagedUninstall(); XCTFail() }
        catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .unsafePath) }
        try assertDataKept(f)
    }
    func testExternalSDKOverlappingGenerationIsExcluded() async throws {
        let f = try fixture()
        let selection: [String: Any] = ["schemaVersion": 1, "mode": "external", "externalSDKRoot": f.layout.generation(f.generation.generationID).sdk.path]
        try JSONSerialization.data(withJSONObject: selection).write(to: f.layout.root.appendingPathComponent("runtime-selection.json"))
        do { _ = try await f.service().prepareManagedUninstall(); XCTFail() }
        catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .unsafePath) }
        XCTAssertTrue(f.exists(f.generationPath))
    }
    func testFailureBeforeCommitRestoresPointerAndFiles() async throws {
        let f = try fixture()
        let service = f.service { point in if point == "beforeCommit" { throw RuntimeMaintenanceError.filesystem } }
        let plan = try await service.prepareManagedUninstall()
        do { _ = try await service.execute(planID: plan.id, quiesce: {}); XCTFail() } catch {}
        XCTAssertTrue(f.exists("current-runtime.json"))
        XCTAssertTrue(f.exists(f.generationPath))
        XCTAssertTrue(f.exists(f.download))
        try assertDataKept(f)
        try RuntimeMaintenanceService.requireNoPendingTransaction(layout: f.layout)
    }
    func testFailedRestoreRetainsQuarantineAndCanRecoverAfterRestart() async throws {
        let f = try fixture()
        let service = f.service { point in
            if point == "beforeCommit" || point.hasPrefix("beforeRestore:") { throw RuntimeMaintenanceError.filesystem }
        }
        let plan = try await service.prepareManagedUninstall()
        do { _ = try await service.execute(planID: plan.id, quiesce: {}); XCTFail() } catch {}
        XCTAssertTrue(f.exists("Maintenance/\(plan.id.uuidString)/quarantine/" + f.generationPath))
        XCTAssertThrowsError(try RuntimeMaintenanceService.requireNoPendingTransaction(layout: f.layout))
        _ = try await f.service().recover(quiesce: {})
        XCTAssertTrue(f.exists(f.generationPath))
        XCTAssertTrue(f.exists("current-runtime.json"))
        try assertDataKept(f)
        try RuntimeMaintenanceService.requireNoPendingTransaction(layout: f.layout)
    }
    func testPartialDeleteCanResumeAfterRestartWithoutTouchingUserData() async throws {
        let f = try fixture()
        let service = f.service { point in if point.hasPrefix("beforeDelete:Generations/") { throw RuntimeMaintenanceError.filesystem } }
        let plan = try await service.prepareManagedUninstall()
        let result = try await service.execute(planID: plan.id, quiesce: {})
        XCTAssertTrue(result.cleanupPending)
        XCTAssertFalse(f.exists("current-runtime.json"))
        XCTAssertThrowsError(try RuntimeMaintenanceLease(layout: f.layout))
        let resumed = try await f.service().recover(quiesce: {})
        XCTAssertEqual(resumed.count, 1)
        XCTAssertFalse(resumed[0].cleanupPending)
        try assertDataKept(f)
        try RuntimeMaintenanceService.requireNoPendingTransaction(layout: f.layout)
    }
    func testCorruptOrPathTraversalJournalNeverDeletes() async throws {
        let f = try fixture()
        let id = UUID().uuidString
        try f.write("Maintenance/" + id + "/transaction.json", "{\"schemaVersion\":1,\"relativePath\":\"../../avd\"}")
        do { _ = try await f.service().recover(quiesce: {}); XCTFail() }
        catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .corruptJournal) }
        try assertDataKept(f)
        XCTAssertTrue(f.exists(f.generationPath))
    }
    func testStorageIncludesHiddenPrivateKeysAndRetainedBackups() async throws {
        let f = try fixture()
        let storage = await f.service().storage()
        XCTAssertTrue(storage.isComplete)
        XCTAssertGreaterThan(storage.userDataBytes, 0)
        XCTAssertGreaterThan(storage.backupBytes, 0)
        XCTAssertGreaterThan(storage.componentBytes, 0)
        XCTAssertGreaterThan(storage.cacheBytes, 0)
    }
}

extension RuntimeMaintenanceTests {
    func testSafeInternalJRESymlinkIsUnlinkedWithoutFollowingIt() async throws {
        let f = try fixture(), service = f.service()
        let javaHome = f.layout.root.appendingPathComponent(f.generationPath + "/jre")
        try FileManager.default.createSymbolicLink(atPath: javaHome.appendingPathComponent("java-link").path, withDestinationPath: "bin/java")
        let plan = try await service.prepareManagedUninstall()
        let result = try await service.execute(planID: plan.id, quiesce: {})
        XCTAssertFalse(result.cleanupPending)
        XCTAssertFalse(f.exists(f.generationPath))
        try assertDataKept(f)
    }

    func testSnapshotReplacedAfterValidationDoesNotDeleteReplacement() async throws {
        let f = try fixture()
        let path = f.layout.root.appendingPathComponent(f.download)
        let saved = f.support.appendingPathComponent("saved-cache")
        let service = f.service { point in
            if point == "beforeMove:" + f.download {
                try FileManager.default.moveItem(at: path, to: saved)
                try Data("replacement".utf8).write(to: path)
            }
        }
        let plan = try await service.prepareManagedUninstall()
        do { _ = try await service.execute(planID: plan.id, quiesce: {}); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: path), "replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        try assertDataKept(f)
    }

    func testGenerationBackupIsRemovedButAVDAndUnknownBackupsRemain() async throws {
        let f = try fixture()
        let backup = "Backups/" + f.generation.generationID.rawValue + "-" + UUID().uuidString
        try FileManager.default.copyItem(at: f.layout.root.appendingPathComponent(f.generationPath), to: f.layout.root.appendingPathComponent(backup))
        try f.write("Backups/notes.txt", "user note")
        let service = f.service()
        let plan = try await service.prepareManagedUninstall()
        XCTAssertTrue(plan.items.contains { $0.relativePath == backup && $0.category == .backup })
        let result = try await service.execute(planID: plan.id, quiesce: {})
        XCTAssertFalse(result.cleanupPending)
        XCTAssertFalse(f.exists(backup))
        XCTAssertTrue(f.exists("Backups/notes.txt"))
        try assertDataKept(f)
        let diagnostics = await f.service().transactionDiagnostics()
        XCTAssertEqual(diagnostics.first?.plan.id, plan.id)
        XCTAssertEqual(diagnostics.first?.phase, "completed")
    }

    func testNewPlanInvalidatesOlderConfirmation() async throws {
        let f = try fixture(), service = f.service()
        let old = try await service.prepareManagedUninstall()
        _ = try await service.prepareManagedUninstall()
        do { _ = try await service.execute(planID: old.id, quiesce: {}); XCTFail() }
        catch { XCTAssertEqual(error as? RuntimeMaintenanceError, .expiredPlan) }
        XCTAssertTrue(f.exists(f.generationPath))
    }

    func testRecoveryRejectsWellFormedJournalTargetingUserdata() async throws {
        let f = try fixture()
        let service = f.service { point in if point.hasPrefix("beforeDelete:") { throw RuntimeMaintenanceError.filesystem } }
        let plan = try await service.prepareManagedUninstall()
        _ = try await service.execute(planID: plan.id, quiesce: {})
        let url = f.layout.root.appendingPathComponent("Maintenance/\(plan.id.uuidString)/transaction.json")
        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var editedPlan = try XCTUnwrap(journal["plan"] as? [String: Any])
        var items = try XCTUnwrap(editedPlan["items"] as? [[String: Any]])
        items[0]["relativePath"] = "Generations/../../avd"
        editedPlan["items"] = items; journal["plan"] = editedPlan
        try JSONSerialization.data(withJSONObject: journal).write(to: url)
        do { _ = try await f.service().recover(quiesce: {}); XCTFail() } catch {}
        try assertDataKept(f)
    }
}
