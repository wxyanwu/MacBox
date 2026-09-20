import AppKit
import Foundation
import OKVideoCore
import OKVideoPersistence
import SwiftUI

enum DanmakuDisplayArea: String, CaseIterable, Identifiable {
    case upperQuarter
    case upperHalf
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upperQuarter: return "顶部 1/4"
        case .upperHalf: return "上半屏"
        case .full: return "全屏"
        }
    }

    var fraction: CGFloat {
        switch self {
        case .upperQuarter: return 0.25
        case .upperHalf: return 0.5
        case .full: return 0.92
        }
    }
}

enum DanmakuDensity: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    var laneSpacing: CGFloat {
        switch self {
        case .low: return 13
        case .medium: return 8
        case .high: return 4
        }
    }

    var maximumActiveComments: Int {
        switch self {
        case .low: return 35
        case .medium: return 70
        case .high: return 120
        }
    }
}

@MainActor
final class DanmakuSessionCoordinator: ObservableObject {
    @Published private(set) var loadState: DanmakuLoadState = .disabled
    @Published private(set) var searchState: DanmakuSearchState = .idle
    @Published private(set) var timeline = DanmakuTimeline(comments: [])
    @Published private(set) var timelineRevision: UInt64 = 0
    @Published private(set) var candidates: [DanmakuSourceDescriptor] = []
    @Published private(set) var selectedSource: DanmakuSourceDescriptor?
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            if !isEnabled {
                loadTask?.cancel()
                replaceTimeline(DanmakuTimeline(comments: []))
                loadState = .disabled
            } else {
                resumeCurrentSessionIfNeeded()
            }
        }
    }
    @Published var fontScale: Double {
        didSet { defaults.set(fontScale, forKey: Keys.fontScale) }
    }
    @Published var opacity: Double {
        didSet { defaults.set(opacity, forKey: Keys.opacity) }
    }
    @Published var displayArea: DanmakuDisplayArea {
        didSet { defaults.set(displayArea.rawValue, forKey: Keys.displayArea) }
    }
    @Published var density: DanmakuDensity {
        didSet { defaults.set(density.rawValue, forKey: Keys.density) }
    }
    @Published var offset: TimeInterval = 0
    @Published var externalServiceURL: String {
        didSet { defaults.set(externalServiceURL, forKey: Keys.externalServiceURL) }
    }

    private enum Keys {
        static let enabled = "player.danmaku.enabled"
        static let fontScale = "player.danmaku.fontScale"
        static let opacity = "player.danmaku.opacity"
        static let displayArea = "player.danmaku.displayArea"
        static let density = "player.danmaku.density"
        static let externalServiceURL = "player.danmaku.externalServiceURL"
    }

    private let defaults: UserDefaults
    private var context: DanmakuPlaybackContext?
    private var playbackSessionID: UUID?
    private var database: SQLiteStore?
    private var selection: DanmakuSessionSelection?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.enabled) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Keys.enabled)
        }
        let storedFontScale = defaults.double(forKey: Keys.fontScale)
        fontScale = storedFontScale == 0 ? 1 : min(max(storedFontScale, 0.6), 2)
        let storedOpacity = defaults.double(forKey: Keys.opacity)
        opacity = storedOpacity == 0 ? 0.86 : min(max(storedOpacity, 0.2), 1)
        displayArea = DanmakuDisplayArea(
            rawValue: defaults.string(forKey: Keys.displayArea) ?? ""
        ) ?? .upperHalf
        density = DanmakuDensity(
            rawValue: defaults.string(forKey: Keys.density) ?? ""
        ) ?? .medium
        externalServiceURL = defaults.string(forKey: Keys.externalServiceURL) ?? ""
    }

    func begin(
        context: DanmakuPlaybackContext?,
        playbackSessionID: UUID,
        database: SQLiteStore
    ) {
        endSession()
        self.context = context
        self.playbackSessionID = playbackSessionID
        self.database = database
        guard isEnabled, let context else {
            loadState = isEnabled ? .unavailable : .disabled
            return
        }
        selection = DanmakuSessionSelection(
            playbackSessionID: playbackSessionID,
            runtimeGeneration: context.runtimeGeneration
        )
        loadState = .resolvingSource
        let editionIdentity = context.editionIdentity
        loadTask = Task { [weak self] in
            let binding = try? await database.danmakuBinding(
                for: editionIdentity
            )
            guard !Task.isCancelled, let self,
                  self.owns(playbackSessionID, generation: context.runtimeGeneration) else {
                return
            }
            self.offset = binding?.offset ?? 0
            if let binding {
                if let source = context.providedSources.first(where: {
                    $0.stable == binding.locator
                }) ?? self.runtimeSource(for: binding.locator, in: context) {
                    self.choose(
                        source,
                        authority: .savedBinding,
                        persist: false
                    )
                    return
                }
                if binding.locator.kind == .providerURLIdentity,
                   let source = await self.restoreSearchSource(
                       for: binding.locator,
                       in: context
                   ),
                   self.owns(
                       playbackSessionID,
                       generation: context.runtimeGeneration
                   ) {
                    self.choose(
                        source,
                        authority: .savedBinding,
                        persist: false
                    )
                    return
                }
                self.loadState = .staleBinding(binding.locator)
                return
            }
            if let source = DanmakuProvidedSourcePolicy.automaticSource(
                from: context.providedSources
            ) {
                self.choose(
                    source,
                    authority: .providedSource,
                    persist: false
                )
            } else if context.providedSources.count > 1 {
                self.candidates = context.providedSources
                self.loadState = .awaitingSelection(context.providedSources)
            } else {
                self.loadState = .unavailable
            }
        }
    }

    func endSession() {
        loadTask?.cancel()
        searchTask?.cancel()
        loadTask = nil
        searchTask = nil
        context = nil
        playbackSessionID = nil
        database = nil
        selection = nil
        selectedSource = nil
        candidates = []
        replaceTimeline(DanmakuTimeline(comments: []))
        searchState = .idle
        loadState = isEnabled ? .unavailable : .disabled
        offset = 0
    }

    func select(_ source: DanmakuSourceDescriptor) {
        choose(source, authority: .userSelection, persist: true)
    }

    func importXML(from fileURL: URL) {
        guard let context, fileURL.isFileURL else { return }
        let source = DanmakuSourceDescriptor(
            stable: StableDanmakuLocator(
                kind: .localBookmark,
                provider: "local",
                resourceID: fileURL.path,
                displayName: fileURL.lastPathComponent
            ),
            runtime: RuntimeDanmakuLocator(
                url: fileURL,
                runtimeGeneration: context.runtimeGeneration
            )
        )
        choose(source, authority: .userSelection, persist: true)
    }

    func updateOffset(_ value: TimeInterval) {
        offset = min(max(value.isFinite ? value : 0, -120), 120)
        persistCurrentBinding()
    }

    func search(_ rawKeyword: String) {
        guard let context, let playbackSessionID else { return }
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let endpoints = searchEndpoints(in: context)
        guard !endpoints.isEmpty else {
            searchState = .failed(message: "请先填写弹幕服务地址")
            return
        }
        searchTask?.cancel()
        searchState = .searching
        let generation = context.runtimeGeneration
        searchTask = Task { [weak self] in
            do {
                let sources = try await Self.searchSources(
                    keyword: keyword,
                    endpoints: endpoints,
                    runtimeGeneration: generation
                )
                try Task.checkCancellation()
                guard let self,
                      self.owns(playbackSessionID, generation: generation) else {
                    return
                }
                self.candidates = sources
                self.searchState = sources.isEmpty ? .empty : .results(sources)
                if !sources.isEmpty {
                    self.loadState = .awaitingSelection(sources)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.owns(playbackSessionID, generation: generation) else {
                    return
                }
                self.searchState = .failed(message: error.localizedDescription)
            }
        }
    }

    var statusText: String {
        switch loadState {
        case .disabled: return "弹幕已关闭"
        case .resolvingSource: return "正在查找本集弹幕…"
        case .awaitingSelection: return "请选择弹幕来源"
        case .loading(let source): return "正在加载 \(source.stable.displayName)…"
        case .ready(_, let timeline): return "已载入 \(timeline.comments.count) 条弹幕"
        case .empty: return "这个来源没有弹幕"
        case .staleBinding: return "以前选择的弹幕来源已失效"
        case .failed(_, let message): return message
        case .unavailable: return "当前视频没有提供弹幕"
        }
    }

    var searchStatusText: String? {
        switch searchState {
        case .idle, .searching, .results:
            return nil
        case .empty:
            return "没有找到匹配的弹幕"
        case .failed(let message):
            return "搜索失败：\(message)"
        }
    }

    var suggestedSearchQuery: String {
        guard let context else { return "" }
        let contentTitle = context.contentIdentity.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let episode = context.editionIdentity.episode
        let suffix: String
        if let season = episode.seasonNumber,
           let number = episode.episodeNumber {
            suffix = String(format: "S%02dE%02d", season, number)
        } else if let number = episode.episodeNumber {
            suffix = "第\(number)集"
        } else {
            suffix = episode.title
        }
        return [contentTitle, suffix]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func resumeCurrentSessionIfNeeded() {
        guard let context, let playbackSessionID, let database else {
            loadState = .unavailable
            return
        }
        begin(
            context: context,
            playbackSessionID: playbackSessionID,
            database: database
        )
    }

    private func choose(
        _ source: DanmakuSourceDescriptor,
        authority: DanmakuSelectionAuthority,
        persist: Bool
    ) {
        guard isEnabled,
              let context,
              let playbackSessionID,
              var currentSelection = selection else { return }
        let revision = currentSelection.selectionRevision
        guard currentSelection.select(
            source,
            authority: authority,
            playbackSessionID: playbackSessionID,
            runtimeGeneration: context.runtimeGeneration,
            basedOnRevision: revision
        ) else { return }
        selection = currentSelection
        selectedSource = source
        if persist { persistCurrentBinding() }
        load(source, playbackSessionID: playbackSessionID, revision: currentSelection.selectionRevision)
    }

    private func load(
        _ source: DanmakuSourceDescriptor,
        playbackSessionID: UUID,
        revision: UInt64
    ) {
        loadTask?.cancel()
        replaceTimeline(DanmakuTimeline(comments: []))
        loadState = .loading(source)
        let generation = source.runtime.runtimeGeneration
        loadTask = Task { [weak self] in
            do {
                let data = try await Self.loadData(from: source.runtime)
                try Task.checkCancellation()
                let parsed = try await Task.detached(priority: .userInitiated) {
                    try BilibiliDanmakuXMLParser().parse(data)
                }.value
                try Task.checkCancellation()
                guard let self,
                      self.owns(playbackSessionID, generation: generation),
                      self.selection?.selectionRevision == revision,
                      self.selection?.selectedSource?.id == source.id else {
                    return
                }
                self.replaceTimeline(parsed)
                self.loadState = parsed.comments.isEmpty
                    ? .empty(source)
                    : .ready(source, parsed)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.owns(playbackSessionID, generation: generation),
                      self.selection?.selectionRevision == revision else {
                    return
                }
                self.loadState = .failed(
                    source,
                    message: "弹幕加载失败：\(error.localizedDescription)"
                )
            }
        }
    }

    private func persistCurrentBinding() {
        guard let context, let selectedSource, let database else { return }
        let binding = DanmakuBinding(
            editionIdentity: context.editionIdentity,
            locator: selectedSource.stable,
            offset: offset
        )
        Task { try? await database.saveDanmakuBinding(binding) }
    }

    private func replaceTimeline(_ value: DanmakuTimeline) {
        timeline = value
        timelineRevision &+= 1
    }

    private func owns(_ sessionID: UUID, generation: UInt64) -> Bool {
        playbackSessionID == sessionID
            && context?.runtimeGeneration == generation
    }

    private func runtimeSource(
        for locator: StableDanmakuLocator,
        in context: DanmakuPlaybackContext
    ) -> DanmakuSourceDescriptor? {
        if locator.kind == .localBookmark {
            let url = URL(fileURLWithPath: locator.resourceID)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return DanmakuSourceDescriptor(
                stable: locator,
                runtime: RuntimeDanmakuLocator(
                    url: url,
                    runtimeGeneration: context.runtimeGeneration
                )
            )
        }
        guard locator.kind == .providerEpisode else { return nil }
        for endpoint in searchEndpoints(in: context) {
            guard endpoint.providerID == locator.provider,
                  let url = endpoint.commentURL(resourceID: locator.resourceID) else {
                continue
            }
            return DanmakuSourceDescriptor(
                stable: locator,
                runtime: RuntimeDanmakuLocator(
                    url: url,
                    headers: endpoint.headers,
                    runtimeGeneration: context.runtimeGeneration
                )
            )
        }
        return nil
    }

    private func restoreSearchSource(
        for locator: StableDanmakuLocator,
        in context: DanmakuPlaybackContext
    ) async -> DanmakuSourceDescriptor? {
        let endpoints = searchEndpoints(in: context)
        let keyword = suggestedSearchQuery
        guard !endpoints.isEmpty, !keyword.isEmpty else { return nil }
        let sources = try? await Self.searchSources(
            keyword: keyword,
            endpoints: endpoints,
            runtimeGeneration: context.runtimeGeneration
        )
        return sources?.first { $0.stable == locator }
    }

    private struct SearchEndpoint: Equatable, Sendable {
        let url: URL
        let headers: HTTPHeaders

        var providerID: String {
            "service:\(url.scheme ?? "")://\(url.host ?? "")\(basePath)"
        }

        var basePath: String {
            let path = url.path
            if let range = path.range(of: "/api/v2") {
                return String(path[..<range.lowerBound])
            }
            return path == "/" ? "" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        func searchURL(keyword: String) -> URL? {
            let template = url.absoluteString
            if template.contains("{") {
                let escaped = keyword.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed
                ) ?? keyword
                return URL(string: template
                    .replacingOccurrences(of: "{name}", with: escaped)
                    .replacingOccurrences(of: "{title}", with: escaped)
                    .replacingOccurrences(of: "{keyword}", with: escaped))
            }
            var components: URLComponents
            if url.path.contains("/api/v2/search/episodes") {
                components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
            } else {
                components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
                components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                components.path = "/" + [components.path, "api/v2/search/episodes"]
                    .filter { !$0.isEmpty && $0 != "/" }
                    .joined(separator: "/")
            }
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == "anime" }
            queryItems.append(URLQueryItem(name: "anime", value: keyword))
            components.queryItems = queryItems
            return components.url
        }

        func commentURL(resourceID: String) -> URL? {
            let encoded = resourceID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? resourceID
            var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
            let existingPath = components?.path.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            ) ?? ""
            components?.path = "/" + [
                existingPath,
                "api/v2/comment/\(encoded)"
            ].filter { !$0.isEmpty }.joined(separator: "/")
            components?.queryItems = [URLQueryItem(name: "format", value: "xml")]
            return components?.url
        }

        private var apiBaseURL: URL {
            guard !basePath.isEmpty else {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.path = ""
                components?.query = nil
                components?.fragment = nil
                return components?.url ?? url
            }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.path = basePath.hasPrefix("/") ? basePath : "/\(basePath)"
            components?.query = nil
            components?.fragment = nil
            return components?.url ?? url
        }
    }

    private func searchEndpoints(
        in context: DanmakuPlaybackContext
    ) -> [SearchEndpoint] {
        var endpoints: [SearchEndpoint] = []
        for capability in context.searchCapabilities {
            switch capability {
            case .catPawAPI(let baseURL, let headers),
                 .providerWebPage(let baseURL, let headers):
                endpoints.append(SearchEndpoint(url: baseURL, headers: headers))
            case .configuredEndpoint(let value):
                endpoints.append(contentsOf: Self.urls(in: value).map {
                    SearchEndpoint(url: $0, headers: [:])
                })
            }
        }
        endpoints.append(contentsOf: Self.urls(in: externalServiceURL).map {
            SearchEndpoint(url: $0, headers: [:])
        })
        var seen = Set<String>()
        return endpoints.filter { seen.insert($0.url.absoluteString).inserted }
    }

    nonisolated private static func urls(in rawValue: String) -> [URL] {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        if let url = URL(string: value), url.scheme != nil { return [url] }
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        var values: [URL] = []
        func collect(_ object: Any) {
            if let string = object as? String,
               let url = URL(string: string), url.scheme != nil {
                values.append(url)
            } else if let array = object as? [Any] {
                array.forEach(collect)
            } else if let object = object as? [String: Any] {
                for key in ["url", "api", "endpoint", "search", "urls"] {
                    if let child = object[key] { collect(child) }
                }
            }
        }
        collect(json)
        return values
    }

    nonisolated private static func loadData(
        from locator: RuntimeDanmakuLocator
    ) async throws -> Data {
        if locator.url.isFileURL {
            let data = try Data(contentsOf: locator.url, options: [.mappedIfSafe])
            guard data.count <= 32 * 1_024 * 1_024 else {
                throw DanmakuXMLParserError.documentTooLarge
            }
            return data
        }
        var request = URLRequest(url: locator.url)
        request.timeoutInterval = 15
        for (key, value) in locator.headers.dictionary {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw AppError.network("弹幕服务没有返回有效数据")
        }
        guard data.count <= 32 * 1_024 * 1_024 else {
            throw DanmakuXMLParserError.documentTooLarge
        }
        return data
    }

    nonisolated private static func searchSources(
        keyword: String,
        endpoints: [SearchEndpoint],
        runtimeGeneration: UInt64
    ) async throws -> [DanmakuSourceDescriptor] {
        var collected: [DanmakuSourceDescriptor] = []
        try await withThrowingTaskGroup(of: [DanmakuSourceDescriptor].self) { group in
            for endpoint in endpoints {
                group.addTask {
                    do {
                        guard let url = endpoint.searchURL(keyword: keyword) else {
                            return []
                        }
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 12
                        for (key, value) in endpoint.headers.dictionary {
                            request.setValue(value, forHTTPHeaderField: key)
                        }
                        let (data, response) = try await URLSession.shared.data(
                            for: request
                        )
                        guard let http = response as? HTTPURLResponse,
                              (200...299).contains(http.statusCode),
                              data.count <= 4 * 1_024 * 1_024 else { return [] }
                        return decodeSearchResults(
                            data,
                            endpoint: endpoint,
                            runtimeGeneration: runtimeGeneration
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Endpoints are independent. A dead optional service
                        // must not erase useful candidates from another one.
                        return []
                    }
                }
            }
            for try await values in group { collected.append(contentsOf: values) }
        }
        var seen = Set<String>()
        return collected.filter { seen.insert($0.id).inserted }
    }

    nonisolated private static func decodeSearchResults(
        _ data: Data,
        endpoint: SearchEndpoint,
        runtimeGeneration: UInt64
    ) -> [DanmakuSourceDescriptor] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        var output: [DanmakuSourceDescriptor] = []
        func string(_ object: [String: Any], _ keys: [String]) -> String? {
            for key in keys {
                if let value = object[key] as? String,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
                if let value = object[key] as? NSNumber { return value.stringValue }
            }
            return nil
        }
        func walk(_ value: Any, inheritedTitle: String?) {
            if let array = value as? [Any] {
                array.forEach { walk($0, inheritedTitle: inheritedTitle) }
                return
            }
            guard let object = value as? [String: Any] else { return }
            let title = string(object, ["episodeTitle", "title", "name", "animeTitle"])
                ?? inheritedTitle
            if let rawURL = string(object, ["url", "xml", "href"]),
               let url = URL(string: rawURL), url.scheme != nil {
                let name = title ?? "弹幕来源"
                output.append(DanmakuSourceDescriptor(
                    stable: StableDanmakuLocator(
                        kind: .providerURLIdentity,
                        provider: endpoint.providerID,
                        resourceID: PlaybackReferenceIdentity.episode(name: name, reference: rawURL),
                        displayName: name
                    ),
                    runtime: RuntimeDanmakuLocator(
                        url: url,
                        headers: endpoint.headers,
                        runtimeGeneration: runtimeGeneration
                    )
                ))
            } else if let resourceID = string(
                object,
                ["episodeId", "episode_id", "commentId", "id"]
            ), let url = endpoint.commentURL(resourceID: resourceID) {
                let name = title ?? "弹幕 \(resourceID)"
                output.append(DanmakuSourceDescriptor(
                    stable: StableDanmakuLocator(
                        kind: .providerEpisode,
                        provider: endpoint.providerID,
                        resourceID: resourceID,
                        displayName: name
                    ),
                    runtime: RuntimeDanmakuLocator(
                        url: url,
                        headers: endpoint.headers,
                        runtimeGeneration: runtimeGeneration
                    )
                ))
            }
            for (key, child) in object where [
                "data", "result", "results", "list", "items", "animes", "episodes"
            ].contains(key) {
                walk(child, inheritedTitle: title)
            }
        }
        walk(root, inheritedTitle: nil)
        return output
    }
}

struct DanmakuOverlayRepresentable: NSViewRepresentable {
    let timeline: DanmakuTimeline
    let timelineRevision: UInt64
    let snapshot: PlayerSnapshot
    let offset: TimeInterval
    let fontScale: Double
    let opacity: Double
    let displayArea: DanmakuDisplayArea
    let density: DanmakuDensity

    func makeNSView(context: Context) -> DanmakuOverlayNSView {
        DanmakuOverlayNSView()
    }

    func updateNSView(_ view: DanmakuOverlayNSView, context: Context) {
        view.update(
            timeline: timeline,
            timelineRevision: timelineRevision,
            snapshot: snapshot,
            offset: offset,
            fontScale: fontScale,
            opacity: opacity,
            displayArea: displayArea,
            density: density
        )
    }
}

final class DanmakuOverlayNSView: NSView {
    private struct ActiveComment {
        let comment: DanmakuComment
        let lane: Int
        let startTime: TimeInterval
        let width: CGFloat
        let lifetime: TimeInterval
        let mode: DanmakuMode
    }

    private var timeline = DanmakuTimeline(comments: [])
    private var timelineRevision: UInt64?
    private var clock = DanmakuClock()
    private var generation: UInt64 = 1
    private var lastPresentedMediaTime: TimeInterval?
    private var active: [ActiveComment] = []
    private var scrollingScheduler = DanmakuLaneScheduler(laneCount: 0)
    private var timer: Timer?
    private var offset: TimeInterval = 0
    private var fontScale: Double = 1
    private var commentOpacity: Double = 0.86
    private var displayArea: DanmakuDisplayArea = .upperHalf
    private var density: DanmakuDensity = .medium
    private var lastBoundsSize: CGSize = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) {
            [weak self] _ in self?.tick()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit { timer?.invalidate() }

    func update(
        timeline: DanmakuTimeline,
        timelineRevision: UInt64,
        snapshot: PlayerSnapshot,
        offset: TimeInterval,
        fontScale: Double,
        opacity: Double,
        displayArea: DanmakuDisplayArea,
        density: DanmakuDensity
    ) {
        if timelineRevision != self.timelineRevision {
            self.timeline = timeline
            self.timelineRevision = timelineRevision
            resetPresentation(at: snapshot.position)
        }
        if self.offset != offset
            || self.fontScale != fontScale
            || self.displayArea != displayArea {
            self.offset = offset
            self.fontScale = fontScale
            self.displayArea = displayArea
            resetPresentation(at: snapshot.position)
        }
        commentOpacity = opacity
        if self.density != density {
            self.density = density
            resetPresentation(at: snapshot.position)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let expected = clock.currentTime(at: now)
        if snapshot.isSeeking || abs(snapshot.position - expected) > 0.8 {
            generation &+= 1
            resetPresentation(at: snapshot.seekTarget ?? snapshot.position)
        }
        let isPlaying: Bool
        if case .playing = snapshot.status { isPlaying = true } else { isPlaying = false }
        clock.anchor(
            mediaTime: snapshot.position,
            monotonicTime: now,
            rate: snapshot.speed,
            isPlaying: isPlaying,
            isBuffering: snapshot.isPausedForCache || snapshot.status == .buffering,
            isSeeking: snapshot.isSeeking,
            generation: generation
        )
    }

    override func layout() {
        super.layout()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            resetPresentation(at: clock.currentTime(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func tick() {
        guard window != nil, !timeline.comments.isEmpty, bounds.width > 0 else { return }
        let mediaTime = clock.currentTime(at: ProcessInfo.processInfo.systemUptime)
        presentComments(through: mediaTime)
        active.removeAll { item in
            mediaTime - item.startTime > item.lifetime
        }
        needsDisplay = true
    }

    private func presentComments(through mediaTime: TimeInterval) {
        let previous = lastPresentedMediaTime ?? max(0, mediaTime - 0.15)
        guard mediaTime >= previous, mediaTime - previous < 1.5 else {
            resetPresentation(at: mediaTime)
            return
        }
        // Timeline windows are closed on both ends; advance the lower edge by
        // a tiny amount so a comment exactly on the previous frame boundary
        // is not emitted twice.
        let sourceStart = previous - offset + 0.000_001
        let sourceEnd = mediaTime - offset
        for comment in timeline.comments(from: sourceStart, through: sourceEnd) {
            guard active.count < density.maximumActiveComments else { break }
            add(comment, at: comment.time + offset)
        }
        lastPresentedMediaTime = mediaTime
    }

    private func add(_ comment: DanmakuComment, at time: TimeInterval) {
        let font = NSFont.systemFont(
            ofSize: CGFloat(min(max(comment.fontSize * fontScale, 13), 58)),
            weight: .semibold
        )
        let width = ceil((comment.text as NSString).size(withAttributes: [.font: font]).width) + 8
        let laneHeight = font.pointSize + density.laneSpacing
        let displayHeight = max(laneHeight, bounds.height * displayArea.fraction)
        let laneCount = max(1, Int(displayHeight / laneHeight))
        if comment.mode == .scrolling {
            if scrollingScheduler.reserve(
                at: time,
                textWidth: Double(width),
                viewportWidth: Double(bounds.width),
                lifetime: 8
            ).map({ reservation in
                active.append(ActiveComment(
                    comment: comment,
                    lane: reservation.lane,
                    startTime: time,
                    width: width,
                    lifetime: 8,
                    mode: .scrolling
                ))
            }) == nil {
                return
            }
        } else {
            let occupied = Set(active.filter {
                $0.mode == comment.mode && time - $0.startTime < $0.lifetime
            }.map(\.lane))
            guard let lane = (0..<laneCount).first(where: { !occupied.contains($0) }) else {
                return
            }
            active.append(ActiveComment(
                comment: comment,
                lane: lane,
                startTime: time,
                width: width,
                lifetime: 4,
                mode: comment.mode
            ))
        }
    }

    private func resetPresentation(at mediaTime: TimeInterval) {
        active.removeAll(keepingCapacity: true)
        let fontHeight = CGFloat(28 * fontScale) + density.laneSpacing
        let laneCount = max(1, Int(max(1, bounds.height * displayArea.fraction) / max(1, fontHeight)))
        scrollingScheduler.reset(laneCount: laneCount)
        lastPresentedMediaTime = max(0, mediaTime - 0.15)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let mediaTime = clock.currentTime(at: ProcessInfo.processInfo.systemUptime)
        for item in active {
            let fontSize = CGFloat(min(max(item.comment.fontSize * fontScale, 13), 58))
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let color = NSColor(
                calibratedRed: CGFloat((item.comment.color >> 16) & 0xFF) / 255,
                green: CGFloat((item.comment.color >> 8) & 0xFF) / 255,
                blue: CGFloat(item.comment.color & 0xFF) / 255,
                alpha: CGFloat(commentOpacity)
            )
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .strokeColor: NSColor.black.withAlphaComponent(0.9),
                .strokeWidth: -2.5
            ]
            let laneHeight = font.pointSize + density.laneSpacing
            let y: CGFloat
            switch item.mode {
            case .bottom:
                y = max(0, bounds.height * displayArea.fraction - CGFloat(item.lane + 1) * laneHeight)
            case .scrolling, .top:
                y = CGFloat(item.lane) * laneHeight
            }
            let x: CGFloat
            if item.mode == .scrolling {
                let progress = min(max((mediaTime - item.startTime) / item.lifetime, 0), 1)
                x = bounds.width - CGFloat(progress) * (bounds.width + item.width)
            } else {
                x = max(0, (bounds.width - item.width) / 2)
            }
            (item.comment.text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        }
    }
}

struct PlayerDanmakuLayer: View {
    @ObservedObject var coordinator: DanmakuSessionCoordinator
    @ObservedObject var snapshotState: PlayerSnapshotState

    var body: some View {
        if coordinator.isEnabled, !coordinator.timeline.comments.isEmpty {
            DanmakuOverlayRepresentable(
                timeline: coordinator.timeline,
                timelineRevision: coordinator.timelineRevision,
                snapshot: snapshotState.snapshot,
                offset: coordinator.offset,
                fontScale: coordinator.fontScale,
                opacity: coordinator.opacity,
                displayArea: coordinator.displayArea,
                density: coordinator.density
            )
        }
    }
}

struct PlayerDanmakuPanel: View {
    @ObservedObject var coordinator: DanmakuSessionCoordinator
    let importXML: () -> Void
    @State private var keyword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("弹幕")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("", isOn: $coordinator.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Text(coordinator.statusText)
                .font(.caption)
                .foregroundColor(.white.opacity(0.58))

            if !coordinator.candidates.isEmpty {
                VStack(spacing: 5) {
                    ForEach(coordinator.candidates) { source in
                        Button {
                            coordinator.select(source)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: coordinator.selectedSource?.id == source.id
                                      ? "checkmark.circle.fill" : "circle")
                                Text(source.stable.displayName)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.84))
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .background(
                                coordinator.selectedSource?.id == source.id
                                    ? Color.accentColor.opacity(0.30)
                                    : Color.white.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 7) {
                TextField("片名 / 集数", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { coordinator.search(keyword) }
                Button("搜索") { coordinator.search(keyword) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField("弹幕服务地址（可选）", text: $coordinator.externalServiceURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            HStack {
                Button("导入 XML…", action: importXML)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                if case .searching = coordinator.searchState {
                    ProgressView().controlSize(.small)
                }
            }

            if let searchStatusText = coordinator.searchStatusText {
                Text(searchStatusText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.58))
            }

            Divider().overlay(Color.white.opacity(0.08))

            settingSlider(
                title: "字号",
                value: $coordinator.fontScale,
                range: 0.7...1.6,
                valueText: "\(Int(coordinator.fontScale * 100))%"
            )
            settingSlider(
                title: "透明度",
                value: $coordinator.opacity,
                range: 0.25...1,
                valueText: "\(Int(coordinator.opacity * 100))%"
            )

            HStack {
                Text("显示区域")
                Spacer()
                Picker("", selection: $coordinator.displayArea) {
                    ForEach(DanmakuDisplayArea.allCases) { area in
                        Text(area.title).tag(area)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            HStack {
                Text("密度")
                Spacer()
                Picker("", selection: $coordinator.density) {
                    ForEach(DanmakuDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            HStack(spacing: 7) {
                Text("时间校准")
                Spacer()
                Button("−0.5s") { coordinator.updateOffset(coordinator.offset - 0.5) }
                Text(String(format: "%+.1fs", coordinator.offset))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: 48)
                Button("+0.5s") { coordinator.updateOffset(coordinator.offset + 0.5) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 13))
        }
        .foregroundColor(.white.opacity(0.9))
        .onAppear {
            if keyword.isEmpty { keyword = coordinator.suggestedSearchQuery }
        }
    }

    private func settingSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 48, alignment: .leading)
            Slider(value: value, in: range)
            Text(valueText)
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.58))
                .frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 13))
    }
}
