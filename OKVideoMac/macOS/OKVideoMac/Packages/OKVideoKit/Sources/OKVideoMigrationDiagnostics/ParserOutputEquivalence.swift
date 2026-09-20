import Foundation
import CryptoKit
import CSQLite
import OKVideoCore

/// Digests cover the entire ordered production result, not just channel counts.
/// No URLs/headers/raw data are emitted. This developer-only helper also allows
/// comparison against a golden captured BEFORE changing the production parser.
public enum ParserOutputEquivalence {
    public static func digest(_ playlist: LivePlaylist) throws -> String {
        struct Output: Encodable {
            let format: LiveSourceFormat
            let groups: [LiveGroup]
            let epgURL: URL?
            let channelIDs: [[String]]
            let groupIDs: [String]
        }
        return try hash(Output(format: playlist.format, groups: playlist.groups, epgURL: playlist.epgURL,
            channelIDs: playlist.groups.map { $0.channels.map(\.id) }, groupIDs: playlist.groups.map(\.id)))
    }
    private static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    public struct SourceGolden: Codable, Equatable {
        public let sourceID: String
        public let inputDigest: String
        public let outputDigest: String
        public let groups: Int
        public let channels: Int
    }
    public static func capture(temporaryDatabase: URL) throws -> [SourceGolden] {
        let resolved = temporaryDatabase.resolvingSymlinksInPath().path
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path
        guard resolved.hasPrefix(temporaryRoot + "/OKVideoMac-8B2-DryRun-") else { throw SnapshotError.unsafeFile }
        var db: OpaquePointer?
        guard sqlite3_open_v2(resolved, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw SnapshotError.sqliteFailure
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, raw_data, base_url FROM live_sources ORDER BY id", -1, &statement, nil) == SQLITE_OK, let statement else { throw SnapshotError.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        var result: [SourceGolden] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let id = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else { throw SnapshotError.invalidDatabase }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            let base = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let playlist = try LiveSourceParser().parse(data, baseURL: base.flatMap(URL.init(string:)))
            struct Input: Encodable { let data: Data; let base: String? }
            result.append(SourceGolden(sourceID: String(cString: id), inputDigest: try hash(Input(data: data, base: base)),
                outputDigest: try digest(playlist), groups: playlist.groups.count, channels: playlist.groups.reduce(0) { $0 + $1.channels.count }))
        }
        return result
    }
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try QuiescentDatabaseSnapshot.writePrivate(encoder.encode(value), to: url)
    }

    /// Fixed synthetic inputs. Invalid domains never get requested.
    public static let fixtures: [String: String] = [
        "single": "#EXTM3U\n#EXTINF:-1 tvg-id=\"1\" tvg-name=\"One\" tvg-logo=\"logo.png\" tvg-chno=\"1\" group-title=\"G\",Name\nhttps://fixture.invalid/one\n",
        "merge": "#EXTM3U\n#EXTINF:-1 tvg-id=\"1\" tvg-name=\"First\" group-title=\"G\",Name\nhttps://fixture.invalid/one\n#EXTINF:-1 tvg-id=\"2\" tvg-name=\"Second\" group-title=\"G\",Name\nhttps://fixture.invalid/two\n",
        "headers": "#EXTM3U\nglobal-header=User-Agent=Global\n#EXTINF:-1 group-title=\"G\",Name\n#EXTHTTP:{\"Cookie\":\"SECRET_TOKEN_DO_NOT_PERSIST\",\"User-Agent\":\"A\"}\nhttps://fixture.invalid/one|Authorization=Bearer%20CANARY\n#EXTINF:-1 group-title=\"G\",Name\n#EXTVLCOPT:http-user-agent=B\nhttps://fixture.invalid/one\n",
        "epg": "#EXTM3U tvg-url=\"first.xml\" url-tvg=\"second.xml\" x-tvg-url=\"third.xml\"\n#EXTINF:-1,Name\nrelative.m3u8\n",
        "order": "#EXTM3U\n#EXTINF:-1 group-title=\"Z\",B\nhttps://fixture.invalid/2\n#EXTINF:-1 group-title=\"A\",C\nhttps://fixture.invalid/3\n#EXTINF:-1 group-title=\"Z\",A\nhttps://fixture.invalid/1\n",
        "protected": "#EXTM3U\n#EXTINF:-1 group-title=\"G_one\",Name\nhttps://fixture.invalid/one\n#EXTINF:-1 group-title=\"G_two\",Name\nhttps://fixture.invalid/two\n",
        "txt": "G_secret,#genre#\nua=Agent\nName,https://fixture.invalid/one$A#https://fixture.invalid/two$B\nName,https://fixture.invalid/one|Cookie=CANARY\n",
        "json": "[{\"name\":\"G\",\"channel\":[{\"name\":\"Name\",\"tvgId\":\"one\",\"urls\":[\"https://fixture.invalid/one\",\"https://fixture.invalid/two\"],\"header\":{\"Cookie\":\"CANARY\"}},{\"name\":\"Name\",\"urls\":[\"https://fixture.invalid/three\"]}]}]",
        "invalid": "#EXTM3U\n#EXTINF:-1 group-title=\"G\",Broken\nfile:///forbidden\n#EXTINF:-1 group-title=\"G\",Good\nhttps://fixture.invalid/good\n"
    ]
    public static func fixtureDigests() throws -> [String: String] {
        try fixtures.mapValues { try digest(LiveSourceParser().parse($0, baseURL: URL(string: "https://fixture.invalid/base/"))) }
    }
}
