import Foundation

public enum EPGChannelMatchKind: String, Equatable, Sendable {
    case exact, normalizedUnique, ambiguous, unmatched
}

public struct EPGChannelMatch: Equatable, Sendable {
    public let kind: EPGChannelMatchKind
    public let channelID: String?

    public init(kind: EPGChannelMatchKind, channelID: String?) {
        self.kind = kind
        self.channelID = channelID
    }
}

/// Shared, deterministic keys for the in-memory matcher and the SQLite EPG
/// index. SQLite only compares these prepared keys with BINARY collation.
public enum XMLTVChannelNormalization {
    private static let cctv = try! NSRegularExpression(pattern: "^CCTV[ -]?([1-9]|1[0-7])(\\+)?$")

    /// Swift String equality treats canonically equivalent identifiers as the
    /// same value. NFC gives SQLite the same exact-ID key without applying any
    /// name heuristics, case folding, or quality-suffix removal.
    public static func exactIDKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    public static func nameVariants(_ value: String) -> Set<String> {
        let base = normalizedName(value)
        guard !base.isEmpty else { return [] }
        var result: Set<String> = [channelForm(base)]
        for suffix in ["高清", "超清", "HD"] where base.hasSuffix(suffix) {
            let rawStem = String(base.dropLast(suffix.count))
            let stem = rawStem.trimmingCharacters(in: .whitespaces)
            guard !stem.isEmpty else { continue }
            // English HD must be an explicit token, a CCTV suffix, or follow
            // a CJK name. Do not strip arbitrary ASCII word endings.
            if suffix == "HD", !rawStem.hasSuffix(" "), !isCCTV(stem),
               !(stem.unicodeScalars.last.map { (0x3400...0x9FFF).contains($0.value) } ?? false) { continue }
            result.insert(channelForm(stem))
        }
        return result
    }

    private static func normalizedName(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func isCCTV(_ value: String) -> Bool {
        cctv.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func channelForm(_ value: String) -> String {
        isCCTV(value) ? value.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "") : value
    }
}

/// Immutable name index. Candidate identity never depends on programme coverage.
public struct XMLTVChannelMatcher: Sendable {
    private var knownIDs: Set<String>
    private var idsByName: [String: Set<String>] = [:]

    public init(guide: XMLTVGuide) {
        knownIDs = Set(guide.channels.map(\.id)).union(guide.programmes.map(\.channelID))
        for id in knownIDs {
            for name in XMLTVChannelNormalization.nameVariants(id) { idsByName[name, default: []].insert(id) }
        }
        for channel in guide.channels {
            for alias in [channel.displayName] + (channel.aliases ?? []) {
                for name in XMLTVChannelNormalization.nameVariants(alias) { idsByName[name, default: []].insert(channel.id) }
            }
        }
    }

    public func match(_ channel: LiveChannel) -> EPGChannelMatch {
        if let id = channel.tvgID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return EPGChannelMatch(kind: knownIDs.contains(id) ? .exact : .unmatched,
                                   channelID: knownIDs.contains(id) ? id : nil)
        }
        var candidates = Set<String>()
        for alias in [channel.name, channel.tvgName ?? ""] {
            for name in XMLTVChannelNormalization.nameVariants(alias) { candidates.formUnion(idsByName[name] ?? []) }
        }
        if candidates.count > 1 { return EPGChannelMatch(kind: .ambiguous, channelID: nil) }
        guard let id = candidates.first else { return EPGChannelMatch(kind: .unmatched, channelID: nil) }
        return EPGChannelMatch(kind: .normalizedUnique, channelID: id)
    }

}
