import Foundation

@_spi(XMLTVStreaming) public struct XMLTVDownloadedImportSummary {
    public let download: XMLTVDownloadMetrics
    public let xml: XMLTVImportSummary
    public let wasGzip: Bool
    public let gzipMemberCount: Int
    public let compressedInputBytes: Int?
}

@_spi(XMLTVStreaming) public struct XMLTVFileImportSummary {
    public let xml: XMLTVImportSummary
    public let wasGzip: Bool
    public let gzipMemberCount: Int
    public let compressedInputBytes: Int?
}

extension XMLTVParser {
    /// Consumes a downloaded file and synchronously applies parser backpressure.
    /// Gzip is selected by file magic, not a URL suffix or provider MIME claim.
    @_spi(XMLTVStreaming) public func parseDownloadedFile(
        _ download: XMLTVDownloadedFile,
        budget: XMLTVBatchBudget = XMLTVBatchBudget(),
        sink: XMLTVBatchSink
    ) throws -> XMLTVDownloadedImportSummary {
        let staged = try download.takeFile()
        let result = try parseStagedFile(staged, budget: budget, sink: sink)
        return XMLTVDownloadedImportSummary(download: download.metrics, xml: result.xml,
            wasGzip: result.wasGzip, gzipMemberCount: result.gzipMemberCount,
            compressedInputBytes: result.compressedInputBytes)
    }

    /// Consumes a sealed local file with the same ownership and EOF contract as
    /// the network path. Neither arbitrary paths nor unbounded Data are accepted.
    @_spi(XMLTVStreaming) public func parseStagedFile(
        _ staged: XMLTVStagedFile, budget: XMLTVBatchBudget = XMLTVBatchBudget(),
        sink: XMLTVBatchSink
    ) throws -> XMLTVFileImportSummary {
        let source = XMLTVStagedInputStream(staged)
        source.open()
        var magic = [UInt8](repeating: 0, count: 2)
        let count = source.read(&magic, maxLength: magic.count)
        guard count >= 0 else {
            source.close()
            throw source.failure ?? XMLTVDownloadError.temporaryFile
        }
        let prefix = Data(magic.prefix(count))
        let input = XMLTVPrefixedInputStream(prefix: prefix, source: source)
        defer { input.close() }
        do {
            if count == 2, magic[0] == 0x1f, magic[1] == 0x8b {
                let result = try parseGzipStream(input, budget: budget, sink: sink)
                if let failure = source.failure { throw failure }
                return XMLTVFileImportSummary(
                    xml: result.xml,
                    wasGzip: true,
                    gzipMemberCount: result.memberCount,
                    compressedInputBytes: result.compressedInputBytes
                )
            }
            let result = try parsePlainStream(input, budget: budget, sink: sink)
            if let failure = source.failure { throw failure }
            return XMLTVFileImportSummary(
                xml: result,
                wasGzip: false,
                gzipMemberCount: 0,
                compressedInputBytes: nil
            )
        } catch {
            input.close()
            throw error
        }
    }
}

private final class XMLTVStagedInputStream: InputStream {
    private var file: XMLTVStagedFile?
    private(set) var failure: Error?
    private var status: Stream.Status = .notOpen

    init(_ file: XMLTVStagedFile) {
        self.file = file
        super.init(data: Data())
    }

    override func open() {
        guard status == .notOpen else { return }
        status = .open
    }

    override func close() {
        guard status != .closed else { return }
        let value = file
        file = nil
        do { try value?.release() }
        catch { if failure == nil { failure = error } }
        status = .closed
    }

    override var streamStatus: Stream.Status { status }
    override var streamError: Error? { failure }
    override var hasBytesAvailable: Bool { status == .open }
    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool { false }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard status == .open, len > 0, let file else { return -1 }
        do {
            let data = try file.read(maximumBytes: min(len, 65_536))
            if data.isEmpty { status = .atEnd; return 0 }
            data.copyBytes(to: buffer, count: data.count)
            return data.count
        } catch {
            failure = error
            status = .error
            return -1
        }
    }

    deinit { close() }
}

private final class XMLTVPrefixedInputStream: InputStream {
    private let prefix: Data
    private let source: XMLTVStagedInputStream
    private var prefixOffset = 0
    private var status: Stream.Status = .notOpen

    init(prefix: Data, source: XMLTVStagedInputStream) {
        self.prefix = prefix
        self.source = source
        super.init(data: Data())
    }

    override func open() {
        guard status == .notOpen else { return }
        source.open()
        status = .open
    }

    override func close() {
        guard status != .closed else { return }
        source.close()
        status = .closed
    }

    override var streamStatus: Stream.Status { status }
    override var streamError: Error? { source.streamError }
    override var hasBytesAvailable: Bool {
        prefixOffset < prefix.count || source.hasBytesAvailable
    }
    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool { false }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard status == .open, len > 0 else { return -1 }
        if prefixOffset < prefix.count {
            let amount = min(len, prefix.count - prefixOffset)
            prefix.copyBytes(
                to: buffer,
                from: prefixOffset..<(prefixOffset + amount)
            )
            prefixOffset += amount
            return amount
        }
        let amount = source.read(buffer, maxLength: len)
        if amount == 0 { status = .atEnd }
        if amount < 0 { status = .error }
        return amount
    }

    deinit { close() }
}
