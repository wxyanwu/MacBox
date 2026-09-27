import Foundation
import CryptoKit

public struct DanmakuSearchResult: Sendable {
    public var sources: [DanmakuSourceDescriptor]
    public var successfulServices: Int
}

/// Uses the existing bounded, cancellation-aware transport; no shared browser cookies.
public actor DanmakuServiceClient {
    public static let shared = DanmakuServiceClient()
    private let http: any HTTPClient
    private let cacheDirectory: URL?
    private var memory: [String: (Date, Data)] = [:]

    public init(http: any HTTPClient = URLSessionHTTPClient.isolatedEphemeral(), cacheDirectory: URL? = nil) {
        self.http = http
        self.cacheDirectory = cacheDirectory
    }
    public static func cached(directory: URL) -> DanmakuServiceClient {
        DanmakuServiceClient(cacheDirectory: directory)
    }
    public func discover(page: URL, headers: HTTPHeaders = [:], identity: String) async -> [DanmakuServiceEndpoint] {
        // This route is declared by the CatPaw danmu web module, not guessed for arbitrary websites.
        guard page.path.hasSuffix("/website/danmu/fe") else { return [] }
        let settings = page.deletingLastPathComponent().appendingPathComponent("setting")
        guard let body = try? await data(url: settings, headers: headers, limit: 512 * 1_024, timeout: 3),
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              root["code"] as? Int == 0,
              let data = root["data"] as? [String: Any], let urls = data["urls"] as? [[String: Any]] else { return [] }
        return urls.prefix(4).compactMap { value in
            guard let address = value["address"] as? String, let url = URL(string: address) else { return nil }
            let owned = value["builtin"] as? Bool == true
            return DanmakuServiceEndpoint(url: url, identity: owned ? identity + ":builtin" : nil)
        }
    }
    private func data(url: URL, headers: HTTPHeaders, limit: Int, timeout: TimeInterval) async throws -> Data {
        let response = try await http.send(HTTPRequest(url: url, headers: headers, timeout: timeout,
            maximumResponseBytes: limit, earlyResponseLimitBytes: limit, maximumRedirects: 3,
            redirectPolicy: .sameOriginNoDowngrade, retryPolicy: .none))
        try Task.checkCancellation()
        return response.body
    }
    public func search(keyword: String, endpoints: [DanmakuServiceEndpoint], generation: UInt64) async throws -> DanmakuSearchResult {
        var output: [DanmakuSourceDescriptor] = [], successful = 0
        // At most two services at once and four services per automatic/manual request.
        let endpoints = Array(endpoints.prefix(4))
        for start in stride(from: 0, to: endpoints.count, by: 2) {
            try Task.checkCancellation()
            let batch = endpoints[start..<min(start + 2, endpoints.count)]
            let results = await withTaskGroup(of: [DanmakuSourceDescriptor]?.self) { group in
                for endpoint in batch {
                    group.addTask {
                        guard let url = endpoint.searchURL(keyword: keyword) else { return nil }
                        do {
                            let body = try await self.data(url: url, headers: endpoint.headers, limit: 4 * 1_024 * 1_024, timeout: 5)
                            return try endpoint.decode(body, generation: generation)
                        } catch { return nil }
                    }
                }
                var results: [[DanmakuSourceDescriptor]] = []
                for await value in group { if let value { results.append(value) } }
                return results
            }
            successful += results.count; output += results.flatMap { $0 }
        }
        try Task.checkCancellation()
        var seen = Set<String>()
        return DanmakuSearchResult(sources: output.filter { seen.insert($0.id).inserted }, successfulServices: successful)
    }
    public func load(_ source: DanmakuSourceDescriptor) async throws -> DanmakuTimeline {
        let locator = source.runtime
        if let data = locator.inlineData { return try DanmakuPayloadParser().parse(data) }
        if locator.url.isFileURL {
            let size = try locator.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1_024 * 1_024 else { throw DanmakuXMLParserError.documentTooLarge }
            return try DanmakuPayloadParser().parse(Data(contentsOf: locator.url))
        }
        // Include the actual runtime address and request scope: no cross-account or reused-ID cache hit.
        let identity = source.id + (source.match.map { "\($0.workID):\($0.episode ?? -1):\($0.videoID ?? "")" } ?? "")
        let scoped = identity + locator.url.absoluteString + locator.headers.dictionary.sorted { $0.key < $1.key }.description
        let key = SHA256.hash(data: Data(scoped.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = memory[key], Date().timeIntervalSince(cached.0) < 900 {
            return try DanmakuPayloadParser().parse(cached.1)
        }
        if let directory = cacheDirectory {
            let file = directory.appendingPathComponent(key)
            if let attributes = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
               let date = attributes.contentModificationDate, Date().timeIntervalSince(date) < 900,
               (attributes.fileSize ?? .max) <= 32 * 1_024 * 1_024,
               let body = try? Data(contentsOf: file), let timeline = try? DanmakuPayloadParser().parse(body) {
                return timeline
            }
        }
        var body = try await data(url: locator.url, headers: locator.headers, limit: 32 * 1_024 * 1_024, timeout: 12)
        let timeline: DanmakuTimeline
        do { timeline = try DanmakuPayloadParser().parse(body) }
        catch let error as DanmakuXMLParserError {
            guard source.match != nil, locator.url.path.contains("/api/v2/comment/") else { throw error }
            var components = URLComponents(url: locator.url, resolvingAgainstBaseURL: false)!
            var query = components.queryItems ?? []; query.removeAll { $0.name == "format" }
            query.append(URLQueryItem(name: "format", value: "json")); components.queryItems = query
            body = try await data(url: components.url!, headers: locator.headers, limit: 32 * 1_024 * 1_024, timeout: 8)
            timeline = try DanmakuPayloadParser().parse(body)
        }
        try Task.checkCancellation()
        if !timeline.comments.isEmpty {
            if memory.count >= 4 { memory.removeValue(forKey: memory.min { $0.value.0 < $1.value.0 }!.key) }
            memory[key] = (Date(), body)
            if let directory = cacheDirectory {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                // Up to eight bounded payloads on disk. No signed URL, cookie or binding in cache filenames.
                for file in files.sorted(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }).dropFirst(7) {
                    try? FileManager.default.removeItem(at: file)
                }
                try? body.write(to: directory.appendingPathComponent(key), options: .atomic)
            }
        }
        return timeline
    }
}
