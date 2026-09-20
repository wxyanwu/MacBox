import CryptoKit
import Foundation
import OKVideoCore

struct Output: Codable {
    let schema: Int
    let mode: String
    let status: String
    let failure: String?
    let programmeCount: Int
    let baseline: ResourcePoint
    let stages: [String: Measurement]
    let distributions: [String: Distribution]
    let oracle: OracleResult?
    let queryOracleAgreement: Bool?
    let notes: [String]
}

func queryDistributions(_ snapshot: EPGSnapshot, fixture: Fixture) -> [String: Distribution] {
    let now = Date(timeIntervalSince1970: Double(fixture.now))
    let matched = (0..<min(100, fixture.channels)).map { liveChannel($0 == 0 ? "CCTV1" : String(format: "ch%05d", $0)) }
    let groups: [(String, [LiveChannel], Date)] = [
        ("matched_hot_batch_\(matched.count)", matched, now),
        ("normalized_unique", [liveChannel(nil, name: "CCTV-1")], now),
        ("ambiguous", [liveChannel(nil, name: "共同别名")], now),
        ("unmatched", [liveChannel("missing", name: "CCTV1")], now),
        ("single_channel", [liveChannel("CCTV1")], now),
        ("gap_probe", [liveChannel("CCTV1")], now.addingTimeInterval(Double(fixture.duration) * 0.75)),
        ("after_all_programmes", [liveChannel("CCTV1")], now.addingTimeInterval(1000 * 86400))]
    var result: [String: Distribution] = [:]
    // This is first-query-after-index-build, not an OS cold-disk measurement.
    var start = DispatchTime.now().uptimeNanoseconds
    let first = snapshot.nowNext(for: matched[0], at: now)
    result["first_query_after_build"] = distribution([Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6], checksum: first.current?.title.utf8.count ?? 0)
    for (name, channels, at) in groups {
        var times: [Double] = [], checksum = 0
        for _ in 0..<120 {
            start = DispatchTime.now().uptimeNanoseconds
            for channel in channels {
                let value = snapshot.nowNext(for: channel, at: at)
                checksum &+= (value.current?.title.utf8.count ?? 0) + (value.next?.title.utf8.count ?? 0)
            }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        result[name] = distribution(times, checksum: checksum)
    }
    return result
}

let syntheticKey = EPGRequestKey(source: .imported(UUID(uuidString: "00000000-0000-0000-0000-000000000009")!), revision: String(repeating: "9", count: 64), resource: "xmltv")

@main
struct Runner {
    static func main() async {
        // Explicit, developer-only subprocess invocation; no default App paths.
        let args = CommandLine.arguments
        guard args.count == 7, ["staged", "production", "cold", "fetch", "cancel"].contains(args[1]) else {
            fputs("usage: EPGBaseline MODE FIXTURE INPUT LOOPBACK_URL CACHE OUTPUT\n", stderr); exit(2)
        }
        let mode = args[1], meter = Meter()
        var queries: [String: Distribution] = [:], facts: OracleResult?, failure: String?
        var queryAgreement: Bool?
        var total = 0
        do {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            let cache = URL(fileURLWithPath: args[5], isDirectory: true)
            guard safeSyntheticCachePath(args[5]),
                  let url = URL(string: args[4]), url.scheme == "http", url.host == "127.0.0.1",
                  url.user == nil, url.password == nil, url.query == nil else {
                throw EPGFetchError.unavailable
            }
            let client = URLSessionHTTPClient.isolatedEphemeral()
            if mode == "cancel" {
                let input = try Data(contentsOf: URL(fileURLWithPath: args[3]))
                let task = Task.detached(priority: .utility) { try XMLTVParser().parse(input) }
                try await Task.sleep(nanoseconds: 50_000_000)
                meter.begin()
                task.cancel()
                do {
                    _ = try await task.value
                    failure = "PARSE_FINISHED_BEFORE_CANCELLATION_OBSERVED"
                } catch is CancellationError {
                    // Observation only: no new cancellation policy or production optimization.
                }
                meter.end("parser_cancel_to_finished_after_50ms_delay")
            } else if mode == "staged" {
                let input = try meter.measure("input_file_read_not_HTTP") { try Data(contentsOf: URL(fileURLWithPath: args[3])) }
                let expanded = try meter.measure("decompress") { try Gzip.decompress(input) }
                let guide = try meter.measure("parse_expanded_and_create_guide") { try XMLTVParser().parse(expanded) }
                let snapshot = meter.measure("snapshot_and_index") {
                    EPGSnapshot(key: syntheticKey, availability: .fresh, fetchedAt: Date(timeIntervalSince1970: Double(fixture.now)),
                                retryAfter: .distantFuture, guide: guide)
                }
                queries = meter.measure("queries") { queryDistributions(snapshot, fixture: fixture) }
                // A proposed interval contract, NOT an existing production window API.
                let selectedIDs = Set(guide.channels.prefix(50).map(\.id))
                let windowStart = Date(timeIntervalSince1970: Double(fixture.now))
                let windowEnd = windowStart.addingTimeInterval(6 * 3600)
                var referenceTimes: [Double] = [], referenceChecksum = 0
                for _ in 0..<30 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let count = guide.programmes.lazy.filter {
                        selectedIDs.contains($0.channelID) && $0.start < windowEnd && $0.end > windowStart
                    }.count
                    referenceChecksum &+= count
                    referenceTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                }
                queries["proposed_window_reference_full_scan_NOT_production_API"] = distribution(referenceTimes, checksum: referenceChecksum)
                let json = try meter.measure("JSON_encode_guide_not_repository_envelope") { try JSONEncoder().encode(guide) }
                let decoded = try meter.measure("JSON_decode_guide") { try JSONDecoder().decode(XMLTVGuide.self, from: json) }
                // Explicit lifetime overlap makes this diagnostic repeatable, not a production peak claim.
                withExtendedLifetime((input, expanded, guide, snapshot, json, decoded)) {
                    meter.begin(); meter.end("retained_stage_objects_checkpoint")
                }
                total = guide.programmes.count
                // Oracle allocations/time excluded from measured import stages.
                facts = oracle(guide, fixture: fixture)
                queryAgreement = facts?.independentGeneratorAgreement
                guard facts?.independentGeneratorAgreement == true, decoded == guide else { throw EPGFetchError.malformed }
            } else if mode == "fetch" {
                meter.begin()
                defer { meter.end("fetch_Data_same_XMLTV_request_limits") }
                let response = try await client.send(HTTPRequest(url: url, timeout: 30,
                    maximumResponseBytes: 32 * 1024 * 1024, earlyResponseLimitBytes: 32 * 1024 * 1024,
                    redirectPolicy: .noDowngrade, retryPolicy: HTTPRetryPolicy(maximumRetries: 2)))
                total = response.body.count // bytes, not programme count; marked in notes.
            } else {
                let repository = try EPGRepository(cacheDirectory: cache, now: { Date(timeIntervalSince1970: Double(fixture.now)) })
                meter.begin()
                let snapshot: EPGSnapshot
                if mode == "cold" {
                    guard let value = await repository.cached(syntheticKey) else { throw EPGFetchError.unavailable }
                    snapshot = value
                } else {
                    snapshot = try await repository.load(syntheticKey, ttl: 21600, fetch: {
                        try await XMLTVService.fetch(url: url, httpClient: client)
                    })
                }
                meter.end(mode == "cold" ? "fresh_process_disk_cache_to_snapshot" : "production_fetch_parse_persist_snapshot")
                total = snapshot.programmeCount
                guard snapshot.availability != .failed, total == fixture.count else { throw EPGFetchError.unavailable }
                queries = meter.measure("queries") { queryDistributions(snapshot, fixture: fixture) }
                queryAgreement = fixture.queries.allSatisfy { expected in
                    let value = snapshot.nowNext(for: liveChannel(expected.channelID), at: Date(timeIntervalSince1970: Double(expected.at)))
                    return value.current.map(ProgrammeFact.init) == expected.current && value.next.map(ProgrammeFact.init) == expected.next
                }
                guard queryAgreement == true else { throw EPGFetchError.malformed }
                meter.begin()
                let warm = await repository.cached(syntheticKey)
                meter.end("warm_repository_cached_rebuilds_snapshot")
                guard warm?.programmeCount == total else { throw EPGFetchError.malformed }
            }
        } catch {
            // No raw URLs, response bodies, paths, or transport descriptions in reports.
            failure = String(describing: type(of: error))
            meter.end("failed_operation")
        }
        let result = Output(schema: 1, mode: mode, status: failure == nil ? "PASS" : "REJECTED_OR_FAILED",
            failure: failure, programmeCount: total, baseline: meter.baseline, stages: meter.stages,
            distributions: queries, oracle: facts, queryOracleAgreement: queryAgreement,
            notes: ["No production mutation. Fixed synthetic source only.",
                    "staged retains overlapping objects; do not sum stage peaks or treat as production peak.",
                    "RSS/footprint bytes; 10ms sampling can miss transients. processPeakRSS is cumulative kernel high water, including earlier stages.",
                    "Oracle allocations occur after measured stages and are excluded from their peaks.",
                    "cold means a fresh process, not flushed OS disk caches; loopback timings are not public network performance.",
                    "fetch mode programmeCount field reports response bytes, not parsed programmes."])
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(result).write(to: URL(fileURLWithPath: args[6]), options: .atomic)
        } catch { fputs("Unable to write developer report\n", stderr); exit(3) }
        if failure != nil { exit(1) }
    }
}
