import Foundation

public enum XtreamLiveOutputFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case ts
    case m3u8
}

public enum XtreamLivePlaybackLocatorError: Error, Equatable, Sendable {
    case invalidLocator
}

/// A credential-free channel locator. It is not a media URL or an episode.
/// The provider binding and output format are part of the playback target;
/// only providerID + streamID constitute the channel's durable identity.
public struct XtreamLivePlaybackLocator: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let providerID: UUID
    public let streamID: String
    public let outputFormat: XtreamLiveOutputFormat

    public init(
        providerID: UUID,
        streamID: String,
        outputFormat: XtreamLiveOutputFormat
    ) throws {
        guard Self.isValidStreamID(streamID) else {
            throw XtreamLivePlaybackLocatorError.invalidLocator
        }
        version = Self.currentVersion
        self.providerID = providerID
        self.streamID = streamID
        self.outputFormat = outputFormat
    }

    /// xtr1.l.<canonical provider UUID>.<lowercase hex stream ID>.<ts|m3u8>
    /// Keeping one canonical encoding prevents alternate spellings from
    /// producing multiple identities for the same runtime playback target.
    public var encoded: String {
        let identifier = Data(streamID.utf8).map {
            String(format: "%02x", $0)
        }.joined()
        return "xtr1.l.\(providerID.uuidString.lowercased()).\(identifier).\(outputFormat.rawValue)"
    }

    public init(encoded: String) throws {
        guard encoded.utf8.count <= 1_100 else {
            throw XtreamLivePlaybackLocatorError.invalidLocator
        }
        let components = encoded.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 5,
              components[0] == "xtr1",
              components[1] == "l",
              let providerID = UUID(uuidString: String(components[2])),
              let streamID = Self.decodeIdentifier(String(components[3])),
              let format = XtreamLiveOutputFormat(rawValue: String(components[4])) else {
            throw XtreamLivePlaybackLocatorError.invalidLocator
        }
        try self.init(providerID: providerID, streamID: streamID, outputFormat: format)
        guard self.encoded == encoded else {
            throw XtreamLivePlaybackLocatorError.invalidLocator
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, providerID, streamID, outputFormat
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == Self.currentVersion else {
            throw XtreamLivePlaybackLocatorError.invalidLocator
        }
        try self.init(
            providerID: values.decode(UUID.self, forKey: .providerID),
            streamID: values.decode(String.self, forKey: .streamID),
            outputFormat: values.decode(XtreamLiveOutputFormat.self, forKey: .outputFormat)
        )
    }

    private static func isValidStreamID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512,
              value != ".", value != ".." else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: ":/\\?#%"))
        return !value.unicodeScalars.contains { forbidden.contains($0) }
    }

    private static func decodeIdentifier(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 1_024, value.count.isMultiple(of: 2) else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        return String(data: data, encoding: .utf8)
    }
}
