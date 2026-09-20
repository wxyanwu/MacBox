import Foundation

/// A memory-only master. Media playlists, segments, keys and ranges remain
/// untouched and are still loaded by libmpv. Never persist this credential-
/// bearing value or include it in diagnostics.
public struct HLSStartupSelection: Equatable, Sendable {
    public let playlist: String
    public let routingURL: URL
    public let variantCount: Int

    public static func select(from data: Data, baseURL: URL) -> Self? {
        // At the read limit, the response may be only a prefix of a larger master.
        guard data.count < 256 * 1024,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0"),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U", lines.count <= 4096 else { return nil }
        var globals = ["#EXTM3U"]
        var media: [[String: String]] = []
        var variants: [(attributes: [String: String], url: URL)] = []
        var pending: [String: String]?
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                guard pending == nil,
                      let attrs = attributes(String(line.dropFirst(18))),
                      attrs["BANDWIDTH"].flatMap(Int.init).map({ $0 > 0 }) == true else { return nil }
                pending = attrs
            } else if !line.hasPrefix("#") {
                guard let attrs = pending, let url = resolve(line, against: baseURL) else { return nil }
                variants.append((attrs, url)); pending = nil
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                guard pending == nil,
                      let attrs = attributes(String(line.dropFirst(13))) else { return nil }
                media.append(attrs)
            } else if line.hasPrefix("#EXT-X-VERSION:") || line == "#EXT-X-INDEPENDENT-SEGMENTS" {
                globals.append(line)
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                // Trick-play variants are not needed for startup.
                continue
            } else if line.hasPrefix("#EXT") {
                // Content steering, variables, session keys, LL-HLS and future
                // extensions require separate semantics. Preserve original load.
                return nil
            }
        }
        guard pending == nil, variants.count >= 2 else { return nil }
        // Choose a video rendition without imposing a new resolution ceiling.
        // CODECS is optional in HLS (including the Open HLS fixture). A missing
        // declaration is left to the player; the complete associated media
        // groups remain attached and the caller can retry the original master.
        let eligible = variants.filter { item in
            let a = item.attributes
            guard let resolution = a["RESOLUTION"] else { return false }
            if let codecs = value(a["CODECS"]) {
                let parts = codecs.split(separator: ",").map(String.init)
                let video = ["avc1.", "avc3.", "hvc1.", "hev1."]
                guard parts.contains(where: { part in video.contains(where: { part.hasPrefix($0) }) }),
                      parts.allSatisfy({ part in
                          video.contains(where: { part.hasPrefix($0) })
                              || part.hasPrefix("mp4a.40.") || part == "ac-3" || part == "ec-3"
                      }) else { return false }
            }
            let size = resolution.split(separator: "x").compactMap { Int($0) }
            guard size.count == 2, size[0] > 0, size[1] > 0 else { return false }
            if let rawFPS = a["FRAME-RATE"] {
                guard let fps = Double(rawFPS), fps.isFinite, fps > 0 else { return false }
            }
            return a["VIDEO"] == nil
        }
        guard let selected = eligible.max(by: {
            (Int($0.attributes["BANDWIDTH"] ?? "") ?? 0) < (Int($1.attributes["BANDWIDTH"] ?? "") ?? 0)
        }) else { return nil }
        // An unsupported higher-quality rendition should keep the original
        // master's selection behavior rather than silently downgrade quality.
        let selectedBandwidth = Int(selected.attributes["BANDWIDTH"] ?? "") ?? 0
        guard !variants.contains(where: {
            $0.attributes["RESOLUTION"] != nil
                && (Int($0.attributes["BANDWIDTH"] ?? "") ?? 0) > selectedBandwidth
        }) else { return nil }
        var result = globals
        for (key, type) in [("AUDIO", "AUDIO"), ("SUBTITLES", "SUBTITLES"), ("CLOSED-CAPTIONS", "CLOSED-CAPTIONS")] {
            guard let group = value(selected.attributes[key]), group != "NONE" else { continue }
            let matches = media.filter { value($0["TYPE"]) == type && value($0["GROUP-ID"]) == group }
            guard !matches.isEmpty else { return nil }
            for var entry in matches {
                if let uri = value(entry["URI"]) {
                    guard let url = resolve(uri, against: baseURL) else { return nil }
                    entry["URI"] = "\"\(url.absoluteString)\""
                } else if type == "SUBTITLES" { return nil }
                result.append("#EXT-X-MEDIA:" + serialize(entry))
            }
        }
        result.append("#EXT-X-STREAM-INF:" + serialize(selected.attributes))
        result.append(selected.url.absoluteString)
        return Self(playlist: result.joined(separator: "\n") + "\n", routingURL: selected.url, variantCount: variants.count)
    }

    private static func resolve(_ value: String, against base: URL) -> URL? {
        guard !value.contains("\""), !value.contains("\r"), !value.contains("\n"),
              !value.contains("{$"),
              let url = URL(string: value, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private static func value(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.hasPrefix("\"") && raw.hasSuffix("\"") ? String(raw.dropFirst().dropLast()) : raw
    }

    private static func attributes(_ text: String) -> [String: String]? {
        var quoted = false, current = "", parts: [String] = []
        for character in text {
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted { parts.append(current); current = "" }
            else { current.append(character) }
        }
        guard !quoted else { return nil }
        parts.append(current)
        var result: [String: String] = [:]
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = String(pair[0]), raw = String(pair[1])
            guard !key.isEmpty, !raw.isEmpty, result[key] == nil,
                  key.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "-") }) else { return nil }
            result[key] = raw
        }
        return result
    }

    private static func serialize(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: ",")
    }
}
