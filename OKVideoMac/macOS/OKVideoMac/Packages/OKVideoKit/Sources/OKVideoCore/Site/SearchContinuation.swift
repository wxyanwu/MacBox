import Foundation

/// Evidence about a page is separate from the scheduler's time/page budget.
public struct SearchPageCursor: Equatable, Sendable {
    public var keyword: String
    public private(set) var nextPage: Int = 1
    public private(set) var seenIDs: Set<String> = []
    public private(set) var ended = false
    public private(set) var uncertain = false
    public var error: String?

    public init(keyword: String) { self.keyword = keyword }

    public mutating func fail(_ message: String, uncertain: Bool = false) {
        error = message
        self.uncertain = uncertain
    }

    /// Commit only validated progress. A repeated/contradictory page remains
    /// retryable at the same cursor; an explicit final page may contain repeats.
    @discardableResult
    public mutating func accept(_ page: VideoPage, requestedPage: Int) -> Bool {
        error = nil
        uncertain = false
        let end = page.pagination.continuation == .end ||
            (page.pagination.continuation == nil &&
             page.pagination.pageCount.map { requestedPage >= $0 } == true)
        let declaredMore = page.pagination.continuation == .more ||
            page.pagination.pageCount.map { requestedPage < $0 } == true
        let newIDs = Set(page.items.map(\.id)).subtracting(seenIDs)
        guard page.pagination.page == requestedPage,
              !(end && declaredMore),
              !newIDs.isEmpty || end || (page.items.isEmpty && !declaredMore) else {
            uncertain = true
            return false
        }
        seenIDs.formUnion(newIDs)
        nextPage = requestedPage + 1
        ended = end || (page.items.isEmpty && !declaredMore)
        return true
    }
}

public struct SearchPageProgress: Sendable {
    public let siteKey: String
    public let keyword: String
    public let requestedPage: Int
    public let page: VideoPage
}

public enum SearchPageAttempt: Sendable {
    case success(VideoPage, keyword: String)
    case failure(String, uncertain: Bool)
    case cancelled
}
