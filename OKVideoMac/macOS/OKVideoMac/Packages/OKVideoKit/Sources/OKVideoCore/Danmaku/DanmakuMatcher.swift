import Foundation

public struct DanmakuMatchRequest: Equatable, Sendable {
    public var title: String
    public var year: String?
    public var form: PlaybackContentForm
    public var season: Int?
    public var episode: Int?
    public var contextualEpisode: Int?
    public var isMain: Bool

    public init(title: String, year: String? = nil, category: String? = nil,
                episode item: PlayEpisode, siblings: [PlayEpisode] = []) {
        self.title = title; self.year = year.flatMap(DanmakuServiceEndpoint.year)
        let parsed = PlaybackResourceAnalyzer.analyze(item, categoryName: category)
        form = parsed.form; season = parsed.season ?? DanmakuServiceEndpoint.season(title)
        isMain = parsed.role == .main && parsed.endEpisode == nil && parsed.evidence != .conflict
        episode = parsed.hasReliableEpisode ? parsed.episode : nil
        let numeric = PlaybackResourceAnalyzer.analyze(item, categoryName: "电视剧")
        if episode == nil, form != .movie, form != .programme, isMain, numeric.evidence == .contextual {
            let family = siblings.map { PlaybackResourceAnalyzer.analyze($0, categoryName: "电视剧") }
                .filter { $0.role == .main }
            let numbers = family.compactMap(\.episode)
            if numbers.count >= 3, Set(numbers).count == numbers.count,
               family.allSatisfy({ $0.form == .series && $0.endEpisode == nil && $0.evidence != .conflict && $0.episode != nil }) {
                contextualEpisode = numeric.episode
                if form == .series { episode = numeric.episode }
            }
        }
    }
    public var searchTitle: String { DanmakuServiceEndpoint.normalizedTitle(title) }
}

public enum DanmakuMatcher {
    public static func candidates(_ sources: [DanmakuSourceDescriptor], for request: DanmakuMatchRequest,
                                  preferredWork: String? = nil) -> [DanmakuSourceDescriptor] {
        guard request.isMain else { return [] }
        return sources.filter { source in
            guard let m = source.match, m.role == .main else { return false }
            let confirmed = preferredWork != nil && m.workID == preferredWork
            guard confirmed || DanmakuServiceEndpoint.normalizedTitle(m.title) == request.searchTitle else { return false }
            if let year = request.year, let other = m.year, year != other { return false }
            if let season = request.season, let other = m.season, season != other { return false }
            if request.form != .unknown, m.form != .unknown, request.form != m.form { return false }
            if request.form == .movie { return m.episode == nil }
            guard let episode = request.episode ?? (m.form == .series ? request.contextualEpisode : nil), m.episode == episode else { return false }
            // Missing season is usable only for a single-season work, never an ambiguous multi-season search.
            return true
        }
    }
    public static func automaticSource(_ sources: [DanmakuSourceDescriptor], for request: DanmakuMatchRequest,
                                       preferredWork: String? = nil) -> DanmakuSourceDescriptor? {
        var eligible = candidates(sources, for: request, preferredWork: preferredWork)
        if let preferredWork {
            eligible = eligible.filter { $0.match?.workID == preferredWork }
        }
        guard !eligible.isEmpty else { return nil }
        // Distinct editions/years/seasons require a choice. A confirmed work can supply an alias.
        let works = Set(eligible.compactMap { $0.match?.workID })
        guard works.count == 1 else { return nil }
        if request.season == nil {
            let seasons = Set(sources.filter { $0.match.map { DanmakuServiceEndpoint.normalizedTitle($0.title) == request.searchTitle } ?? false }
                .compactMap { $0.match?.season })
            guard seasons.count <= 1 else { return nil }
        }
        return eligible.sorted { $0.id < $1.id }.first
    }
}
