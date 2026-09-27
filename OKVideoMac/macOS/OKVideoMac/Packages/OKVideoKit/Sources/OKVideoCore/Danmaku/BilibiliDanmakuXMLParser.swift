import Foundation

public enum DanmakuXMLParserError: LocalizedError, Equatable {
    case documentTooLarge
    case invalidXML(String)

    public var errorDescription: String? {
        switch self {
        case .documentTooLarge:
            return "弹幕文件超过大小限制"
        case .invalidXML(let message):
            return "弹幕 XML 无效：\(message)"
        }
    }
}

public struct BilibiliDanmakuXMLParser: Sendable {
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
        let delegate = Delegate(
            maximumComments: maximumComments,
            maximumTextCharacters: maximumTextCharacters
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "无法解析"
            throw DanmakuXMLParserError.invalidXML(message)
        }
        guard delegate.isDanmakuDocument else {
            throw DanmakuXMLParserError.invalidXML("文件不是支持的弹幕格式")
        }
        return DanmakuTimeline(comments: delegate.comments)
    }
}

private final class Delegate: NSObject, XMLParserDelegate {
    let maximumComments: Int
    let maximumTextCharacters: Int
    var comments: [DanmakuComment] = []
    var isDanmakuDocument = false
    private var sawRoot = false
    private var fields: [Substring] = []
    private var text = ""
    private var commentOrdinal = 0
    private var isReadingComment = false

    init(maximumComments: Int, maximumTextCharacters: Int) {
        self.maximumComments = maximumComments
        self.maximumTextCharacters = maximumTextCharacters
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if !sawRoot {
            sawRoot = true
            isDanmakuDocument = elementName == "i"
        }
        guard elementName == "d", comments.count < maximumComments else { return }
        fields = (attributeDict["p"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
        text = ""
        isReadingComment = fields.count >= 4
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isReadingComment, text.count < maximumTextCharacters else { return }
        text.append(contentsOf: string.prefix(maximumTextCharacters - text.count))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "d", isReadingComment else { return }
        defer {
            isReadingComment = false
            fields = []
            text = ""
        }
        guard comments.count < maximumComments,
              let time = TimeInterval(fields[0]), time.isFinite, time >= 0,
              let rawMode = Int(fields[1]),
              let rawSize = Double(fields[2]), rawSize.isFinite,
              let rawColor = UInt32(fields[3]),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let mode: DanmakuMode
        switch rawMode {
        case 4: mode = .bottom
        case 5: mode = .top
        default: mode = .scrolling
        }
        let sourceID = fields.count > 7 ? String(fields[7]) : ""
        commentOrdinal += 1
        comments.append(DanmakuComment(
            id: sourceID.isEmpty ? "xml-\(commentOrdinal)" : "\(sourceID)-\(commentOrdinal)",
            time: time,
            mode: mode,
            fontSize: min(max(rawSize, 12), 72),
            color: min(rawColor, 0xFF_FF_FF),
            text: text
        ))
    }
}
