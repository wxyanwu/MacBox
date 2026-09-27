import Foundation

public enum DanmakuJSONParserError: LocalizedError, Equatable {
    case invalidResponse
    case serviceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "弹幕服务返回的数据格式无效"
        case .serviceFailure(let message):
            return "弹幕服务返回错误：\(message)"
        }
    }
}

public struct DanmakuPayloadParser: Sendable {
    public init() {}

    public func parse(_ data: Data) throws -> DanmakuTimeline {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        let prefix = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        if prefix.contains("<!doctype html") || prefix.contains("<html") {
            throw DanmakuJSONParserError.serviceFailure("服务返回了网页，未取得弹幕数据")
        }
        let first = data.first { ![9, 10, 13, 32].contains($0) }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            return try DanmakuJSONParser().parse(data)
        }
        return try BilibiliDanmakuXMLParser().parse(data)
    }
}

public struct DanmakuJSONParser: Sendable {
    public var maximumDocumentBytes: Int
    public var maximumComments: Int
    public var maximumTextCharacters: Int

    public init(
        maximumDocumentBytes: Int = 32 * 1_024 * 1_024,
        maximumComments: Int = 100_000,
        maximumTextCharacters: Int = 512
    ) {
        self.maximumDocumentBytes = max(1, maximumDocumentBytes)
        self.maximumComments = max(1, maximumComments)
        self.maximumTextCharacters = max(1, maximumTextCharacters)
    }

    public func parse(_ data: Data) throws -> DanmakuTimeline {
        guard data.count <= maximumDocumentBytes else {
            throw DanmakuXMLParserError.documentTooLarge
        }
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            throw DanmakuJSONParserError.invalidResponse
        }
        if object["success"] as? Bool == false ||
           (object["errorCode"] as? Int ?? 0) != 0 {
            let message = (object["errorMessage"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = message.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
            throw DanmakuJSONParserError.serviceFailure(
                detail ?? "请求失败"
            )
        }
        guard let values = object["comments"] as? [[String: Any]] else {
            throw DanmakuJSONParserError.invalidResponse
        }
        var comments: [DanmakuComment] = []
        comments.reserveCapacity(min(values.count, maximumComments))
        for (index, value) in values.prefix(maximumComments).enumerated() {
            guard let text = value["m"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let fields = (value["p"] as? String ?? "")
                .split(separator: ",", omittingEmptySubsequences: false)
            let time = fields.first.flatMap { TimeInterval($0) }
                ?? (value["t"] as? NSNumber)?.doubleValue
            guard let time, time.isFinite, time >= 0 else { continue }
            let rawMode = fields.count > 1 ? Int(fields[1]) : nil
            let mode: DanmakuMode
            switch rawMode {
            case 4: mode = .bottom
            case 5: mode = .top
            default: mode = .scrolling
            }
            let hasBilibiliFields = fields.count >= 8
            let rawSize = hasBilibiliFields ? Double(fields[2]) : nil
            let colorField = hasBilibiliFields ? 3 : 2
            let color = fields.count > colorField
                ? UInt32(fields[colorField]) : nil
            let cid = (value["cid"] as? NSNumber)?.stringValue
                ?? value["cid"] as? String
                ?? String(index)
            comments.append(DanmakuComment(
                id: "json-\(cid)-\(index)",
                time: time,
                mode: mode,
                fontSize: min(max(rawSize ?? 25, 12), 72),
                color: min(color ?? 0xFF_FF_FF, 0xFF_FF_FF),
                text: String(text.prefix(maximumTextCharacters))
            ))
        }
        return DanmakuTimeline(comments: comments)
    }
}
