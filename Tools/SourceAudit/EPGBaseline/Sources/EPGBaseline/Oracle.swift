import CryptoKit
import Foundation
import OKVideoCore

struct ProgrammeFact: Codable, Equatable {
    let channelID: String
    let title: String
    let start: Int64
    let end: Int64
    init(_ value: EPGProgramme) {
        channelID = value.channelID; title = value.title
        start = Int64(value.start.timeIntervalSince1970); end = Int64(value.end.timeIntervalSince1970)
    }
}
struct QueryFact: Codable, Equatable {
    let channelID: String
    let at: Int64
    let current: ProgrammeFact?
    let next: ProgrammeFact?
}
struct Fixture: Decodable {
    let count: Int
    let channels: Int
    let now: Int64
    let duration: Int
    let xmlSHA256: String
    let semanticSHA256: String
    let windowStart: Int64
    let windowEnd: Int64
    let windowCount: Int
    let queries: [QueryFact]
}
struct MatchFact: Codable, Equatable {
    let input: String
    let kind: String
    let channelID: String?
}
struct OracleResult: Codable {
    let semanticSHA256: String
    let matches: [MatchFact]
    let queries: [QueryFact]
    let windowCount: Int
    let independentGeneratorAgreement: Bool
}

func semanticDigest(_ guide: XMLTVGuide) -> String {
    var hash = SHA256()
    func row(_ kind: String, _ fields: [String]) {
        hash.update(data: Data((kind + "\0").utf8))
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(bufferPointer: $0) }
            hash.update(data: bytes)
        }
        hash.update(data: Data([10]))
    }
    for channel in guide.channels { row("C", [channel.id, channel.displayName] + (channel.aliases ?? [])) }
    for p in guide.programmes {
        row("P", [p.channelID, p.title, String(Int64(p.start.timeIntervalSince1970)), String(Int64(p.end.timeIntervalSince1970))])
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func liveChannel(_ id: String?, name: String = "not-an-alias") -> LiveChannel {
    LiveChannel(groupName: "synthetic", name: name, tvgID: id, streams: [])
}

func oracle(_ guide: XMLTVGuide, fixture: Fixture) -> OracleResult {
    let index = XMLTVScheduleIndex(guide: guide)
    let probes = [liveChannel("CCTV1"), liveChannel(nil, name: "CCTV-1"),
                  liveChannel(nil, name: "共同别名"), liveChannel(nil, name: "UNKNOWN"),
                  liveChannel("missing", name: "CCTV1"), liveChannel("CCTV1", name: "共同别名")]
    let matches = probes.map { channel -> MatchFact in
        let result = index.channelMatch(for: channel)
        return MatchFact(input: (channel.tvgID ?? "nil") + "|" + channel.name,
                         kind: result.kind.rawValue, channelID: result.channelID)
    }
    let query = fixture.queries.map { expected -> QueryFact in
        let value = index.currentAndNext(for: liveChannel(expected.channelID), at: Date(timeIntervalSince1970: Double(expected.at)))
        return QueryFact(channelID: expected.channelID, at: expected.at,
                         current: value.current.map(ProgrammeFact.init), next: value.next.map(ProgrammeFact.init))
    }
    let count = guide.programmes.lazy.filter {
        $0.start.timeIntervalSince1970 < Double(fixture.windowEnd) && $0.end.timeIntervalSince1970 > Double(fixture.windowStart)
    }.count
    let digest = semanticDigest(guide)
    return OracleResult(semanticSHA256: digest, matches: matches, queries: query, windowCount: count,
        independentGeneratorAgreement: digest == fixture.semanticSHA256 && query == fixture.queries
            && count == fixture.windowCount
            && matches.map(\.kind) == ["exact", "normalizedUnique", "ambiguous", "unmatched", "unmatched", "exact"])
}
