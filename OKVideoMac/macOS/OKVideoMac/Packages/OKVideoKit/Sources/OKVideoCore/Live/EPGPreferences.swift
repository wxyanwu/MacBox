import Foundation

public enum EPGSourceMode: String, Codable, CaseIterable, Sendable {
    case automatic, custom, disabled
}

public struct EPGSourcePreference: Codable, Equatable, Sendable {
    public var mode: EPGSourceMode
    public var customEPGURL: String?
    public init(mode: EPGSourceMode = .automatic, customEPGURL: String? = nil) {
        self.mode = mode
        self.customEPGURL = customEPGURL
    }
    private enum CodingKeys: String, CodingKey { case mode, customEPGURL }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(EPGSourceMode.self, forKey: .mode) ?? .automatic
        customEPGURL = try values.decodeIfPresent(String.self, forKey: .customEPGURL)
    }
}

public struct ResolvedXMLTVSource: Equatable, Sendable {
    public enum Origin: String, Sendable { case custom, embedded, global }
    public let url: URL
    public let origin: Origin
    public var revision: String { EPGRequestKey.revision(for: Data(url.absoluteString.utf8)) }
}

public enum EPGPreferenceError: Error, Equatable { case invalidURL }

/// Versioned Settings value, not a second live-source database or cache.
/// URL strings are configuration (may contain tokens); never log this value.
public struct EPGPreferences: Codable, Equatable, Sendable {
    public var automaticEPGEnabled: Bool
    public var defaultEPGURL: String?
    public var sources: [String: EPGSourcePreference]

    public init(automaticEPGEnabled: Bool = true, defaultEPGURL: String? = nil,
                sources: [String: EPGSourcePreference] = [:]) {
        self.automaticEPGEnabled = automaticEPGEnabled
        self.defaultEPGURL = defaultEPGURL
        self.sources = sources
    }
    private enum CodingKeys: String, CodingKey { case automaticEPGEnabled, defaultEPGURL, sources }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automaticEPGEnabled = try values.decodeIfPresent(Bool.self, forKey: .automaticEPGEnabled) ?? true
        defaultEPGURL = try values.decodeIfPresent(String.self, forKey: .defaultEPGURL)
        sources = try values.decodeIfPresent([String: EPGSourcePreference].self, forKey: .sources) ?? [:]
    }
    public func source(_ id: UUID) -> EPGSourcePreference {
        sources[id.uuidString] ?? EPGSourcePreference()
    }
    public func resolvedXMLTV(for source: LiveSourceID, embedded: URL?) -> ResolvedXMLTVSource? {
        guard automaticEPGEnabled, case .imported(let id) = source else { return nil }
        let preference = self.source(id)
        switch preference.mode {
        case .disabled: return nil
        case .custom:
            guard let url = try? Self.validatedURL(preference.customEPGURL, required: true) else { return nil }
            return ResolvedXMLTVSource(url: url, origin: .custom)
        case .automatic:
            if let embedded { return ResolvedXMLTVSource(url: embedded, origin: .embedded) }
            guard let url = try? Self.validatedURL(defaultEPGURL) else { return nil }
            return ResolvedXMLTVSource(url: url, origin: .global)
        }
    }

    public static func validatedURL(_ text: String?, required: Bool = false) throws -> URL? {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            if required { throw EPGPreferenceError.invalidURL }
            return nil
        }
        guard value.utf8.count <= 8192,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              let url = components.url else { throw EPGPreferenceError.invalidURL }
        return url
    }

    public func validated() throws -> Self {
        var result = self
        result.defaultEPGURL = try Self.validatedURL(defaultEPGURL)?.absoluteString
        for (id, preference) in sources {
            guard UUID(uuidString: id) != nil else { throw EPGPreferenceError.invalidURL }
            var value = preference
            value.customEPGURL = preference.mode == .custom
                ? try Self.validatedURL(preference.customEPGURL, required: true)?.absoluteString : nil
            result.sources[id] = value
        }
        return result
    }
}
