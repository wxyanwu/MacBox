import Foundation
import CZlib

@_spi(XMLTVStreaming) public enum XMLTVGzipError: Error {
    case compressedInputLimit, truncatedInput, invalidStream, initialization
}

@_spi(XMLTVStreaming) public struct XMLTVGzipImportSummary {
    public let xml: XMLTVImportSummary
    public let compressedInputBytes: Int
    public let memberCount: Int
}

extension XMLTVParser {
    /// Explicit developer SPI, not the legacy Data/Repository entry point.
    /// Validates ALL gzip members, including CRC/ISIZE, through physical EOF.
    /// Their concatenated output must be one XMLTV document. Non-gzip suffixes
    /// (including zero padding) are rejected. Limits apply across all members:
    /// 32 MiB compressed, 64 MiB expanded; neither is reset at member boundaries.
    /// Like the plain SPI, consumes/closes a synchronous, cooperative input on
    /// the caller's non-main worker. It cannot interrupt an arbitrary blocking
    /// InputStream implementation; network cancellation belongs to its owner.
    @_spi(XMLTVStreaming) public func parseGzipStream(
        _ input: InputStream, budget: XMLTVBatchBudget = XMLTVBatchBudget(),
        sink: XMLTVBatchSink
    ) throws -> XMLTVGzipImportSummary {
        let gzip = XMLTVGzipInputStream(input, checkCancellation: {
            try Task.checkCancellation()
            try (sink as? XMLTVMetadataBatchSink)?.checkCancellation()
        })
        let xml = try parsePlainStream(gzip, budget: budget, sink: sink)
        return XMLTVGzipImportSummary(xml: xml, compressedInputBytes: gzip.inputBytes,
                                      memberCount: gzip.members)
    }
}

/// Pull adapter with one fixed input buffer and zlib's bounded inflate state.
/// z_stream has a stable allocated address (zlib retains its address internally).
/// next_in/next_out only exist during their pointer scopes, never across read().
final class XMLTVGzipInputStream: InputStream {
    private let input: InputStream
    private let limit: Int
    private let checkCancellation: () throws -> Void
    private let z = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    private var initialized = false
    private var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    private var offset = 0, available = 0
    private var physicalEOF = false, atMemberBoundary = false, complete = false
    private var state: Stream.Status = .notOpen
    private(set) var inputBytes = 0, members = 0
    private(set) var failure: Error?

    // Smaller caps are available internally for limit tests, never to production callers.
    init(_ input: InputStream, compressedLimit: Int = 32 * 1_024 * 1_024,
         checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() }) {
        self.input = input; self.limit = compressedLimit
        self.checkCancellation = checkCancellation
        z.initialize(to: z_stream())
        super.init(data: Data())
    }
    deinit { close(); z.deinitialize(count: 1); z.deallocate() }
    override func open() {
        guard state == .notOpen else { return }
        input.open()
        guard limit > 0, inflateInit2_(z, 16 + MAX_WBITS, zlibVersion(),
                    Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            fail(XMLTVGzipError.initialization); return
        }
        initialized = true; state = .open
    }
    override func close() {
        if initialized { inflateEnd(z); initialized = false }
        input.close(); state = .closed
    }
    override var streamStatus: Stream.Status { state }
    override var streamError: Error? { failure }
    override var hasBytesAvailable: Bool { state == .open }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                            length len: UnsafeMutablePointer<Int>) -> Bool { false }

    private func fail(_ error: Error) { failure = error; state = .error }
    private func refill() throws {
        try checkCancellation()
        try Task.checkCancellation()
        guard available == 0, !physicalEOF else { return }
        let requested = min(buffer.count, limit - inputBytes + 1)
        let count = buffer.withUnsafeMutableBufferPointer {
            input.read($0.baseAddress!, maxLength: requested)
        }
        guard count >= 0 else { throw input.streamError ?? XMLTVStreamError.inputFailure }
        guard count <= requested else { throw XMLTVStreamError.inputFailure }
        inputBytes += count
        guard inputBytes <= limit else { throw XMLTVGzipError.compressedInputLimit }
        offset = 0; available = count; physicalEOF = count == 0
    }

    override func read(_ output: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if complete { return 0 }
        guard state == .open, len > 0 else { return -1 }
        do {
            // Never expose a member boundary as EOF, even for empty members.
            while true {
                try checkCancellation()
                try Task.checkCancellation()
                try refill()
                if atMemberBoundary {
                    if physicalEOF {
                        complete = true; state = .atEnd; return 0
                    }
                    guard inflateReset2(z, 16 + MAX_WBITS) == Z_OK else {
                        throw XMLTVGzipError.initialization
                    }
                    atMemberBoundary = false
                }
                let capacity = min(len, 64 * 1_024)
                let before = available
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { bytes in
                    z.pointee.next_in = bytes.baseAddress!.advanced(by: offset)
                    z.pointee.avail_in = uInt(available)
                    z.pointee.next_out = output
                    z.pointee.avail_out = uInt(capacity)
                    defer { z.pointee.next_in = nil; z.pointee.next_out = nil }
                    return inflate(z, Z_NO_FLUSH)
                }
                let consumed = before - Int(z.pointee.avail_in)
                let produced = capacity - Int(z.pointee.avail_out)
                offset += consumed; available -= consumed
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw XMLTVGzipError.invalidStream
                }
                if status == Z_STREAM_END { members += 1; atMemberBoundary = true }
                if produced > 0 { return produced }
                if atMemberBoundary { continue }
                // With no input left, request another bounded fragment. With
                // physical EOF, missing trailer/header is failure, not success.
                if consumed == 0 {
                    if physicalEOF { throw XMLTVGzipError.truncatedInput }
                    if available > 0 { throw XMLTVGzipError.invalidStream }
                }
            }
        } catch { fail(error); return -1 }
    }
}
