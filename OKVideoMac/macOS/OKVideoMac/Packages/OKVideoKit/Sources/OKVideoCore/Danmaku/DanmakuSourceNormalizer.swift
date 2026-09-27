import Foundation
import CryptoKit

public enum DanmakuSourceNormalizer {
    private static let containerKeys = [
        "danmaku", "danmu", "sources", "source", "urls", "list", "data", "extra"
    ]
    private static let urlKeys = ["url", "href", "link", "file", "xml"]
    private static let nameKeys = ["name", "title", "label"]
    private static let idKeys = ["episodeId", "episode_id", "id", "resourceId"]

    public static func sources(
        from value: JSONValue?,
        provider: String,
        baseURL: URL? = nil,
        inheritedHeaders: HTTPHeaders = [:],
        runtimeGeneration: UInt64
    ) -> [DanmakuSourceDescriptor] {
        guard let value else { return [] }
        var output: [DanmakuSourceDescriptor] = []
        collect(
            value,
            provider: provider,
            baseURL: baseURL,
            inheritedHeaders: inheritedHeaders,
            runtimeGeneration: runtimeGeneration,
            depth: 0,
            output: &output
        )
        var seen = Set<String>()
        return output.filter { seen.insert($0.id).inserted }
    }

    private static func collect(
        _ value: JSONValue,
        provider: String,
        baseURL: URL?,
        inheritedHeaders: HTTPHeaders,
        runtimeGeneration: UInt64,
        depth: Int,
        output: inout [DanmakuSourceDescriptor]
    ) {
        guard depth < 8, output.count < 64 else { return }
        switch value {
        case .string(let rawValue):
            let string = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !string.isEmpty else { return }
            if let data = string.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
               decoded != value {
                collect(
                    decoded,
                    provider: provider,
                    baseURL: baseURL,
                    inheritedHeaders: inheritedHeaders,
                    runtimeGeneration: runtimeGeneration,
                    depth: depth + 1,
                    output: &output
                )
                return
            }
            if string.hasPrefix("<"), let data = string.data(using: .utf8), data.count <= 32 * 1_024 * 1_024 {
                output.append(inlineSource(data, provider: provider, generation: runtimeGeneration))
                return
            }
            if let source = makeSource(
                rawURL: string,
                name: nil,
                explicitResourceID: nil,
                provider: provider,
                baseURL: baseURL,
                headers: inheritedHeaders,
                preferred: false,
                runtimeGeneration: runtimeGeneration
            ) {
                output.append(source)
            }

        case .array(let values):
            for child in values {
                collect(
                    child,
                    provider: provider,
                    baseURL: baseURL,
                    inheritedHeaders: inheritedHeaders,
                    runtimeGeneration: runtimeGeneration,
                    depth: depth + 1,
                    output: &output
                )
            }

        case .object(let object):
            if object["comments"] != nil, let data = try? JSONEncoder().encode(value), data.count <= 32 * 1_024 * 1_024 {
                output.append(inlineSource(data, provider: provider, generation: runtimeGeneration))
                return
            }
            let headers = inheritedHeaders.merging(headers(from: object["headers"]))
            let rawURL = firstString(in: object, keys: urlKeys)
            let name = firstString(in: object, keys: nameKeys)
            let explicitID = firstString(in: object, keys: idKeys)
            let preferred = bool(in: object, keys: ["preferred", "default", "selected"])
            if let rawURL,
               let source = makeSource(
                   rawURL: rawURL,
                   name: name,
                   explicitResourceID: explicitID,
                   provider: provider,
                   baseURL: baseURL,
                   headers: headers,
                   preferred: preferred,
                   runtimeGeneration: runtimeGeneration
               ) {
                output.append(source)
            }
            for key in containerKeys {
                guard let child = object[key], child != .string(rawURL ?? "") else {
                    continue
                }
                collect(
                    child,
                    provider: provider,
                    baseURL: baseURL,
                    inheritedHeaders: headers,
                    runtimeGeneration: runtimeGeneration,
                    depth: depth + 1,
                    output: &output
                )
            }

        case .null, .bool, .integer, .number:
            break
        }
    }

    private static func inlineSource(_ data: Data, provider: String, generation: UInt64) -> DanmakuSourceDescriptor {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var runtime = RuntimeDanmakuLocator(url: URL(string: "danmaku-inline://payload/" + digest)!, runtimeGeneration: generation)
        runtime.inlineData = data
        return .init(stable: .init(kind: .providerURLIdentity, provider: provider, resourceID: digest, displayName: "本集弹幕"), runtime: runtime)
    }

    private static func makeSource(
        rawURL: String,
        name: String?,
        explicitResourceID: String?,
        provider: String,
        baseURL: URL?,
        headers: HTTPHeaders,
        preferred: Bool,
        runtimeGeneration: UInt64
    ) -> DanmakuSourceDescriptor? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url: URL?
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            url = absolute
        } else if let baseURL {
            url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        } else {
            url = nil
        }
        guard let url,
              url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? provider
        let resourceID = explicitResourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? PlaybackReferenceIdentity.episode(name: displayName, reference: trimmed)
        let kind: StableDanmakuLocator.Kind = explicitResourceID?.nilIfEmpty == nil
            ? (url.isFileURL ? .localBookmark : .providerURLIdentity)
            : .providerEpisode
        return DanmakuSourceDescriptor(
            stable: StableDanmakuLocator(
                kind: kind,
                provider: provider,
                resourceID: resourceID,
                displayName: displayName
            ),
            runtime: RuntimeDanmakuLocator(
                url: url,
                headers: headers,
                runtimeGeneration: runtimeGeneration
            ),
            isPreferred: preferred
        )
    }

    private static func firstString(
        in object: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if case .string(let value)? = object[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func bool(
        in object: [String: JSONValue],
        keys: [String]
    ) -> Bool {
        for key in keys {
            switch object[key] {
            case .bool(let value): return value
            case .integer(let value): return value != 0
            case .string(let value):
                return ["true", "1", "yes", "default", "preferred"]
                    .contains(value.lowercased())
            default: break
            }
        }
        return false
    }

    private static func headers(from value: JSONValue?) -> HTTPHeaders {
        guard case .object(let object)? = value else { return [:] }
        var output: [String: String] = [:]
        for (key, value) in object.prefix(64) {
            if case .string(let string) = value,
               key.count <= 128,
               string.count <= 8_192 {
                output[key] = string
            }
        }
        return HTTPHeaders(output)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
