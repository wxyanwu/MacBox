import Foundation
import XCTest
import Darwin
@_spi(XMLTVStreaming) @testable import OKVideoCore

final class XMLTVStagingFileTests: XCTestCase {
    // Test receipts only. No recursive deletion, directory enumeration, or
    // caller-selected cleanup root. Every removed node was created by this test.
    final class Fixture {
        struct Node { let parent: Int32; let name: String; let info: stat; let directory: Bool }
        let path: String, fd: Int32, identity: stat
        private var nodes: [Node] = []
        private var extraFDs: [Int32] = []
        private var ownerMarker: stat!
        private var cleaned = false
        init() throws {
            var template = Array("/private/tmp/OKVideoMac-9B.XXXXXX".utf8CString)
            path = try template.withUnsafeMutableBufferPointer {
                guard let p = mkdtemp($0.baseAddress!) else { throw POSIXError(.EIO) }
                return String(cString: p) // copied while C storage is pinned
            }
            fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var info = stat(); guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
            identity = info
            try createFile(parent: fd, name: ".owner", data: Data(UUID().uuidString.utf8))
            ownerMarker = nodes.last!.info
        }
        func track(parent: Int32, name: String, directory: Bool = false) throws {
            precondition(!name.contains("/") && name != "." && name != "..")
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.EIO) }
            nodes.append(Node(parent: parent, name: name, info: info, directory: directory))
        }
        func capture(_ file: XMLTVStagingFile) throws -> XMLTVFileTestReceipt {
            let r = file.testReceipt
            try track(parent: fd, name: r.directoryName, directory: true)
            let held = dup(r.directoryFD); guard held >= 0 else { throw POSIXError(.EIO) }
            extraFDs.append(held)
            try track(parent: held, name: "payload")
            return r
        }
        func hold(_ fd: Int32) throws -> Int32 {
            let copy = dup(fd); guard copy >= 0 else { throw POSIXError(.EIO) }
            extraFDs.append(copy); return copy
        }
        func createFile(parent: Int32, name: String, data: Data = Data("stranger".utf8)) throws {
            let file = openat(parent, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(file) }
            try track(parent: parent, name: name)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw POSIXError(.EIO) }
                    offset += n
                }
            }
        }
        func clean() throws {
            guard !cleaned else { return }; cleaned = true
            defer { for handle in extraFDs { Darwin.close(handle) }; Darwin.close(fd) }
            var root = stat(), marker = stat()
            guard path.hasPrefix("/private/tmp/OKVideoMac-9B."), lstat(path, &root) == 0,
                  root.st_dev == identity.st_dev, root.st_ino == identity.st_ino,
                  root.st_mode & S_IFMT == S_IFDIR, root.st_uid == geteuid(),
                  fstatat(fd, ".owner", &marker, AT_SYMLINK_NOFOLLOW) == 0,
                  marker.st_dev == ownerMarker.st_dev, marker.st_ino == ownerMarker.st_ino else { throw POSIXError(.EPERM) }
            // Files first, then empty directories. Foreign/replaced entries are
            // never removed merely because they occupy an expected path.
            let ordered = Array(nodes.filter({ !$0.directory }).reversed()) + Array(nodes.filter({ $0.directory }).reversed())
            for node in ordered {
                var current = stat()
                if fstatat(node.parent, node.name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { continue }; throw POSIXError(.EIO)
                }
                if current.st_dev != node.info.st_dev || current.st_ino != node.info.st_ino { continue }
                guard unlinkat(node.parent, node.name, node.directory ? AT_REMOVEDIR : 0) == 0 else { throw POSIXError(.EIO) }
            }
            guard rmdir(path) == 0 else { throw POSIXError(.ENOTEMPTY) }
        }
        deinit { if !cleaned { for handle in extraFDs { Darwin.close(handle) }; Darwin.close(fd) } }
    }
    func root() throws -> Fixture {
        let value = try Fixture()
        addTeardownBlock { try value.clean() }
        return value
    }
    func actualWrite(_ fd: Int32, _ p: UnsafeRawPointer, _ count: Int) throws -> Int {
        let n = Darwin.write(fd, p, count)
        if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; return n
    }
    func missing(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) != 0 && errno == ENOENT }
    func assertClosed(_ r: XMLTVFileTestReceipt, file: StaticString = #filePath, line: UInt = #line) {
        for fd in [r.fileFD,r.directoryFD,r.rootFD] {
            XCTAssertEqual(fcntl(fd,F_GETFD), -1, file: file, line: line)
            XCTAssertEqual(errno, EBADF, file: file, line: line)
        }
    }
    func testCreatePermissionsAndExplicitReleaseWhileObjectAlive() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in: r.path)
        let receipt = try r.capture(file)
        var d = stat(), f = stat()
        XCTAssertEqual(fstat(receipt.directoryFD,&d),0); XCTAssertEqual(fstat(receipt.fileFD,&f),0)
        XCTAssertEqual(d.st_mode & 0o777,0o700); XCTAssertEqual(f.st_mode & 0o777,0o600)
        XCTAssertEqual(f.st_nlink,1)
        try file.release(); try file.release()
        XCTAssertTrue(missing(r.path+"/"+receipt.directoryName)); XCTAssertNil(file.cleanupIssue)
        assertClosed(receipt)
    }
    func testRoundTripTransferAndOldOwnerHasNoAuthority() throws {
        let r = try root(), writer = try XMLTVStagingFile.create(in: r.path)
        let receipt = try r.capture(writer), data = Data("节目📺".utf8)
        try writer.write(data)
        let reader = try writer.finishAndTransfer()
        XCTAssertThrowsError(try writer.write(Data()))
        XCTAssertThrowsError(try writer.finishAndTransfer())
        XCTAssertThrowsError(try writer.release()) { XCTAssertEqual($0 as? XMLTVFileError,.inactiveOwner) }
        XCTAssertEqual(try reader.read(),data); XCTAssertEqual(try reader.read(),Data())
        try reader.release(); try reader.release()
        XCTAssertTrue(missing(r.path+"/"+receipt.directoryName))
    }
    func testWriterDeinitCannotDeleteTransferredFile() throws {
        let r = try root()
        var writer: XMLTVStagingFile? = try XMLTVStagingFile.create(in: r.path)
        let receipt = try r.capture(writer!)
        try writer!.write(Data([1,2,3])); let reader = try writer!.finishAndTransfer()
        writer = nil
        XCTAssertFalse(missing(r.path+"/"+receipt.directoryName+"/payload"))
        XCTAssertEqual(try reader.read(),Data([1,2,3])); try reader.release()
    }
    func testTransferredDescriptorIsReadOnlyAndReadsAreBounded() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in: r.path)
        _ = try r.capture(file); try file.write(Data([1,2,3]))
        let reader = try file.finishAndTransfer(), fd = file.testReceipt.fileFD
        XCTAssertEqual(fcntl(fd,F_GETFL) & O_ACCMODE,O_RDONLY)
        XCTAssertThrowsError(try reader.read(maximumBytes: 65_537))
        XCTAssertEqual(try reader.read(maximumBytes: 2),Data([1,2]))
        XCTAssertEqual(try reader.read(maximumBytes: 2),Data([3]))
        try reader.release(); XCTAssertThrowsError(try reader.read())
    }
    func testPartialWritesAndEINTRPreserveEveryByte() throws {
        let r = try root(); var calls = 0
        let file = try XMLTVStagingFile.create(in: r.path, write: { fd,p,n in
            calls += 1
            if calls == 2 || calls == 4 { throw POSIXError(.EINTR) }
            return try self.actualWrite(fd,p,min(n,3))
        })
        _ = try r.capture(file)
        let data = Data((0..<91).map(UInt8.init)); try file.write(data)
        let reader = try file.finishAndTransfer()
        XCTAssertEqual(try reader.read(),data); XCTAssertGreaterThan(calls,30); try reader.release()
    }
    func testPartialThenENOSPCOrEIOCannotTransferAndClosesAllFDs() throws {
        for error in [POSIXErrorCode.ENOSPC,.EIO] {
            let r = try root(); var calls = 0
            let file = try XMLTVStagingFile.create(in: r.path, write: { fd,p,n in
                calls += 1
                if calls == 3 { throw POSIXError(error) }
                return try self.actualWrite(fd,p,min(n,calls == 1 ? 30 : 20))
            })
            let receipt = try r.capture(file)
            XCTAssertThrowsError(try file.write(Data(repeating: 42,count: 100))) { XCTAssertEqual(($0 as? POSIXError)?.code,error) }
            XCTAssertEqual(calls,3); assertClosed(receipt)
            XCTAssertThrowsError(try file.finishAndTransfer())
            try file.release(); try file.release()
            XCTAssertTrue(missing(r.path+"/"+receipt.directoryName))
        }
    }
    func testZeroProgressAndInvalidWriteCountFailClosed() throws {
        for returned in [0,-1,100] {
            let r = try root(), file = try XMLTVStagingFile.create(in: r.path,write: { _,_,_ in returned })
            let receipt = try r.capture(file)
            XCTAssertThrowsError(try file.write(Data([1,2,3])))
            assertClosed(receipt); XCTAssertThrowsError(try file.finishAndTransfer()); try file.release()
        }
    }
    func testWritesAreChunkedWithoutRetainingUnboundedQueue() throws {
        let r = try root(); var sizes: [Int] = []
        let file = try XMLTVStagingFile.create(in:r.path,write: { fd,p,n in sizes.append(n); return try self.actualWrite(fd,p,n) })
        _ = try r.capture(file); try file.write(Data(repeating: 65,count: 200_000))
        XCTAssertEqual(sizes,[65_536,65_536,65_536,3392]); try file.release()
    }
    func testByteLimitExactAndOneOverAcrossWrites() throws {
        let r = try root(), a = try XMLTVStagingFile.create(in:r.path,maximumBytes:3)
        _ = try r.capture(a); try a.write(Data([1,2])); try a.write(Data([3]))
        let reader = try a.finishAndTransfer(); XCTAssertEqual(try reader.read(),Data([1,2,3])); try reader.release()
        let b = try XMLTVStagingFile.create(in:r.path,maximumBytes:3), receipt = try r.capture(b)
        try b.write(Data([1,2]))
        XCTAssertThrowsError(try b.write(Data([3,4]))) { XCTAssertEqual($0 as? XMLTVFileError,.byteLimit) }
        assertClosed(receipt); try b.release()
    }
    func testUnsafeRootsAndInvalidBudgetsRejected() throws {
        let r = try root()
        let nonexistent = "/private/tmp/OKVideoMac-9B."+UUID().uuidString.replacingOccurrences(of:"-",with:"")
        for path in ["",".","..","/","/private/tmp",NSHomeDirectory(),FileManager.default.currentDirectoryPath,r.path+"/.",r.path+"/../bad",nonexistent] {
            XCTAssertThrowsError(try XMLTVStagingFile.create(in:path))
        }
        for limit in [0,-1,32*1_024*1_024+1,Int.max] {
            XCTAssertThrowsError(try XMLTVStagingFile.create(in:r.path,maximumBytes:limit))
        }
    }
    func testRootPermissionsAndCheckoutMarkerRejected() throws {
        let r = try root()
        XCTAssertEqual(fchmod(r.fd,0o755),0)
        XCTAssertThrowsError(try XMLTVStagingFile.create(in:r.path))
        XCTAssertEqual(fchmod(r.fd,0o700),0)
        try r.createFile(parent:r.fd,name:"AGENTS.md")
        XCTAssertThrowsError(try XMLTVStagingFile.create(in:r.path))
    }
    func testRootSymlinkRejected() throws {
        let r = try root(), parent = Darwin.open("/private/tmp",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(parent) }
        let held = try r.hold(parent), name = "OKVideoMac-9B."+UUID().uuidString.replacingOccurrences(of:"-",with:"")
        XCTAssertEqual(symlinkat(r.path,held,name),0); try r.track(parent:held,name:name)
        XCTAssertThrowsError(try XMLTVStagingFile.create(in:"/private/tmp/"+name))
    }
    func testReplacedFileNeverDeletedAndFDsClosed() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path), receipt = try r.capture(file)
        let dir = try r.hold(receipt.directoryFD)
        XCTAssertEqual(unlinkat(dir,"payload",0),0)
        try r.createFile(parent:dir,name:"payload")
        XCTAssertThrowsError(try file.release()) { XCTAssertEqual($0 as? XMLTVFileError,.ownershipMismatch) }
        assertClosed(receipt)
        XCTAssertFalse(missing(r.path+"/"+receipt.directoryName+"/payload"))
        XCTAssertThrowsError(try file.release()); XCTAssertNotNil(file.cleanupIssue)
    }
    func testPayloadSymlinkNeverFollowedOrDeleted() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path), receipt = try r.capture(file)
        let dir = try r.hold(receipt.directoryFD)
        try r.createFile(parent:r.fd,name:"outside")
        XCTAssertEqual(unlinkat(dir,"payload",0),0)
        XCTAssertEqual(symlinkat(r.path+"/outside",dir,"payload"),0); try r.track(parent:dir,name:"payload")
        XCTAssertThrowsError(try file.release()); assertClosed(receipt)
        XCTAssertFalse(missing(r.path+"/outside")); XCTAssertFalse(missing(r.path+"/"+receipt.directoryName+"/payload"))
    }
    func testExtraHardLinkBlocksCleanup() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path), receipt = try r.capture(file)
        XCTAssertEqual(linkat(receipt.directoryFD,"payload",r.fd,"second-link",0),0)
        try r.track(parent:r.fd,name:"second-link")
        XCTAssertThrowsError(try file.release()); assertClosed(receipt)
        XCTAssertFalse(missing(r.path+"/second-link"))
    }
    func testUnknownChildIsNotRecursivelyDeleted() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path), receipt = try r.capture(file)
        let dir = try r.hold(receipt.directoryFD)
        try r.createFile(parent:dir,name:"unrelated")
        XCTAssertThrowsError(try file.release()) { XCTAssertEqual($0 as? XMLTVFileError,.system(ENOTEMPTY)) }
        assertClosed(receipt)
        XCTAssertTrue(missing(r.path+"/"+receipt.directoryName+"/payload"))
        XCTAssertFalse(missing(r.path+"/"+receipt.directoryName+"/unrelated"))
        XCTAssertThrowsError(try file.release())
    }
    func testDirectoryRenameAndReplacementRefusesCleanup() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path), receipt = try r.capture(file)
        XCTAssertEqual(renameat(r.fd,receipt.directoryName,r.fd,"moved"),0)
        try r.track(parent:r.fd,name:"moved",directory:true)
        XCTAssertEqual(mkdirat(r.fd,receipt.directoryName,0o700),0)
        try r.track(parent:r.fd,name:receipt.directoryName,directory:true)
        XCTAssertThrowsError(try file.release()); assertClosed(receipt)
        XCTAssertFalse(missing(r.path+"/moved/payload"))
        XCTAssertFalse(missing(r.path+"/"+receipt.directoryName))
    }
    func testExternalModificationPreventsTransfer() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path), receipt = try r.capture(file)
        XCTAssertEqual(ftruncate(receipt.fileFD,10),0)
        XCTAssertThrowsError(try file.finishAndTransfer()) { XCTAssertEqual($0 as? XMLTVFileError,.ownershipMismatch) }
        assertClosed(receipt); try file.release()
    }
    func testRepeatedReleaseDoesNotCloseReusedDescriptor() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path), receipt = try r.capture(file)
        try file.release()
        let newFD = openat(r.fd,".owner",O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard newFD >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(newFD) }
        XCTAssertEqual(dup2(newFD,receipt.fileFD),receipt.fileFD)
        defer { if newFD != receipt.fileFD { Darwin.close(receipt.fileFD) } }
        try file.release()
        XCTAssertNotEqual(fcntl(receipt.fileFD,F_GETFD),-1)
    }
    func testTwoFilesNeverShareOwnershipOrCleanup() throws {
        let r = try root(), a = try XMLTVStagingFile.create(in:r.path), b = try XMLTVStagingFile.create(in:r.path)
        let ar = try r.capture(a), br = try r.capture(b)
        XCTAssertNotEqual(ar.directoryName,br.directoryName)
        try a.release(); try b.write(Data([9])); let reader = try b.finishAndTransfer()
        XCTAssertEqual(try reader.read(),Data([9])); try reader.release()
    }
    func testDiagnosticsNeverContainPayloadOrRoot() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path)
        _ = try r.capture(file)
        try file.write(Data("SECRET_TOKEN_DO_NOT_PERSIST".utf8))
        let reader = try file.finishAndTransfer()
        let text = "\(file) \(String(reflecting:file)) \(reader) \(String(reflecting:reader))"
        XCTAssertFalse(text.contains("SECRET_TOKEN")); XCTAssertFalse(text.contains(r.path)); try reader.release()
    }
    func testCancellationAfterPartialWriteCleansSynchronously() async throws {
        let r = try root()
        let result = try await Task.detached { () throws -> Bool in
            let file = try XMLTVStagingFile.create(in:r.path,write: { fd,p,n in
                let written = try self.actualWrite(fd,p,min(n,3))
                withUnsafeCurrentTask { $0?.cancel() }; return written
            })
            let receipt = try r.capture(file)
            do { try file.write(Data(repeating:1,count:100)); return false }
            catch is CancellationError { }
            self.assertClosed(receipt); try file.release()
            return self.missing(r.path+"/"+receipt.directoryName)
        }.value
        XCTAssertTrue(result)
    }
    func testEINTRLoopObservesCancellation() async throws {
        let r = try root()
        let result = try await Task.detached { () throws -> Bool in
            let file = try XMLTVStagingFile.create(in:r.path,write: { _,_,_ in
                withUnsafeCurrentTask { $0?.cancel() }; throw POSIXError(.EINTR)
            })
            _ = try r.capture(file)
            do { try file.write(Data([1])); return false } catch is CancellationError { }
            try file.release(); return true
        }.value
        XCTAssertTrue(result)
    }
    func testPrecancelledCreateHasNoPublishedOwner() async throws {
        let r = try root()
        let result = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try XMLTVStagingFile.create(in:r.path); return false } catch is CancellationError { return true } catch { return false }
        }.value
        XCTAssertTrue(result)
    }
    func testConcurrentTransfersHaveExactlyOneWinner() async throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path)
        _ = try r.capture(file); try file.write(Data([1]))
        let readers = await withTaskGroup(of: XMLTVStagedFile?.self, returning: [XMLTVStagedFile].self) { group in
            for _ in 0..<16 { group.addTask { try? file.finishAndTransfer() } }
            var result: [XMLTVStagedFile] = []
            for await reader in group { if let reader { result.append(reader) } }; return result
        }
        XCTAssertEqual(readers.count,1)
        for reader in readers { XCTAssertEqual(try reader.read(),Data([1])); try reader.release() }
    }
    func testTransferRacingReleaseHasOneTerminalOutcome() async throws {
        for _ in 0..<20 {
            let r = try root(), file = try XMLTVStagingFile.create(in:r.path)
            let receipt = try r.capture(file)
            async let transfer: XMLTVStagedFile? = Task.detached { try? file.finishAndTransfer() }.value
            async let release: Void = Task.detached { try? file.release(); return () }.value
            let reader = await transfer; await release
            if let reader { XCTAssertEqual(try reader.read(),Data()); try reader.release() }
            XCTAssertTrue(missing(r.path+"/"+receipt.directoryName))
        }
    }
    func testExplicitCancellationWorksOutsideSwiftTask() async throws {
        let r = try root(), began = expectation(description:"write entered"), finished = expectation(description:"cancelled")
        var first = true
        let file = try XMLTVStagingFile.create(in:r.path,write: { _,_,_ in
            if first { first = false; began.fulfill() }
            throw POSIXError(.EINTR)
        })
        let receipt = try r.capture(file)
        DispatchQueue.global().async {
            do { try file.write(Data([1])); XCTFail("Cancelled write succeeded") }
            catch is CancellationError { }
            catch { XCTFail("Wrong cancellation error") }
            finished.fulfill()
        }
        await fulfillment(of:[began],timeout:2)
        file.requestCancellation()
        await fulfillment(of:[finished],timeout:2)
        try file.release(); assertClosed(receipt)
    }
    func testOldCancellationCannotCancelNewOwner() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path)
        let receipt = try r.capture(file)
        try file.write(Data([1,2,3])); let reader = try file.finishAndTransfer()
        file.requestCancellation()
        XCTAssertEqual(try reader.read(maximumBytes:1),Data([1]))
        reader.requestCancellation()
        XCTAssertThrowsError(try reader.read()) { XCTAssertTrue($0 is CancellationError) }
        try reader.release(); XCTAssertTrue(missing(r.path+"/"+receipt.directoryName))
    }
    func testExistingDirectoryIsNeverAdoptedOrDeleted() throws {
        let r = try root(), name = "xmltv-"+UUID().uuidString
        XCTAssertEqual(mkdirat(r.fd,name,0o700),0); try r.track(parent:r.fd,name:name,directory:true)
        XCTAssertThrowsError(try XMLTVStagingFile.create(in:r.path,directoryName:name,write:actualWrite))
        XCTAssertFalse(missing(r.path+"/"+name))
    }
    func testReaderUsesPinnedFileNotReplacedPath() throws {
        let r = try root(), file = try XMLTVStagingFile.create(in:r.path), receipt = try r.capture(file)
        let dir = try r.hold(receipt.directoryFD)
        try file.write(Data([1,2,3])); let reader = try file.finishAndTransfer()
        XCTAssertEqual(unlinkat(dir,"payload",0),0)
        try r.createFile(parent:dir,name:"payload",data:Data([9]))
        XCTAssertEqual(try reader.read(),Data([1,2,3]))
        XCTAssertThrowsError(try reader.release())
        XCTAssertFalse(missing(r.path+"/"+receipt.directoryName+"/payload"))
    }
    func testWriteFailureAndCleanupFailureAreBothObservable() throws {
        let r = try root(); var dir: Int32 = -1, calls = 0
        let file = try XMLTVStagingFile.create(in:r.path,write: { fd,p,n in
            calls += 1
            if calls == 1 { return try self.actualWrite(fd,p,min(3,n)) }
            guard unlinkat(dir,"payload",0) == 0 else { throw POSIXError(.EPERM) }
            try r.createFile(parent:dir,name:"payload")
            throw POSIXError(.EIO)
        })
        let receipt = try r.capture(file); dir = try r.hold(receipt.directoryFD)
        XCTAssertThrowsError(try file.write(Data(repeating:1,count:10))) { XCTAssertEqual(($0 as? POSIXError)?.code,.EIO) }
        XCTAssertEqual(file.cleanupIssue,.ownershipMismatch)
        assertClosed(receipt)
        XCTAssertThrowsError(try file.release()) { XCTAssertEqual($0 as? XMLTVFileError,.ownershipMismatch) }
        XCTAssertFalse(missing(r.path+"/"+receipt.directoryName+"/payload"))
    }
}
