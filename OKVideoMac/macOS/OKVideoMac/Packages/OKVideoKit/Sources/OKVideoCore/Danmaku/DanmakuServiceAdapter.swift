import Foundation
import CryptoKit

/// Search metadata is separate from the temporary comment URL/episode number.
public struct DanmakuMatchMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var year: String?
    public var season: Int?
    public var episode: Int?
    public var form: PlaybackContentForm
    public var role: PlaybackResourceSemantics.Role
    public var workID: String
    public var videoID: String?
    public var serviceEpisodeID: String

    public init(title: String, year: String? = nil, season: Int? = nil, episode: Int? = nil,
                form: PlaybackContentForm = .unknown, role: PlaybackResourceSemantics.Role = .main,
                workID: String, videoID: String? = nil, serviceEpisodeID: String) {
        self.title = title; self.year = year; self.season = season; self.episode = episode
        self.form = form; self.role = role; self.workID = workID; self.videoID = videoID
        self.serviceEpisodeID = serviceEpisodeID
    }
}

/// Dandan-compatible episode API. Provider web pages are deliberately not API bases.
public struct DanmakuServiceEndpoint: Equatable, Sendable {
    public let url: URL
    public let headers: HTTPHeaders
    public let identity: String

    public init?(url: URL, headers: HTTPHeaders = [:], identity: String? = nil) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, !url.path.contains("/website/"),
              !["html", "htm"].contains(url.pathExtension.lowercased()) else { return nil }
        self.url = url; self.headers = headers
        var base = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let range = base.path.range(of: "/api/v2") { base.path = String(base.path[..<range.lowerBound]) }
        base.query = nil; base.fragment = nil; base.user = nil; base.password = nil
        let canonical = base.string!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.identity = identity ?? "service:" + SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var base: URLComponents {
        var value = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if let range = value.path.range(of: "/api/v2") { value.path = String(value.path[..<range.lowerBound]) }
        value.path = value.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        value.fragment = nil
        return value
    }

    public func searchURL(keyword: String) -> URL? {
        var value = base
        value.path = "/" + [value.path, "api/v2/search/episodes"].filter { !$0.isEmpty }.joined(separator: "/")
        var query = value.queryItems ?? []
        query.removeAll { ["anime", "format"].contains($0.name) }
        query.append(URLQueryItem(name: "anime", value: keyword))
        value.queryItems = query
        return value.url
    }

    public func commentURL(resourceID: String, format: String = "xml") -> URL? {
        guard !resourceID.isEmpty, !resourceID.contains("/"), !resourceID.contains("..") else { return nil }
        var value = base
        value.path = "/" + [value.path, "api/v2/comment", resourceID].filter { !$0.isEmpty }.joined(separator: "/")
        var query = value.queryItems ?? []
        query.removeAll { ["anime", "format"].contains($0.name) }
        query.append(URLQueryItem(name: "format", value: format)); value.queryItems = query
        return value.url
    }

    public func decode(_ data: Data, generation: UInt64) throws -> [DanmakuSourceDescriptor] {
        guard data.count <= 4 * 1_024 * 1_024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DanmakuJSONParserError.invalidResponse
        }
        if root["success"] as? Bool == false || (root["errorCode"] as? Int ?? 0) != 0 {
            throw DanmakuJSONParserError.serviceFailure("搜索服务暂不可用")
        }
        var output: [DanmakuSourceDescriptor] = []
        func string(_ object: [String: Any], _ keys: [String]) -> String? {
            for key in keys {
                if let v = object[key] as? String, !v.isEmpty { return v }
                if let v = object[key] as? NSNumber { return v.stringValue }
            }
            return nil
        }
        func walk(_ value: Any, work: String?, workID: String?, category: String?, depth: Int) {
            guard depth < 8, output.count < 2_000 else { return }
            if let array = value as? [Any] {
                for child in array { walk(child, work: work, workID: workID, category: category, depth: depth + 1) }
                return
            }
            guard let object = value as? [String: Any] else { return }
            let anime = string(object, ["animeTitle"]) ?? work
            let groupID = string(object, ["animeId"]) ?? workID
            let kind = string(object, ["typeDescription", "type"]) ?? category
            let name = string(object, ["episodeTitle", "title", "name"]) ?? anime ?? "弹幕来源"
            let episodeID = string(object, ["episodeId", "episode_id", "commentId"])
            let webpage = string(object, ["url", "href"]).flatMap(URL.init(string:))
            if let episodeID, let resource = commentURL(resourceID: episodeID) {
                let reference = Self.platformIdentity(webpage)
                let title = anime ?? name
                let parsed = PlaybackResourceAnalyzer.analyze(PlayEpisode(name: name, url: ""), categoryName: kind)
                let episode = parsed.endEpisode == nil && parsed.evidence != .conflict
                    ? (parsed.episode ?? Self.trailingEpisode(name)) : nil
                let meta = DanmakuMatchMetadata(title: title, year: Self.year(title),
                    season: parsed.season ?? Self.season(title), episode: episode,
                    form: PlaybackContentForm.category(kind), role: parsed.role,
                    workID: reference?.work ?? "title:\(Self.normalizedTitle(title)):\(Self.year(title) ?? ""):\(Self.season(title).map(String.init) ?? "")",
                    videoID: reference?.video, serviceEpisodeID: episodeID)
                // Use provider video identity where available; runtime episode IDs may be regenerated.
                let stableID = reference?.video ?? "episode:\(groupID ?? Self.normalizedTitle(title)):\(episodeID)"
                var descriptor = DanmakuSourceDescriptor(stable: .init(kind: .providerEpisode,
                    provider: identity, resourceID: stableID, displayName: name),
                    runtime: .init(url: resource, headers: headers, runtimeGeneration: generation))
                descriptor.match = meta
                output.append(descriptor)
            } else if let direct = string(object, ["xml", "danmaku"])
                ?? (webpage?.pathExtension.lowercased() == "xml" ? webpage?.absoluteString : nil),
                      let resource = URL(string: direct, relativeTo: url)?.absoluteURL,
                      ["http", "https"].contains(resource.scheme ?? "") {
                output.append(DanmakuSourceDescriptor(stable: .init(kind: .providerURLIdentity,
                    provider: identity, resourceID: PlaybackReferenceIdentity.episode(name: name, reference: direct), displayName: name),
                    runtime: .init(url: resource, headers: headers, runtimeGeneration: generation)))
            }
            for key in ["data", "result", "results", "list", "items", "animes", "episodes"] {
                if let child = object[key] { walk(child, work: anime, workID: groupID, category: kind, depth: depth + 1) }
            }
        }
        walk(root, work: nil, workID: nil, category: nil, depth: 0)
        var seen = Set<String>()
        return output.filter { seen.insert($0.id).inserted }
    }

    public static func normalizedTitle(_ title: String) -> String {
        var value = title.precomposedStringWithCompatibilityMapping.lowercased()
        for pattern in [#"\s*from\s+(?:tencent|qq|iqiyi|youku|bilibili|mgtv)\s*$"#, #"[【\[](?:电视剧|电影|动漫|综艺|qq|腾讯|爱奇艺|优酷|芒果)[\]】]"#,
                        #"[（(](?:19|20)[0-9]{2}[)）]"#,
                        #"[（(](?:臻彩|4k|高清|超清|蓝光)[)）]"#] {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return value.filter { !$0.isWhitespace && !"·_-:：".contains($0) }
    }
    public static func year(_ text: String) -> String? {
        capture(#"(?:^|[^0-9])((?:19|20)[0-9]{2})(?:[^0-9]|$)"#, text)
    }
    public static func season(_ text: String) -> Int? {
        let parsed = PlaybackResourceAnalyzer.analyze(PlayEpisode(name: text + " 第1集", url: ""))
        return parsed.evidence == .conflict ? nil : parsed.season
    }
    private static func trailingEpisode(_ text: String) -> Int? {
        capture(#"[_\-]\s*([0-9]{1,4})\s*$"#, text).flatMap(Int.init)
    }
    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private static func platformIdentity(_ url: URL?) -> (work: String, video: String)? {
        guard let url, url.host == "v.qq.com" else { return nil }
        let path = url.pathComponents
        guard path.count >= 5, path[1] == "x", path[2] == "cover" else { return nil }
        return ("qq:\(path[3])", "qq:\(url.deletingPathExtension().lastPathComponent)")
    }
}
