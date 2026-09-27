import Foundation
import XCTest
@testable import AndroidRuntimeKit

final class RuntimeCompressedStorageTests: XCTestCase {
    func testLayoutKeepsContainerAndMutableUserDataOutsideMount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AndroidRuntimeLayout(runtimeRoot: root)
        let id = RuntimeGenerationID(rawValue: "fixture-v1")
        let expanded = layout.generation(id)
        XCTAssertFalse(expanded.isCompressed)
        XCTAssertEqual(expanded.payloadRoot, expanded.root)
        try FileManager.default.createDirectory(at: expanded.root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: expanded.root.appendingPathComponent(RuntimeCompressedStorage.manifestName))
        let compressed = layout.generation(id)
        XCTAssertTrue(compressed.isCompressed)
        XCTAssertEqual(compressed.root, expanded.root)
        XCTAssertEqual(compressed.manifest, expanded.manifest)
        XCTAssertEqual(compressed.payloadRoot, layout.mountPoint(id))
        XCTAssertFalse(layout.avdDirectory.path.hasPrefix(layout.mounts.path + "/"))
        XCTAssertFalse(layout.privateAndroidHome.path.hasPrefix(layout.mounts.path + "/"))
    }

    func testRefusesDestinationInsideSourceAndExistingDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try fixture(source)
        let store = try RuntimeCompressedStorage(root: root)
        for target in [source, source.appendingPathComponent("child")] {
            do {
                _ = try await store.create(source: source, destination: target)
                XCTFail("Unsafe destination accepted")
            } catch {
                XCTAssertEqual(error as? RuntimeCompressedStorageError, .invalidLayout)
            }
        }
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("sdk/payload")), Data(repeating: 0x61, count: 1_048_576))
    }

    func testRefusesSymlinkEscape() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try fixture(source)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        let store = try RuntimeCompressedStorage(root: root)
        do {
            _ = try await store.create(source: source, destination: root.appendingPathComponent("outside/should-not-exist"))
            XCTFail("Escaping destination accepted")
        } catch {
            XCTAssertEqual(error as? ManagedRuntimePathError, .escapesManagedRoot)
        }
    }

    /// Explicit integration gate: real Apple disk-image tools, no mocked mount.
    /// Creates only a tiny test image and never touches the user's Runtime.
    func testRealImageRoundTripReadOnlyRestartAndCorruption() async throws {
        guard ProcessInfo.processInfo.environment["OKVIDEOMAC_COMPRESSED_RUNTIME_E2E"] == "1" else {
            throw XCTSkip("Enable OKVIDEOMAC_COMPRESSED_RUNTIME_E2E for real disk image lifecycle tests")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("okvideo-compressed-test-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let container = root.appendingPathComponent("container")
        let mountPoint = root.appendingPathComponent("mount")
        try fixture(source)
        let store = try RuntimeCompressedStorage(root: root)
        do {
            let manifest = try await store.create(source: source, destination: container)
            XCTAssertEqual(manifest.schemaVersion, 1)
            XCTAssertGreaterThan(manifest.imageBytes, 0)
            try await store.mount(container: container, at: mountPoint)
            XCTAssertEqual(try Data(contentsOf: mountPoint.appendingPathComponent("sdk/payload")),
                           try Data(contentsOf: source.appendingPathComponent("sdk/payload")))
            XCTAssertThrowsError(try Data([1]).write(to: mountPoint.appendingPathComponent("sdk/new-file")))

            // A new service instance must recognize an existing attachment.
            let restarted = try RuntimeCompressedStorage(root: root)
            // Existing-ancestor normalization can lose URL's directory hint.
            // Both spellings identify the same mount, including under /tmp.
            try await restarted.mount(container: container,
                at: URL(fileURLWithPath: mountPoint.path, isDirectory: false))
            try await restarted.unmount(container: container, at: mountPoint)
            try await restarted.mount(container: container, at: mountPoint)
            XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("jre/payload").path))
            try await restarted.unmount(container: container, at: mountPoint)

            // Disk corruption must fail before attachment, not launch a guest.
            let image = container.appendingPathComponent(RuntimeCompressedStorage.imageName)
            let handle = try FileHandle(forWritingTo: image)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            do {
                try await restarted.mount(container: container, at: mountPoint)
                XCTFail("Modified image accepted")
            } catch {
                XCTAssertEqual(error as? RuntimeCompressedStorageError, .imageChanged)
            }
            try FileManager.default.removeItem(at: root)
        } catch {
            try? await store.unmount(container: container, at: mountPoint)
            // Keep a failed fixture for diagnosis; never remove a busy mount.
            throw error
        }
    }

    private func fixture(_ source: URL) throws {
        for name in ["sdk", "jre"] {
            let directory = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: 1_048_576).write(to: directory.appendingPathComponent("payload"))
        }
        try Data("{}".utf8).write(to: source.appendingPathComponent("generation-manifest.json"))
    }
}
