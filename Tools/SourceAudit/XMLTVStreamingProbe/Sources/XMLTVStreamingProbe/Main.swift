import Foundation
import Darwin
@_spi(XMLTVStreaming) import OKVideoCore

// Explicit synthetic file invocation only. Never opens a DB or deletes a path.
func checkedPath(_ value: String, existing: Bool) throws -> String {
    guard value.hasPrefix("/private/tmp/OKVideoMac-9B.") else { throw XMLTVStreamError.inputFailure }
    let parent = (value as NSString).deletingLastPathComponent
    let test = existing ? value : parent
    guard let pointer = realpath(test,nil) else { throw XMLTVStreamError.inputFailure }
    defer { free(pointer) }
    guard String(cString:pointer)==test else { throw XMLTVStreamError.inputFailure }
    return value
}

final class FileSink: XMLTVBatchSink {
    let fd: Int32
    var count = 0
    var previousOrdinal = -1
    init(_ path: String) throws {
        fd = Darwin.open(path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw XMLTVStreamError.inputFailure }
    }
    deinit { Darwin.close(fd) }
    func consumeTentative(_ batch: [XMLTVStreamedProgramme]) throws {
        var data=Data()
        for item in batch {
            guard item.ordinal > previousOrdinal else { throw XMLTVStreamError.inputFailure }
            previousOrdinal=item.ordinal
            let p=item.programme
            data.append(contentsOf:[80,0]) // canonical 9A "P\0" row
            for field in [p.channelID,p.title,String(Int64(p.start.timeIntervalSince1970)),String(Int64(p.end.timeIntervalSince1970))] {
                let bytes=Data(field.utf8)
                var length=UInt64(bytes.count).bigEndian
                withUnsafeBytes(of:&length) { data.append(contentsOf:$0) }
                data.append(bytes)
            }
            data.append(10)
            count += 1
        }
        try data.withUnsafeBytes { buffer in
            var offset=0
            while offset<buffer.count {
                try Task.checkCancellation()
                let n=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if n<0 && errno==EINTR { continue }
                guard n>0 else { throw XMLTVStreamError.inputFailure }
                offset += n
            }
        }
    }
    func discardTentative() { _ = ftruncate(fd,0); count=0 }
}

struct Result: Encodable {
    let mode: String
    let compressedInputBytes: Int?, memberCount: Int?
    let channels: [EPGChannel]
    let programmeIDs: [String]
    let elements: Int, valid: Int, emitted: Int, inputBytes: Int
    let peakBatchCount: Int, peakBatchEstimatedBytes: Int
    let minStart: Double?, maxEnd: Double?
    let baseline: ResourcePoint
    let stages: [String: Measurement]
}

@main struct Main {
    static func main() {
        do {
            let args=CommandLine.arguments
            guard args.count==4 || args.count==5 else { throw XMLTVStreamError.inputFailure }
            let mode = args.count==5 ? args[4] : "plain"
            guard mode=="plain" || mode=="gzip" else { throw XMLTVStreamError.inputFailure }
            let input=try checkedPath(args[1],existing:true)
            let output=try checkedPath(args[2],existing:false)
            let rows=try checkedPath(args[3],existing:false)
            guard !FileManager.default.fileExists(atPath:output), let stream=InputStream(fileAtPath:input) else {
                throw XMLTVStreamError.inputFailure
            }
            let meter=Meter(),sink=try FileSink(rows)
            meter.begin()
            let s: XMLTVImportSummary
            var compressedBytes: Int?, members: Int?
            if mode=="gzip" {
                let gzip=try XMLTVParser().parseGzipStream(stream,sink:sink)
                s=gzip.xml; compressedBytes=gzip.compressedInputBytes; members=gzip.memberCount
            } else { s=try XMLTVParser().parsePlainStream(stream,sink:sink) }
            meter.end(mode+"_stream_to_tentative_file")
            let result=Result(mode:mode,compressedInputBytes:compressedBytes,memberCount:members,
                channels:s.channels,programmeIDs:s.programmeChannelIDs.sorted(),elements:s.programmeElementCount,
                valid:s.validProgrammeCount,emitted:s.emittedProgrammeCount,inputBytes:s.inputBytes,
                peakBatchCount:s.peakBatchCount,peakBatchEstimatedBytes:s.peakBatchEstimatedBytes,
                minStart:s.minProgrammeStart?.timeIntervalSince1970,maxEnd:s.maxProgrammeEnd?.timeIntervalSince1970,
                baseline:meter.baseline,stages:meter.stages)
            let data=try JSONEncoder().encode(result)
            try data.write(to:URL(fileURLWithPath:output),options:.withoutOverwriting)
        } catch {
            fputs("Streaming probe failed: \(type(of:error))\n",stderr)
            exit(1)
        }
    }
}
