import Foundation
import OKVideoCore

/// No scroll-position publication: recording an anchor must not invalidate the
/// SwiftUI graph during native scrolling. Keys belong to one search session.
@MainActor final class SearchBrowseMemory {
    var anchors: [String: PosterBrowseAnchor] = [:]
    private var presentations: [String: SearchStablePresentation] = [:]
    func presentation(for key: String) -> SearchStablePresentation {
        if let existing = presentations[key] { return existing }
        let result = SearchStablePresentation()
        presentations[key] = result
        return result
    }
    func acceptPendingOrders() { presentations.values.forEach { $0.acceptOrder() } }
    private var sourceOrder: [String] = []
    func orderedSources(_ sources: [SearchSiteOption]) -> [SearchSiteOption] {
        let byKey = Dictionary(uniqueKeysWithValues: sources.map { ($0.key, $0) })
        for item in sources where !sourceOrder.contains(item.key) { sourceOrder.append(item.key) }
        return sourceOrder.compactMap { byKey[$0] }
    }
    func reset() { sourceOrder.removeAll(); anchors = anchors.filter { $0.key.hasPrefix("folder:") }; presentations.removeAll() }
}

struct SearchPagingState: Equatable {
    var cursors: [String: SearchPageCursor] = [:]
    var order: [String] = []
    var restricted: Set<String> = []
    var loading = false
    var stopped = false
    var manualContinuation = false
    var lastServed: String?
    var revision = 0

    func keys(selected: String?) -> [String] {
        if let selected { return order.contains(selected) ? [selected] : [] }
        return order
    }

    func eligible(selected: String?, retry: Bool) -> [String] {
        let keys = keys(selected: selected)
        let pivot = lastServed.flatMap { keys.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let rotated = Array(keys.dropFirst(pivot)) + Array(keys.prefix(pivot))
        return rotated.filter { key in
            guard let cursor = cursors[key], !cursor.ended,
                  !restricted.contains(key) || cursor.nextPage == 1 else { return false }
            return retry || (cursor.error == nil && !cursor.uncertain)
        }
    }
}

/// Keeps the reading order and representative poster stable while new providers
/// arrive. This object never publishes native scroll events into SwiftUI.
final class SearchStablePresentation {
    var atTop = true
    private(set) var hasPendingOrder = false
    private(set) var displayed: [SearchResultCluster] = []
    private var lastInput: [SearchResultCluster]?
    private var lastAtTop = true
    private var latest: [SearchResultCluster] = []

    func acceptOrder() { displayed = latest; hasPendingOrder = false }

    func update(_ incoming: [SearchResultCluster]) -> [SearchResultCluster] {
        if lastInput == incoming && lastAtTop == atTop { return displayed }
        lastInput = incoming
        lastAtTop = atTop
        let previous = Dictionary(uniqueKeysWithValues: displayed.map { ($0.id, $0) })
        latest = incoming.map { cluster in
            var cluster = cluster
            if let primary = previous[cluster.id]?.primary,
               let index = cluster.sources.firstIndex(where: { $0.id == primary.id }) {
                cluster.sources.remove(at: index)
                cluster.sources.insert(primary, at: 0)
            }
            return cluster
        }
        if atTop || displayed.isEmpty { displayed = latest; hasPendingOrder = false }
        else {
            let byID = Dictionary(uniqueKeysWithValues: latest.map { ($0.id, $0) })
            let retained = displayed.compactMap { byID[$0.id] }
            let retainedIDs = Set(retained.map(\.id))
            displayed = retained + latest.filter { !retainedIDs.contains($0.id) }
            hasPendingOrder = displayed.map(\.id) != latest.map(\.id)
        }
        return displayed
    }
}

struct SearchPresentationInput: Equatable, Sendable {
    let key: String
    let items: [VideoSummary]
    let keyword: String
    let mergesDuplicates: Bool
    let sortOrder: SearchResultSortOrder
}

actor SearchPresentationWorker {
    func clusters(_ input: SearchPresentationInput) -> [SearchResultCluster] {
        SearchResultPresentation.clusters(from: input.items, keyword: input.keyword,
            mergesDuplicates: input.mergesDuplicates, sortOrder: input.sortOrder)
    }
}

/// A refreshing provider commits atomically on success, including a valid empty
/// result. A failed or unfinished provider keeps every previously loaded page.
enum SearchRefreshSnapshot {
    static func merge(retained: [VideoSummary], incoming: [VideoSummary], successfulKeys: Set<String>) -> [VideoSummary] {
        retained.filter { !successfulKeys.contains($0.siteKey) }
            + incoming.filter { successfulKeys.contains($0.siteKey) }
    }
}
