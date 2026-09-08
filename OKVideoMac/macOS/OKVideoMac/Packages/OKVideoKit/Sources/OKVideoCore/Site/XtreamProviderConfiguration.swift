import Foundation

public enum XtreamProviderConfigurationError: Error, Equatable,
    LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case invalidProviderID
    case invalidDisplayName
    case invalidServerURL
    case malformedConfiguration

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Xtream provider configuration version \(version) is unsupported."
        case .invalidProviderID:
            return "The Xtream provider identity is invalid."
        case .invalidDisplayName:
            return "The Xtream provider name is invalid."
        case .invalidServerURL:
            return "The Xtream server URL is invalid."
        case .malformedConfiguration:
            return "The Xtream provider configuration is malformed."
        }
    }
}

/// A credential-free persisted descriptor. Username and password are excluded
/// from the type itself and live only in `XtreamCredentialStoring`.
public struct XtreamProviderConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let nativeAPIIdentifier = "native:xtream"
    public static let nativeSiteType = -100

    public let version: Int
    public let providerID: UUID
    public let displayName: String
    public let serverBaseURL: URL

    public init(
        version: Int = currentVersion,
        providerID: UUID,
        displayName: String,
        serverBaseURL: URL
    ) throws {
        guard version == Self.currentVersion else {
            throw XtreamProviderConfigurationError.unsupportedVersion(version)
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256 else {
            throw XtreamProviderConfigurationError.invalidDisplayName
        }
        guard let endpoint = try? XtreamEndpoint(serverURL: serverBaseURL) else {
            throw XtreamProviderConfigurationError.invalidServerURL
        }
        self.version = version
        self.providerID = providerID
        self.displayName = name
        self.serverBaseURL = endpoint.serverURL
    }

    public init(data: Data) throws {
        let decoded: XtreamProviderConfiguration
        do {
            decoded = try JSONDecoder().decode(Self.self, from: data)
        } catch let error as XtreamProviderConfigurationError {
            throw error
        } catch {
            throw XtreamProviderConfigurationError.malformedConfiguration
        }
        try self.init(
            version: decoded.version,
            providerID: decoded.providerID,
            displayName: decoded.displayName,
            serverBaseURL: decoded.serverBaseURL
        )
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public var siteKey: String {
        "xtream:\(providerID.uuidString.lowercased())"
    }

    public var providerConfiguration: FongMiConfiguration {
        FongMiConfiguration(
            sites: [
                SiteConfiguration(
                    key: siteKey,
                    name: displayName,
                    type: Self.nativeSiteType,
                    api: Self.nativeAPIIdentifier,
                    searchable: 1,
                    changeable: 0,
                    quickSearch: 1,
                    extra: ["okNativeProvider": .string("xtream")]
                )
            ]
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case providerID
        case displayName
        case serverBaseURL
    }
}
