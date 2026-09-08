import Foundation

public struct XtreamCatalogResponsePolicy: Equatable, Sendable {
    /// An adjustable initial safety value, not an Xtream protocol limit.
    public static let initialSafetyDefault = XtreamCatalogResponsePolicy(
        maximumResponseBytes: 64 * 1_024 * 1_024
    )

    public var maximumResponseBytes: Int

    public init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }
}

public struct XtreamAccount: Equatable, Sendable {
    public let status: String?
    public let expirationDate: Date?
    public let isTrial: Bool?
    public let activeConnections: Int?
    public let maxConnections: Int?
    public let allowedOutputFormats: [String]

    public init(
        status: String?,
        expirationDate: Date?,
        isTrial: Bool?,
        activeConnections: Int?,
        maxConnections: Int?,
        allowedOutputFormats: [String]
    ) {
        self.status = status
        self.expirationDate = expirationDate
        self.isTrial = isTrial
        self.activeConnections = activeConnections
        self.maxConnections = maxConnections
        self.allowedOutputFormats = allowedOutputFormats
    }
}

public enum XtreamClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidAuthenticationResponse
    case authenticationRejected(status: String?)
    case accountUnavailable(status: String)
    case unsupportedAccountStatus(status: String)
    case invalidResourceIdentifier

    public var errorDescription: String? {
        switch self {
        case .invalidAuthenticationResponse:
            return "The Xtream server returned an invalid account response."
        case .authenticationRejected:
            return "The Xtream server rejected this account."
        case .accountUnavailable(let status):
            return "The Xtream account is unavailable (\(status))."
        case .unsupportedAccountStatus(let status):
            return "The Xtream server returned an unsupported account status (\(status))."
        case .invalidResourceIdentifier:
            return "The Xtream resource identifier is invalid."
        }
    }
}

public final class XtreamClient: @unchecked Sendable {
    private static let metadataMaximumResponseBytes = 8 * 1_024 * 1_024

    private let httpClient: HTTPClient
    private let credentials: XtreamCredentials
    private let urlBuilder: XtreamURLBuilder
    private let responseDecoder: XtreamResponseDecoder
    private let catalogResponsePolicy: XtreamCatalogResponsePolicy
    private let userAgent: String
    private let requestLimiter: XtreamRequestLimiter

    public init(
        endpoint: XtreamEndpoint,
        credentials: XtreamCredentials,
        httpClient: HTTPClient,
        userAgent: String,
        catalogResponsePolicy: XtreamCatalogResponsePolicy = .initialSafetyDefault,
        maximumConcurrentRequests: Int = 2
    ) {
        self.httpClient = httpClient
        self.credentials = credentials
        urlBuilder = XtreamURLBuilder(endpoint: endpoint)
        responseDecoder = XtreamResponseDecoder()
        self.catalogResponsePolicy = catalogResponsePolicy
        let normalizedUserAgent = userAgent.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.userAgent = normalizedUserAgent.isEmpty ? "OKVideoMac" : normalizedUserAgent
        requestLimiter = XtreamRequestLimiter(
            maximumConcurrentRequests: maximumConcurrentRequests
        )
    }

    public func authenticate(now: Date = Date()) async throws -> XtreamAccount {
        let response = try await request(
            XtreamAuthenticationResponseDTO.self,
            action: nil,
            parameters: [],
            isCatalog: false
        )
        guard let info = response.userInfo else {
            throw XtreamClientError.invalidAuthenticationResponse
        }
        if info.auth == false {
            throw XtreamClientError.authenticationRejected(status: info.status)
        }
        guard let status = info.status?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else {
            throw XtreamClientError.invalidAuthenticationResponse
        }
        let normalizedStatus = status.lowercased()
        guard normalizedStatus == "active" else {
            if Self.isKnownUnavailableStatus(normalizedStatus) {
                throw XtreamClientError.accountUnavailable(status: status)
            }
            throw XtreamClientError.unsupportedAccountStatus(status: status)
        }
        let expirationDate = info.expirationTimestamp.flatMap { timestamp in
            timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
        }
        if let expirationDate, expirationDate <= now {
            // Several Xtream-compatible panels keep `status=Active` after the
            // subscription timestamp has elapsed. Treat that combination as
            // expired instead of enabling a known unusable account.
            throw XtreamClientError.accountUnavailable(status: "Expired")
        }
        return XtreamAccount(
            status: info.status,
            expirationDate: expirationDate,
            isTrial: info.isTrial,
            activeConnections: info.activeConnections,
            maxConnections: info.maxConnections,
            allowedOutputFormats: info.allowedOutputFormats
        )
    }

    public func liveCategories() async throws -> [XtreamCategoryDTO] {
        try await catalog(XtreamCategoryDTO.self, action: .liveCategories)
    }

    public func liveStreams(categoryID: String? = nil) async throws
        -> [XtreamLiveStreamDTO] {
        try await catalog(
            XtreamLiveStreamDTO.self,
            action: .liveStreams,
            parameters: try categoryParameter(categoryID)
        )
    }

    public func vodCategories() async throws -> [XtreamCategoryDTO] {
        try await catalog(
            XtreamCategoryDTO.self,
            action: .vodCategories
        )
    }

    public func vodStreams(categoryID: String? = nil) async throws
        -> [XtreamVODStreamDTO] {
        try await catalog(
            XtreamVODStreamDTO.self,
            action: .vodStreams,
            parameters: try categoryParameter(categoryID)
        )
    }

    public func vodInfo(streamID: String) async throws -> XtreamVODInfoResponseDTO {
        try await request(
            XtreamVODInfoResponseDTO.self,
            action: .vodInfo,
            parameters: [
                URLQueryItem(
                    name: "vod_id",
                    value: try validIdentifier(streamID)
                )
            ],
            isCatalog: false
        )
    }

    public func seriesCategories() async throws -> [XtreamCategoryDTO] {
        try await catalog(
            XtreamCategoryDTO.self,
            action: .seriesCategories
        )
    }

    public func series(categoryID: String? = nil) async throws
        -> [XtreamSeriesDTO] {
        try await catalog(
            XtreamSeriesDTO.self,
            action: .series,
            parameters: try categoryParameter(categoryID)
        )
    }

    public func seriesInfo(seriesID: String) async throws
        -> XtreamSeriesInfoResponseDTO {
        try await request(
            XtreamSeriesInfoResponseDTO.self,
            action: .seriesInfo,
            parameters: [
                URLQueryItem(
                    name: "series_id",
                    value: try validIdentifier(seriesID)
                )
            ],
            isCatalog: false
        )
    }

    public func playbackURL(
        kind: XtreamMediaKind,
        remoteID: String,
        containerExtension: String?
    ) throws -> URL {
        try urlBuilder.playbackURL(
            kind: kind,
            remoteID: validIdentifier(remoteID),
            containerExtension: containerExtension,
            credentials: credentials
        )
    }

    private func catalog<T: Decodable>(
        _ type: T.Type,
        action: XtreamAction,
        parameters: [URLQueryItem] = []
    ) async throws -> [T] {
        let data = try await responseData(
            action: action,
            parameters: parameters,
            isCatalog: true
        )
        return try responseDecoder.decodeArray(type, from: data)
    }

    private func request<T: Decodable>(
        _ type: T.Type,
        action: XtreamAction?,
        parameters: [URLQueryItem],
        isCatalog: Bool
    ) async throws -> T {
        let data = try await responseData(
            action: action,
            parameters: parameters,
            isCatalog: isCatalog
        )
        return try responseDecoder.decode(type, from: data)
    }

    private func responseData(
        action: XtreamAction?,
        parameters: [URLQueryItem],
        isCatalog: Bool
    ) async throws -> Data {
        let url = try urlBuilder.playerAPIURL(
            credentials: credentials,
            action: action,
            parameters: parameters
        )
        let maximumBytes = isCatalog
            ? catalogResponsePolicy.maximumResponseBytes
            : Self.metadataMaximumResponseBytes
        let request = HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json, text/plain;q=0.9",
                "User-Agent": userAgent
            ],
            timeout: 30,
            maximumResponseBytes: maximumBytes,
            earlyResponseLimitBytes: isCatalog ? maximumBytes : nil,
            maximumRedirects: 3,
            redirectPolicy: .sameOriginNoDowngrade,
            retryPolicy: HTTPRetryPolicy(
                maximumRetries: 1,
                initialDelay: 0.25
            )
        )

        try await requestLimiter.acquire()
        do {
            let response = try await httpClient.send(request)
            await requestLimiter.release()
            return response.body
        } catch {
            await requestLimiter.release()
            throw error
        }
    }

    private func categoryParameter(_ categoryID: String?) throws -> [URLQueryItem] {
        guard let categoryID else { return [] }
        return [
            URLQueryItem(
                name: "category_id",
                value: try validIdentifier(categoryID)
            )
        ]
    }

    private func validIdentifier(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw XtreamClientError.invalidResourceIdentifier
        }
        return trimmed
    }

    private static func isKnownUnavailableStatus(_ status: String) -> Bool {
        let unavailableStatuses: Set<String> = [
            "banned", "disabled", "expired", "inactive"
        ]
        if unavailableStatuses.contains(status) {
            return true
        }
        let components = status.components(
            separatedBy: CharacterSet.alphanumerics.inverted
        )
        return components.contains { unavailableStatuses.contains($0) }
    }
}

private actor XtreamRequestLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maximumConcurrentRequests: Int
    private var availablePermits: Int
    private var waiters: [Waiter] = []

    init(maximumConcurrentRequests: Int) {
        let limit = max(1, maximumConcurrentRequests)
        self.maximumConcurrentRequests = limit
        availablePermits = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if availablePermits > 0 {
                    availablePermits -= 1
                    continuation.resume(returning: true)
                } else {
                    waiters.append(
                        Waiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
        guard acquired else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits = min(
                maximumConcurrentRequests,
                availablePermits + 1
            )
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
