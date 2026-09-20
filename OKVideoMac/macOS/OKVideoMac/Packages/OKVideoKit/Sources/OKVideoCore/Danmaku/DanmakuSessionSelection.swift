import Foundation

/// Owns source-selection races independently of networking and rendering.
public struct DanmakuSessionSelection: Equatable, Sendable {
    public private(set) var playbackSessionID: UUID
    public private(set) var runtimeGeneration: UInt64
    public private(set) var selectionRevision: UInt64
    public private(set) var selectedSource: DanmakuSourceDescriptor?
    public private(set) var authority: DanmakuSelectionAuthority

    public init(playbackSessionID: UUID, runtimeGeneration: UInt64) {
        self.playbackSessionID = playbackSessionID
        self.runtimeGeneration = runtimeGeneration
        selectionRevision = 0
        selectedSource = nil
        authority = .none
    }

    @discardableResult
    public mutating func select(
        _ source: DanmakuSourceDescriptor,
        authority proposedAuthority: DanmakuSelectionAuthority,
        playbackSessionID: UUID,
        runtimeGeneration: UInt64,
        basedOnRevision: UInt64
    ) -> Bool {
        guard playbackSessionID == self.playbackSessionID,
              runtimeGeneration == self.runtimeGeneration,
              source.runtime.runtimeGeneration == runtimeGeneration,
              basedOnRevision == selectionRevision,
              proposedAuthority >= authority else {
            return false
        }
        selectedSource = source
        authority = proposedAuthority
        selectionRevision &+= 1
        return true
    }

    @discardableResult
    public mutating func clearByUser() -> UInt64 {
        selectedSource = nil
        authority = .userSelection
        selectionRevision &+= 1
        return selectionRevision
    }
}
