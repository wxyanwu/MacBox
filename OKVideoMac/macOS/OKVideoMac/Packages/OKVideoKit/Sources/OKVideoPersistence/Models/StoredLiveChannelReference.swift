import Foundation
import OKVideoCore

public enum StoredLiveChannelReferenceError: Error, Equatable, Sendable {
    case invalidXtreamReference
    case unsupportedCollection
}

/// Legacy identifiers are deliberately opaque: names may themselves contain
/// the old `::` separator. Native references never derive identity from names.
public enum StoredLiveChannelReference: Codable, Equatable, Sendable {
    case legacy(String)
    case xtream(providerID: UUID, streamID: String)
    case unsupported(JSONValue)

    public init(setting: JSONValue) {
        if case .string(let identifier) = setting {
            self = .legacy(identifier)
            return
        }
        if case .object(let object) = setting,
           Set(object.keys) == ["version", "kind", "providerID", "streamID"],
           object["version"] == .integer(1),
           object["kind"] == .string("xtream"),
           let rawProviderID = object["providerID"]?.stringValue,
           let providerID = UUID(uuidString: rawProviderID),
           let streamID = object["streamID"]?.stringValue,
           (try? XtreamLivePlaybackLocator(
               providerID: providerID, streamID: streamID, outputFormat: .ts
           )) != nil {
            self = .xtream(providerID: providerID, streamID: streamID)
            return
        }
        self = .unsupported(setting)
    }

    // Raw serialization is reserved for this file's validated encoding and
    // envelope paths. Public callers must not bypass stream ID validation.
    fileprivate var setting: JSONValue {
        switch self {
        case .legacy(let identifier): return .string(identifier)
        case .xtream(let providerID, let streamID):
            return .object([
                "version": .integer(1),
                "kind": .string("xtream"),
                "providerID": .string(providerID.uuidString.lowercased()),
                "streamID": .string(streamID)
            ])
        case .unsupported(let original): return original
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(setting: try JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        try setting.encode(to: encoder)
    }

    fileprivate func validate() throws {
        guard case .xtream(let providerID, let streamID) = self else { return }
        guard (try? XtreamLivePlaybackLocator(
            providerID: providerID, streamID: streamID, outputFormat: .ts
        )) != nil else {
            throw StoredLiveChannelReferenceError.invalidXtreamReference
        }
    }
}

/// Owns only a new versioned reference setting. Imported-source settings are
/// not migrated into it. Unknown array members round-trip unchanged; an
/// unknown root remains read-only instead of being replaced with an empty list.
public struct StoredLiveChannelReferenceEnvelope: Equatable, Sendable {
    public private(set) var references: [StoredLiveChannelReference]
    private let unsupportedRoot: JSONValue?

    public init(setting: JSONValue?) {
        switch setting {
        case nil:
            references = []
            unsupportedRoot = nil
        case .array(let values):
            references = values.map(StoredLiveChannelReference.init(setting:))
            unsupportedRoot = nil
        case .some(let value):
            references = []
            unsupportedRoot = value
        }
    }

    public var isReadOnly: Bool { unsupportedRoot != nil }

    public var setting: JSONValue {
        unsupportedRoot ?? .array(references.map(\.setting))
    }

    public func containsXtream(providerID: UUID, streamID: String) -> Bool {
        references.contains(.xtream(providerID: providerID, streamID: streamID))
    }

    public mutating func setXtream(
        providerID: UUID,
        streamID: String,
        isIncluded: Bool
    ) throws {
        guard !isReadOnly else {
            throw StoredLiveChannelReferenceError.unsupportedCollection
        }
        let reference = StoredLiveChannelReference.xtream(
            providerID: providerID, streamID: streamID
        )
        try reference.validate()
        if isIncluded {
            if !references.contains(reference) { references.append(reference) }
        } else {
            references.removeAll { $0 == reference }
        }
    }
}
