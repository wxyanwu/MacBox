import Foundation

/// Developer-only, synchronous import SPI. Not wired into Repository or App.
/// One invocation owns one sink; consumers must not retain unbounded batches.
@_spi(XMLTVStreaming) public protocol XMLTVBatchSink: AnyObject {
    func consumeTentative(_ programmes: [XMLTVStreamedProgramme]) throws
    /// Called on every failed/cancelled import, including after emitted batches.
    func discardTentative()
}

/// Opt-in bounded metadata path. Each display-name is a fact, not a complete
/// channel aggregate. The sink owns persistent deduplication and cancellation.
@_spi(XMLTVStreaming) public protocol XMLTVMetadataBatchSink: XMLTVBatchSink {
    func consumeTentativeChannels(_ channels: [EPGChannel]) throws
    func checkCancellation() throws
}

@_spi(XMLTVStreaming) public struct XMLTVStreamedProgramme {
    public let programme: EPGProgramme
    /// Zero-based raw programme element order, NOT channel or persistent identity.
    public let ordinal: Int
}

@_spi(XMLTVStreaming) public enum XMLTVStreamError: Error {
    case invalidBudget, inputLimit, inputFailure, oversizedRecord, invalidDocument
}

@_spi(XMLTVStreaming) public struct XMLTVBatchBudget {
    public let count: Int
    /// UTF-8 field bytes plus a conservative fixed record allowance, not RSS.
    public let estimatedBytes: Int
    public init(count: Int = 512, estimatedBytes: Int = 1_048_576) {
        self.count = count; self.estimatedBytes = estimatedBytes
    }
}

/// Only a successful return authorizes treating tentative output as a complete
/// document. It is NOT permission to publish into an active EPG generation.
@_spi(XMLTVStreaming) public struct XMLTVImportSummary {
    public let channels: [EPGChannel]
    public let programmeChannelIDs: Set<String>
    public let programmeElementCount: Int
    public let validProgrammeCount: Int
    public let emittedProgrammeCount: Int
    public let minProgrammeStart: Date?
    public let maxProgrammeEnd: Date?
    public let inputBytes: Int
    public let peakBatchCount: Int
    public let peakBatchEstimatedBytes: Int
    public let emittedChannelRecordCount: Int
    public let peakChannelBatchCount: Int
    public let peakChannelBatchEstimatedBytes: Int
}

extension XMLTVParser {
    /// Consumes and closes a plain XML stream, on the caller's non-main worker.
    /// No network/gzip inference, no retention filtering, no per-batch Task.
    /// A record larger than the explicit batch budget is rejected on this SPI;
    /// the legacy parse(Data) API does not acquire this additional policy.
    @_spi(XMLTVStreaming) public func parsePlainStream(
        _ input: InputStream, budget: XMLTVBatchBudget = XMLTVBatchBudget(),
        sink: XMLTVBatchSink
    ) throws -> XMLTVImportSummary {
        var complete = false
        defer { if !complete { sink.discardTentative() } }
        guard budget.count > 0, budget.count <= 200_000,
              budget.estimatedBytes > 0, budget.estimatedBytes <= 64 * 1_024 * 1_024 else {
            input.close()
            throw XMLTVStreamError.invalidBudget
        }
        let metadataSink = sink as? XMLTVMetadataBatchSink
        let check: () throws -> Void = {
            try Task.checkCancellation()
            try metadataSink?.checkCancellation()
        }
        let stream = XMLTVLimitedInputStream(input, checkCancellation: check)
        defer { stream.close() }
        try Task.checkCancellation()
        let batches = XMLTVBatchEmitter(budget: budget, sink: sink, collectChannelIDs: metadataSink == nil)
        let channels = metadataSink.map { XMLTVChannelBatchEmitter(budget: budget, sink: $0) }
        let onChannel: ((EPGChannel) throws -> Void)? = channels.map { emitter in
            { channel in try emitter.accept(channel) }
        }
        let delegate: XMLTVDelegate
        do {
            delegate = try parseXML(XMLParser(stream: stream), boundsDateTemporaries: true,
                                    onChannel: onChannel, checkCancellation: check) { programme, ordinal in
                try batches.accept(programme, ordinal: ordinal)
            }
            try stream.verifyEndOfInput()
        } catch {
            if let failure = stream.failure { throw failure }
            throw error
        }
        try Task.checkCancellation()
        try batches.flush()
        try channels?.flush()
        try check()
        try Task.checkCancellation()
        let result = XMLTVImportSummary(channels: delegate.channels,
            programmeChannelIDs: batches.channelIDs,
            programmeElementCount: delegate.programmeElementCount,
            validProgrammeCount: delegate.validProgrammeCount,
            emittedProgrammeCount: batches.emitted,
            minProgrammeStart: batches.minStart, maxProgrammeEnd: batches.maxEnd,
            inputBytes: stream.bytes, peakBatchCount: batches.peakCount,
            peakBatchEstimatedBytes: batches.peakBytes,
            emittedChannelRecordCount: channels?.emitted ?? 0,
            peakChannelBatchCount: channels?.peakCount ?? 0,
            peakChannelBatchEstimatedBytes: channels?.peakBytes ?? 0)
        complete = true
        return result
    }
}

private final class XMLTVBatchEmitter {
    let budget: XMLTVBatchBudget
    let sink: XMLTVBatchSink
    var batch: [XMLTVStreamedProgramme] = []
    var bytes = 0, peakBytes = 0, peakCount = 0, emitted = 0
    var channelIDs = Set<String>()
    let collectChannelIDs: Bool
    var minStart: Date?, maxEnd: Date?
    init(budget: XMLTVBatchBudget, sink: XMLTVBatchSink, collectChannelIDs: Bool) {
        self.budget = budget; self.sink = sink; self.collectChannelIDs = collectChannelIDs
    }
    func accept(_ programme: EPGProgramme, ordinal: Int) throws {
        try Task.checkCancellation()
        let size = programme.channelID.utf8.count + programme.title.utf8.count + 64
        guard size <= budget.estimatedBytes else { throw XMLTVStreamError.oversizedRecord }
        if batch.count >= budget.count || bytes + size > budget.estimatedBytes { try flush() }
        batch.append(XMLTVStreamedProgramme(programme: programme, ordinal: ordinal))
        bytes += size
        peakBytes = max(peakBytes, bytes); peakCount = max(peakCount, batch.count)
        if collectChannelIDs { channelIDs.insert(programme.channelID) }
        minStart = minStart.map { min($0, programme.start) } ?? programme.start
        maxEnd = maxEnd.map { max($0, programme.end) } ?? programme.end
    }
    func flush() throws {
        try Task.checkCancellation()
        guard !batch.isEmpty else { return }
        // The callback must return before parsing resumes: implicit backpressure.
        try sink.consumeTentative(batch)
        try Task.checkCancellation()
        emitted += batch.count
        batch.removeAll(keepingCapacity: true)
        bytes = 0
    }
}

private final class XMLTVChannelBatchEmitter {
    let budget: XMLTVBatchBudget
    let sink: XMLTVMetadataBatchSink
    var batch: [EPGChannel] = []
    var bytes = 0, peakBytes = 0, peakCount = 0, emitted = 0
    init(budget: XMLTVBatchBudget, sink: XMLTVMetadataBatchSink) {
        self.budget = budget; self.sink = sink
    }
    func accept(_ channel: EPGChannel) throws {
        try sink.checkCancellation()
        let size = channel.id.utf8.count + channel.displayName.utf8.count + 64
        guard size <= budget.estimatedBytes else { throw XMLTVStreamError.oversizedRecord }
        if batch.count >= budget.count || bytes + size > budget.estimatedBytes { try flush() }
        batch.append(channel); bytes += size
        peakCount = max(peakCount, batch.count); peakBytes = max(peakBytes, bytes)
    }
    func flush() throws {
        try sink.checkCancellation()
        guard !batch.isEmpty else { return }
        try sink.consumeTentativeChannels(batch)
        emitted += batch.count; batch.removeAll(keepingCapacity: true); bytes = 0
    }
}

/// Enforces the unchanged 64 MiB expanded XML limit on actual reads, not metadata.
/// Pointer storage never escapes read(_:maxLength:). No prefetch/unbounded buffer.
final class XMLTVLimitedInputStream: InputStream {
    private let input: InputStream
    private(set) var bytes = 0
    private(set) var failure: Error?
    private var reachedEOF = false
    private var state: Stream.Status = .notOpen
    private let limit = 64 * 1_024 * 1_024
    private let checkCancellation: () throws -> Void
    init(_ input: InputStream, checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() }) {
        self.input = input; self.checkCancellation = checkCancellation; super.init(data: Data())
    }
    override func open() { guard state == .notOpen else { return }; input.open(); state = .open }
    override func close() { input.close(); state = .closed }
    override var streamStatus: Stream.Status { state }
    override var streamError: Error? { failure }
    override var hasBytesAvailable: Bool { state == .open }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
                            length len: UnsafeMutablePointer<Int>) -> Bool { false }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if reachedEOF { return 0 }
        guard state == .open, len > 0 else { return -1 }
        let target = min(len, min(64 * 1_024, limit - bytes + 1))
        var produced = 0
        // Coalesce short underlying reads, including XMLParser's initial encoding
        // sniff. Never let a one-byte transport fragment become a false EOF.
        while produced < target {
            do { try checkCancellation() }
            catch { failure = error; state = .error; return -1 }
            if Task.isCancelled { failure = CancellationError(); state = .error; return -1 }
            let count = input.read(buffer.advanced(by: produced), maxLength: target - produced)
            if count < 0 { failure = input.streamError ?? XMLTVStreamError.inputFailure; state = .error; return -1 }
            bytes += count
            if bytes > limit { failure = XMLTVStreamError.inputLimit; state = .error; return -1 }
            if count == 0 { reachedEOF = true; state = .atEnd; break }
            produced += count
        }
        return produced
    }
    func verifyEndOfInput() throws {
        if let failure { throw failure }
        if reachedEOF { return }
        // Never silently accept an unread suffix after the XML reader stops.
        var byte: UInt8 = 0
        let count = read(&byte, maxLength: 1)
        if let failure { throw failure }
        guard count == 0 else { throw XMLTVStreamError.inputFailure }
    }
}
