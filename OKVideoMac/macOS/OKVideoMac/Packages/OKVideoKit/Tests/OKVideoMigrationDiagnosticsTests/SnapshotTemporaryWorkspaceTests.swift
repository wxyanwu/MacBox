import Foundation
import Darwin
import XCTest
@testable import OKVideoMigrationDiagnostics

final class SnapshotTemporaryWorkspaceTests: XCTestCase {
    private let fm = FileManager.default

    func testOptimizedRepeatedCreationReturnsOwnedAbsolutePathsNotCWD() throws {
        var paths = Set<String>()
        for _ in 0..<64 {
            let workspace = try SnapshotTemporaryWorkspace.create()
            XCTAssertTrue(paths.insert(workspace.directory.path).inserted)
            XCTAssertTrue(workspace.directory.path.hasPrefix("/private/tmp/OKVideoMac-8B2-DryRun-"))
            XCTAssertNotEqual(workspace.directory.path, fm.currentDirectoryPath)
            XCTAssertNoThrow(try workspace.validateForCleanup())
            try workspace.remove()
            XCTAssertFalse(fm.fileExists(atPath: workspace.directory.path))
        }
    }

    func testEmptyRelativeBroadRootsHomeAndRepositoryPathsRejected() {
        for path in ["", ".", "..", "/", "/private/tmp", "/tmp", NSHomeDirectory(),
                     fm.currentDirectoryPath, URL(fileURLWithPath: #filePath).deletingLastPathComponent().path,
                     "OKVideoMac-8B2-DryRun-ABC123", "/private/tmp/OKVideoMac-8B2-DryRun-", "/private/tmp/OKVideoMac-8B2-DryRun-../../"] {
            XCTAssertThrowsError(try SnapshotTemporaryWorkspace.checkedDirectory(path))
        }
    }

    func testCWDOrItsAncestorRejectedEvenWithValidReceiptShape() throws {
        let workspace = try SnapshotTemporaryWorkspace.create()
        defer { try? workspace.remove() }
        XCTAssertThrowsError(try SnapshotTemporaryWorkspace.checkedDirectory(workspace.directory.path,
                                                                            currentDirectory: workspace.directory.path))
        XCTAssertThrowsError(try SnapshotTemporaryWorkspace.checkedDirectory(workspace.directory.path,
                                                                            currentDirectory: workspace.directory.path + "/child"))
    }

    func testMissingPathAliasAndUnresolvablePathRejected() throws {
        let workspace = try SnapshotTemporaryWorkspace.create()
        XCTAssertThrowsError(try SnapshotTemporaryWorkspace.checkedDirectory(workspace.directory.path + "/"))
        XCTAssertThrowsError(try SnapshotTemporaryWorkspace.checkedDirectory(workspace.directory.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")))
        try workspace.remove()
        XCTAssertThrowsError(try workspace.validateForCleanup())
        XCTAssertThrowsError(try workspace.remove()) // Repeated cleanup fails closed.
    }

    func testCreationDoesNotReuseAnExistingOwnedDirectory() throws {
        let first = try SnapshotTemporaryWorkspace.create(), second = try SnapshotTemporaryWorkspace.create()
        defer { try? first.remove(); try? second.remove() }
        let sentinel = first.directory.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testMissingOrWrongMarkerNeverDeletesDirectory() throws {
        let workspace = try SnapshotTemporaryWorkspace.create()
        let marker = workspace.directory.appendingPathComponent(SnapshotTemporaryWorkspace.markerName)
        let original = try Data(contentsOf: marker)
        // Only this exact marker file is mutated, never a recursive cleanup target.
        XCTAssertEqual(Darwin.unlink(marker.path), 0)
        XCTAssertThrowsError(try workspace.remove())
        try QuiescentDatabaseSnapshot.writePrivate(Data(repeating: 88, count: original.count), to: marker)
        XCTAssertThrowsError(try workspace.remove())
        XCTAssertTrue(fm.fileExists(atPath: workspace.directory.path))
        XCTAssertEqual(Darwin.unlink(marker.path), 0)
        try QuiescentDatabaseSnapshot.writePrivate(original, to: marker)
        try workspace.remove()
    }

    func testSymlinkMarkerRejectedWithoutTouchingTarget() throws {
        let workspace = try SnapshotTemporaryWorkspace.create(), other = try SnapshotTemporaryWorkspace.create()
        defer { try? other.remove() }
        let marker = workspace.directory.appendingPathComponent(SnapshotTemporaryWorkspace.markerName)
        let original = try Data(contentsOf: marker)
        let target = other.directory.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: target)
        XCTAssertEqual(Darwin.unlink(marker.path), 0)
        try fm.createSymbolicLink(at: marker, withDestinationURL: target)
        XCTAssertThrowsError(try workspace.remove())
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertEqual(Darwin.unlink(marker.path), 0)
        try QuiescentDatabaseSnapshot.writePrivate(original, to: marker)
        try workspace.remove()
    }

    func testRootSymlinkAndReplacementInodeRejected() throws {
        let original = try SnapshotTemporaryWorkspace.create(), container = try SnapshotTemporaryWorkspace.create()
        defer { try? container.remove() }
        let parked = container.directory.appendingPathComponent("parked")
        try fm.moveItem(at: original.directory, to: parked)
        try fm.createSymbolicLink(at: original.directory, withDestinationURL: parked)
        XCTAssertThrowsError(try original.remove())
        XCTAssertTrue(fm.fileExists(atPath: parked.path))
        XCTAssertEqual(Darwin.unlink(original.directory.path), 0)
        // A different real directory with the same marker still isn't the owned inode.
        try fm.createDirectory(at: original.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let marker = try Data(contentsOf: parked.appendingPathComponent(SnapshotTemporaryWorkspace.markerName))
        try QuiescentDatabaseSnapshot.writePrivate(marker, to: original.directory.appendingPathComponent(SnapshotTemporaryWorkspace.markerName))
        XCTAssertThrowsError(try original.remove())
        try fm.moveItem(at: original.directory, to: container.directory.appendingPathComponent("replacement"))
        try fm.moveItem(at: parked, to: original.directory)
        try original.remove()
    }

    func testRecursiveCleanupDoesNotFollowNestedSymlink() throws {
        let workspace = try SnapshotTemporaryWorkspace.create(), other = try SnapshotTemporaryWorkspace.create()
        defer { try? other.remove() }
        let target = other.directory.appendingPathComponent("keep")
        try Data("still here".utf8).write(to: target)
        try fm.createSymbolicLink(at: workspace.directory.appendingPathComponent("outside"), withDestinationURL: other.directory)
        try workspace.remove()
        XCTAssertEqual(try Data(contentsOf: target), Data("still here".utf8))
    }

    func testDirectoryPermissionsAndRepositoryMarkersFailClosed() throws {
        let workspace = try SnapshotTemporaryWorkspace.create()
        defer { try? workspace.remove() }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.directory.path)
        XCTAssertThrowsError(try workspace.remove())
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.directory.path)
        for name in [".git", "Package.swift", "AGENTS.md"] {
            let marker = workspace.directory.appendingPathComponent(name)
            try Data().write(to: marker)
            XCTAssertThrowsError(try workspace.remove())
            XCTAssertEqual(Darwin.unlink(marker.path), 0)
        }
    }

    func testExceptionDoesNotImplicitlyDeleteOrTransferOwnership() throws {
        enum Injected: Error { case failed }
        let workspace = try SnapshotTemporaryWorkspace.create()
        XCTAssertThrowsError(try { () throws -> Void in
            try Data("partial".utf8).write(to: workspace.directory.appendingPathComponent("partial.sqlite3"))
            throw Injected.failed
        }())
        XCTAssertNoThrow(try workspace.validateForCleanup())
        XCTAssertTrue(fm.fileExists(atPath: workspace.directory.appendingPathComponent("partial.sqlite3").path))
        try workspace.remove()
    }
}
