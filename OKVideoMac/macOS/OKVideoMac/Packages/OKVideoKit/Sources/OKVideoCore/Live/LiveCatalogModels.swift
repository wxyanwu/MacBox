import Foundation

public enum LiveModelError: Error, Equatable, Sendable {
    case invalidProviderTarget
}

/// The two source domains must stay distinct even when their UUIDs coincide.
public enum LiveSourceID: Hashable, Sendable {
    case imported(UUID)
    case xtream(UUID)

    public var isXtream: Bool {
        if case .xtream = self { return true }
        return false
    }
}

public enum LiveSourceKind: Equatable, Sendable {
    case imported
    case xtream
}

/// Display metadata only; provider credentials and request URLs are never kept here.
public struct LiveSourceDescriptor: Equatable, Identifiable, Sendable {
    public let id: LiveSourceID
    public var name: String
    public var canRefresh: Bool
    public var canExport: Bool
    public var supportsEPG: Bool

    public var kind: LiveSourceKind {
        switch id {
        case .imported: return .imported
        case .xtream: return .xtream
        }
    }

    public init(
        id: LiveSourceID,
        name: String,
        canRefresh: Bool,
        canExport: Bool,
        supportsEPG: Bool
    ) {
        self.id = id
        self.name = name
        self.canRefresh = canRefresh
        self.canExport = canExport
        self.supportsEPG = supportsEPG
    }
}

/// A source-bound, in-memory catalog, independent of imported playlist formats.
public struct LiveCatalogSnapshot: Equatable, Sendable {
    public let sourceID: LiveSourceID
    public var groups: [LiveGroup]
    public var epgURL: URL?

    public init(sourceID: LiveSourceID, groups: [LiveGroup], epgURL: URL? = nil) {
        self.sourceID = sourceID
        self.groups = groups
        self.epgURL = epgURL
    }
}
