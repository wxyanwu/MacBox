import Foundation

public enum XtreamResponseDecodingError: Error, Equatable, LocalizedError, Sendable {
    case emptyResponse
    case htmlResponse
    case malformedJSON
    case unexpectedResponseShape

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "The Xtream server returned an empty response."
        case .htmlResponse:
            return "The Xtream server returned an HTML page instead of API data."
        case .malformedJSON:
            return "The Xtream server returned malformed API data."
        case .unexpectedResponseShape:
            return "The Xtream server returned an unexpected API response."
        }
    }
}

public struct XtreamResponseDecoder: Sendable {
    public init() {}

    public func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        try validate(data)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw XtreamResponseDecodingError.malformedJSON
        }
    }

    public func decodeArray<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> [T] {
        try validate(data)
        if let result = try? JSONDecoder().decode([T].self, from: data) {
            return result
        }
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            switch value {
            case .null:
                return []
            case .object(let object) where object.isEmpty:
                return []
            default:
                throw XtreamResponseDecodingError.unexpectedResponseShape
            }
        }
        throw XtreamResponseDecodingError.malformedJSON
    }

    private func validate(_ data: Data) throws {
        let meaningful = data.drop { byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
        guard let first = meaningful.first else {
            throw XtreamResponseDecodingError.emptyResponse
        }
        if first == Character("<").asciiValue {
            throw XtreamResponseDecodingError.htmlResponse
        }
    }
}
