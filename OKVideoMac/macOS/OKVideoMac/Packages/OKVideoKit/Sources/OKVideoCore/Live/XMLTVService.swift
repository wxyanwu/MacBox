import CryptoKit
import Foundation

public actor XMLTVService {
    public static let refreshInterval: TimeInterval = 6 * 60 * 60

    /// Uncached transport/parse adapter used by the source-scoped EPGRepository.
    public static func fetch(url: URL, httpClient: HTTPClient,
                             headers: HTTPHeaders = [:]) async throws -> EPGPayload {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw EPGFetchError.unavailable
        }
        let response = try await httpClient.send(HTTPRequest(
            url: url, headers: headers, timeout: 30,
            maximumResponseBytes: 32 * 1024 * 1024,
            earlyResponseLimitBytes: 32 * 1024 * 1024,
            redirectPolicy: .noDowngrade,
            retryPolicy: HTTPRetryPolicy(maximumRetries: 2)
        ))
        try Task.checkCancellation()
        return EPGPayload(guide: try XMLTVParser().parse(response.body))
    }

    private struct CacheFile: Codable {
        var fetchedAt: Date
        var guide: XMLTVGuide
    }

    private let httpClient: HTTPClient
    private let cacheDirectory: URL
    private let now: () -> Date
    private var memory: [URL: CacheFile] = [:]

    public init(
        httpClient: HTTPClient,
        cacheDirectory: URL,
        now: @escaping () -> Date = Date.init
    ) throws {
        self.httpClient = httpClient
        self.cacheDirectory = cacheDirectory
        self.now = now
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: cacheDirectory.path
        )
    }

    public func guide(
        for url: URL,
        headers: HTTPHeaders = [:],
        forceRefresh: Bool = false
    ) async throws -> XMLTVGuide {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AppError.live("EPG 仅允许 HTTP/HTTPS")
        }

        if !forceRefresh, let cached = try? cachedGuide(for: url), isFresh(cached) {
            return cached.guide
        }

        do {
            let payload = try await Self.fetch(url: url, httpClient: httpClient, headers: headers)
            let value = CacheFile(
                fetchedAt: now(),
                guide: payload.guide
            )
            memory[url] = value
            try persist(value, for: url)
            return value.guide
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? HTTPClientError) == .cancelled {
                throw CancellationError()
            }
            if let stale = try? cachedGuide(for: url) {
                return stale.guide
            }
            throw error
        }
    }

    private func cachedGuide(for url: URL) throws -> CacheFile? {
        if let value = memory[url] {
            return value
        }
        let fileURL = cacheFileURL(for: url)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        let value = try JSONDecoder().decode(CacheFile.self, from: data)
        memory[url] = value
        return value
    }

    private func isFresh(_ value: CacheFile) -> Bool {
        now().timeIntervalSince(value.fetchedAt) < Self.refreshInterval
    }

    private func persist(_ value: CacheFile, for url: URL) throws {
        let data = try JSONEncoder().encode(value)
        let fileURL = cacheFileURL(for: url)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func cacheFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent("\(digest).json")
    }
}
