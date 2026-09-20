import Foundation

/// Parser/migration SPI, not an App model or persistent identity. Facts from one
/// successfully parsed channel entry before merge. Source ownership belongs to
/// the caller's source-scoped collector, never inferred from playlist metadata.
/// Secret-bearing lines stay in memory; descriptions deliberately omit them.
@_spi(MigrationDiagnostics)
public struct LiveParserObservation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let format: LiveSourceFormat
    public let ordinal: Int
    public let group: String
    public let name: String
    public let tvgID: String?
    public let tvgName: String?
    public let number: String?
    public let logoReference: String?
    public let streams: [LiveStream]
    // No current format provides a parsed stable upstream channel ID. Do not
    // reinterpret tvg-id or an ignored JSON id field as one.
    public var upstreamID: String? { nil }
    public var description: String { "LiveParserObservation(\(format.rawValue), R\(ordinal), <metadata and lines omitted>)" }
    public var debugDescription: String { description }
}
