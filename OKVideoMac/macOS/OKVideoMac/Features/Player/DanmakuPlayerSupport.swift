import AppKit
import CoreVideo
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
    @Published private(set) var selectionDescription = ""
    @Published private(set) var recoveryDescription: String?
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            if !isEnabled {
                resolveTask?.cancel(); searchTask?.cancel(); loadTask?.cancel()
                epoch = UUID(); searchState = .idle; replaceTimeline(.init(comments: [])); loadState = .disabled
            } else { resumeCurrentSessionIfNeeded() }
        }
    }
    @Published var autoMatchEnabled: Bool {
        didSet { defaults.set(autoMatchEnabled, forKey: Keys.autoMatch); resumeCurrentSessionIfNeeded() }
    }
    @Published var fontScale: Double { didSet { defaults.set(fontScale, forKey: Keys.fontScale) } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: Keys.opacity) } }
    @Published var displayArea: DanmakuDisplayArea { didSet { defaults.set(displayArea.rawValue, forKey: Keys.displayArea) } }
    @Published var density: DanmakuDensity { didSet { defaults.set(density.rawValue, forKey: Keys.density) } }
    @Published var offset: TimeInterval = 0
    @Published var externalServiceURL: String { didSet { defaults.set(externalServiceURL, forKey: Keys.externalServiceURL) } }
    private enum Keys {
        static let enabled = "player.danmaku.enabled"
        static let autoMatch = "player.danmaku.autoMatch"
        static let fontScale = "player.danmaku.fontScale"
        static let opacity = "player.danmaku.opacity"
        static let displayArea = "player.danmaku.displayArea"
        static let density = "player.danmaku.density"
        static let externalServiceURL = "player.danmaku.externalServiceURL"
    }
    private let defaults: UserDefaults
    private let client: DanmakuServiceClient
    private var context: DanmakuPlaybackContext?
    private var playbackSessionID: UUID?
    private var database: SQLiteStore?
    private var selection: DanmakuSessionSelection?
    private var resolveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var epoch = UUID()
    private var searchRevision = UUID()
    private var legacyLocator: StableDanmakuLocator?
    private var preferredWork: String?
    private var pushObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, client: DanmakuServiceClient? = nil) {
        self.defaults = defaults
        self.client = client ?? .cached(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OKVideoMac/Danmaku-v2", isDirectory: true))
        isEnabled = defaults.object(forKey: Keys.enabled) == nil || defaults.bool(forKey: Keys.enabled)
        autoMatchEnabled = defaults.object(forKey: Keys.autoMatch) == nil || defaults.bool(forKey: Keys.autoMatch)
        fontScale = defaults.object(forKey: Keys.fontScale) == nil ? 1 : min(max(defaults.double(forKey: Keys.fontScale), 0.6), 2)
        opacity = defaults.object(forKey: Keys.opacity) == nil ? 0.86 : min(max(defaults.double(forKey: Keys.opacity), 0.2), 1)
        displayArea = DanmakuDisplayArea(rawValue: defaults.string(forKey: Keys.displayArea) ?? "") ?? .upperHalf
        density = DanmakuDensity(rawValue: defaults.string(forKey: Keys.density) ?? "") ?? .medium
        externalServiceURL = defaults.string(forKey: Keys.externalServiceURL) ?? ""
        pushObserver = NotificationCenter.default.addObserver(forName: DanmakuPushEvent.notification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.object as? DanmakuPushEvent else { return }
            MainActor.assumeIsolated { self?.acceptPush(event) }
        }
    }
    deinit { if let pushObserver { NotificationCenter.default.removeObserver(pushObserver) } }

    func begin(context: DanmakuPlaybackContext?, playbackSessionID: UUID, database: SQLiteStore) {
        endSession()
        self.context = context; self.playbackSessionID = playbackSessionID; self.database = database
        guard isEnabled, let context else { loadState = isEnabled ? .unavailable : .disabled; return }
        selection = .init(playbackSessionID: playbackSessionID, runtimeGeneration: context.runtimeGeneration)
        loadState = .resolvingSource
        let token = epoch
        resolveTask = Task { [weak self] in
            let bindings = (try? await database.danmakuBindings(configurationID: context.contentIdentity.configurationID)) ?? []
            guard let self, self.owns(token) else { return }
            let binding = bindings.first { $0.editionIdentity == context.editionIdentity }
            self.preferredWork = bindings.filter {
                $0.verificationVersion == 2 && $0.authority == .userSelection &&
                $0.editionIdentity.episode.content == context.contentIdentity &&
                $0.editionIdentity.editionID == context.editionIdentity.editionID &&
                $0.editionIdentity.episode.seasonNumber == context.editionIdentity.episode.seasonNumber
            }.max { $0.updatedAt < $1.updatedAt }?.match?.workID
            if let binding, binding.verificationVersion == 2 || binding.locator.kind == .localBookmark {
                self.offset = binding.offset
                if binding.authority == .userSelection || binding.locator.kind == .localBookmark {
                    if let source = self.directSource(binding.locator, context: context) {
                        self.choose(source, authority: .savedBinding); return
                    }
                    if let source = await self.restore(binding, context: context), self.owns(token) {
                        self.choose(source, authority: .savedBinding); return
                    }
                    guard self.owns(token) else { return }
                    self.loadState = .staleBinding(binding.locator); return
                }
            } else if let binding {
                self.legacyLocator = binding.locator
                self.recoveryDescription = "原来源未成功验证，正在重新匹配本集"
            }
            guard self.owns(token) else { return }
            if let requestID = context.upstreamRequestID, let event = DanmakuPushEvent.pending[requestID] {
                self.acceptPush(event)
                if self.selectedSource != nil { return }
            }
            if let source = DanmakuProvidedSourcePolicy.automaticSource(from: context.providedSources) {
                self.choose(source, authority: .providedSource)
            } else if !context.providedSources.isEmpty {
                self.candidates = context.providedSources; self.loadState = .awaitingSelection(context.providedSources)
            } else {
                await self.matchAutomatically(token: token)
            }
        }
    }
    func endSession() {
        resolveTask?.cancel(); loadTask?.cancel(); searchTask?.cancel()
        resolveTask = nil; loadTask = nil; searchTask = nil
        epoch = UUID(); searchRevision = UUID()
        context = nil; playbackSessionID = nil; database = nil; selection = nil
        selectedSource = nil; candidates = []; preferredWork = nil; legacyLocator = nil
        selectionDescription = ""; recoveryDescription = nil
        replaceTimeline(.init(comments: [])); searchState = .idle
        loadState = isEnabled ? .unavailable : .disabled; offset = 0
    }
    private func owns(_ token: UUID) -> Bool { isEnabled && epoch == token && !Task.isCancelled }
    private func resumeCurrentSessionIfNeeded() {
        guard let context, let playbackSessionID, let database else { return }
        begin(context: context, playbackSessionID: playbackSessionID, database: database)
    }
    func select(_ source: DanmakuSourceDescriptor) {
        resolveTask?.cancel(); searchTask?.cancel(); searchRevision = UUID()
        offset = 0
        searchState = candidates.isEmpty ? .idle : .results(candidates)
        choose(source, authority: .userSelection)
    }
    func retry() {
        guard isEnabled else { return }
        if let selectedSource { choose(selectedSource, authority: selection?.authority ?? .userSelection) }
        else { resumeCurrentSessionIfNeeded() }
    }
    func rematch() {
        guard let context, let playbackSessionID, isEnabled else { return }
        resolveTask?.cancel(); loadTask?.cancel(); searchTask?.cancel()
        epoch = UUID(); let token = epoch
        selection = .init(playbackSessionID: playbackSessionID, runtimeGeneration: context.runtimeGeneration)
        selectedSource = nil; offset = 0; replaceTimeline(.init(comments: []))
        resolveTask = Task { [weak self] in await self?.matchAutomatically(token: token, explicitlyRequested: true) }
    }
    func importXML(from url: URL) {
        guard let context, url.isFileURL else { return }
        select(.init(stable: .init(kind: .localBookmark, provider: "local", resourceID: url.path, displayName: url.lastPathComponent),
                     runtime: .init(url: url, runtimeGeneration: context.runtimeGeneration)))
    }
    func updateOffset(_ value: TimeInterval) {
        offset = min(max(value.isFinite ? value : 0, -120), 120)
        persistCurrentBinding(authority: .userSelection)
    }
    private func matchAutomatically(token: UUID, explicitlyRequested: Bool = false) async {
        guard owns(token) else { return }
        guard let context, let request = context.matchRequest,
              autoMatchEnabled || explicitlyRequested else { loadState = .unavailable; return }
        let endpoints = await searchEndpoints(context)
        guard owns(token) else { return }
        guard !endpoints.isEmpty, !request.searchTitle.isEmpty else { loadState = .unavailable; return }
        searchState = .searching; loadState = .resolvingSource
        do {
            let result = try await client.search(keyword: request.searchTitle, endpoints: endpoints, generation: context.runtimeGeneration)
            guard owns(token), selection?.authority == DanmakuSelectionAuthority.none else { return }
            guard result.successfulServices > 0 else {
                searchState = .failed(message: "弹幕服务暂不可用，可重试")
                loadState = .failed(nil, message: "弹幕服务暂不可用，可重试"); return
            }
            let matched = DanmakuMatcher.candidates(result.sources, for: request, preferredWork: preferredWork)
            candidates = Array((matched.isEmpty ? result.sources : matched).prefix(24))
            searchState = candidates.isEmpty ? .empty : .results(candidates)
            if let source = DanmakuMatcher.automaticSource(result.sources, for: request, preferredWork: preferredWork) {
                choose(source, authority: .automaticMatch)
            } else {
                loadState = candidates.isEmpty ? .unavailable : .awaitingSelection(candidates)
            }
        } catch {
            guard owns(token) else { return }
            loadState = .failed(nil, message: "弹幕服务暂不可用，可重试")
        }
    }
    func search(_ rawKeyword: String) {
        guard isEnabled, let context else { return }
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        searchTask?.cancel(); searchRevision = UUID()
        let revision = searchRevision, token = epoch
        searchState = .searching
        searchTask = Task { [weak self, client] in
            do {
                guard let self else { return }
                let endpoints = await self.searchEndpoints(context)
                let result = try await client.search(keyword: keyword, endpoints: endpoints, generation: context.runtimeGeneration)
                guard self.owns(token), self.searchRevision == revision else { return }
                self.candidates = result.sources
                self.searchState = result.successfulServices == 0 ? .failed(message: "弹幕服务暂不可用") :
                    (result.sources.isEmpty ? .empty : .results(result.sources))
                if self.selectedSource == nil { self.loadState = .awaitingSelection(result.sources) }
            } catch { }
        }
    }
    private func choose(_ source: DanmakuSourceDescriptor, authority: DanmakuSelectionAuthority) {
        guard isEnabled, let context, let playbackSessionID, var selection else { return }
        guard selection.select(source, authority: authority, playbackSessionID: playbackSessionID,
            runtimeGeneration: context.runtimeGeneration, basedOnRevision: selection.selectionRevision) else { return }
        self.selection = selection; selectedSource = source
        selectionDescription = authority >= .savedBinding ? "手动选择" : (authority == .providedSource ? "源提供" : "自动匹配")
        loadTask?.cancel(); replaceTimeline(.init(comments: [])); loadState = .loading(source)
        let revision = selection.selectionRevision, token = epoch
        loadTask = Task { [weak self, client] in
            do {
                let parsed = try await client.load(source)
                guard let self, self.owns(token), self.selection?.selectionRevision == revision else { return }
                if parsed.comments.isEmpty, authority == .providedSource, self.autoMatchEnabled {
                    self.selection = .init(playbackSessionID: playbackSessionID, runtimeGeneration: context.runtimeGeneration)
                    await self.matchAutomatically(token: token)
                    return
                }
                self.replaceTimeline(parsed)
                self.loadState = parsed.comments.isEmpty ? .empty(source) : .ready(source, parsed)
                if !parsed.comments.isEmpty {
                    self.persistCurrentBinding(authority: authority == .savedBinding ? .userSelection : authority)
                    if self.legacyLocator != nil { self.recoveryDescription = "原来源未成功验证，已重新匹配本集" }
                }
            } catch {
                guard let self, self.owns(token), self.selection?.selectionRevision == revision else { return }
                self.loadState = .failed(source, message: "弹幕加载失败：\(error.localizedDescription)")
                if authority == .providedSource, self.autoMatchEnabled {
                    self.selection = .init(playbackSessionID: playbackSessionID, runtimeGeneration: context.runtimeGeneration)
                    await self.matchAutomatically(token: token)
                }
            }
        }
    }
    private func persistCurrentBinding(authority: DanmakuSelectionAuthority) {
        guard case .ready = loadState, let context, let source = selectedSource, let database else { return }
        var binding = DanmakuBinding(editionIdentity: context.editionIdentity, locator: source.stable, offset: offset)
        binding.verificationVersion = 2; binding.authority = authority; binding.match = source.match
        binding.previousLocator = legacyLocator
        let token = epoch, revision = selection?.selectionRevision
        Task { [weak self] in
            guard let self, self.owns(token), self.selection?.selectionRevision == revision else { return }
            try? await database.saveDanmakuBinding(binding)
        }
    }
    private func directSource(_ locator: StableDanmakuLocator, context: DanmakuPlaybackContext) -> DanmakuSourceDescriptor? {
        if let source = context.providedSources.first(where: { $0.stable == locator }) { return source }
        if locator.kind == .localBookmark, FileManager.default.fileExists(atPath: locator.resourceID) {
            return .init(stable: locator, runtime: .init(url: URL(fileURLWithPath: locator.resourceID), runtimeGeneration: context.runtimeGeneration))
        }
        return nil
    }
    private func restore(_ binding: DanmakuBinding, context: DanmakuPlaybackContext) async -> DanmakuSourceDescriptor? {
        guard let request = context.matchRequest else { return nil }
        let result = try? await client.search(keyword: request.searchTitle, endpoints: await searchEndpoints(context), generation: context.runtimeGeneration)
        return result?.sources.first { source in
            guard source.stable.provider == binding.locator.provider else { return false }
            if binding.locator.kind == .providerURLIdentity { return source.stable == binding.locator }
            if let video = binding.match?.videoID { return source.match?.videoID == video }
            guard let previous = binding.match, let current = source.match else { return false }
            return previous.workID == current.workID && previous.episode == current.episode && previous.season == current.season
        }
    }
    private func searchEndpoints(_ context: DanmakuPlaybackContext) async -> [DanmakuServiceEndpoint] {
        var values: [DanmakuServiceEndpoint] = []
        for capability in context.searchCapabilities {
            switch capability {
            case .catPawAPI(let url, let headers):
                if let e = DanmakuServiceEndpoint(url: url, headers: headers, identity: "source:\(context.contentIdentity.configurationID):\(context.contentIdentity.siteKey)") { values.append(e) }
            case .configuredEndpoint(let raw):
                for url in Self.urls(raw) {
                    if let endpoint = DanmakuServiceEndpoint(url: url) { values.append(endpoint) }
                    else { values += await client.discover(page: url, identity: "source:\(context.contentIdentity.configurationID):\(context.contentIdentity.siteKey)") }
                }
            case .providerWebPage(let url, let headers):
                values += await client.discover(page: url, headers: headers, identity: "source:\(context.contentIdentity.configurationID):\(context.contentIdentity.siteKey)")
            }
        }
        values += Self.urls(externalServiceURL).compactMap { DanmakuServiceEndpoint(url: $0) }
        var seen = Set<String>()
        return values.filter { seen.insert($0.identity).inserted }
    }
    private static func urls(_ raw: String) -> [URL] {
        if let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme ?? "") { return [url] }
        guard let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        func collect(_ value: Any, depth: Int) -> [URL] {
            guard depth < 6 else { return [] }
            if let string = value as? String, let url = URL(string: string), ["http", "https"].contains(url.scheme ?? "") { return [url] }
            if let list = value as? [Any] { return list.flatMap { collect($0, depth: depth + 1) } }
            if let object = value as? [String: Any] { return ["url", "api", "endpoint", "search", "urls"].flatMap { object[$0].map { collect($0, depth: depth + 1) } ?? [] } }
            return []
        }
        return collect(json, depth: 0)
    }
    private func acceptPush(_ event: DanmakuPushEvent) {
        guard isEnabled, let context, event.requestID == context.upstreamRequestID,
              event.siteKey == context.contentIdentity.siteKey,
              (selection?.authority ?? .none) <= .providedSource else { return }
        DanmakuPushEvent.pending[event.requestID] = nil
        let sources = DanmakuSourceNormalizer.sources(from: event.payload, provider: "catpaw:\(event.siteKey)",
            baseURL: event.baseURL, runtimeGeneration: context.runtimeGeneration)
        if let source = DanmakuProvidedSourcePolicy.automaticSource(from: sources) { choose(source, authority: .providedSource) }
    }
    private func replaceTimeline(_ value: DanmakuTimeline) { timeline = value; timelineRevision &+= 1 }
    var suggestedSearchQuery: String { context?.matchRequest?.searchTitle ?? context?.contentIdentity.title ?? "" }
    var statusText: String {
        switch loadState {
        case .disabled: return "弹幕已关闭"
        case .resolvingSource: return "正在自动匹配本集弹幕…"
        case .awaitingSelection: return "请确认作品、集数或版本"
        case .loading(let source): return "正在加载 \(source.stable.displayName)…"
        case .ready(let source, let timeline): return "\(selectionDescription)：\(source.stable.displayName) · \(timeline.comments.count) 条"
        case .empty: return "这个来源暂无本集弹幕"
        case .staleBinding: return "已选来源需重新匹配，请重试或选择重新匹配"
        case .failed(_, let message): return message
        case .unavailable: return "暂无可自动匹配的本集弹幕"
        }
    }
    var searchStatusText: String? {
        switch searchState {
        case .empty: return "没有找到匹配的弹幕"
        case .failed(let message): return "搜索失败：\(message)"
        default: return nil
        }
    }
}

struct DanmakuPushEvent: Sendable {
    @MainActor static var pending: [UUID: DanmakuPushEvent] = [:]
    @MainActor static func publish(_ event: DanmakuPushEvent) {
        if pending.count > 16 { pending.removeAll() }
        pending[event.requestID] = event
        NotificationCenter.default.post(name: notification, object: event)
    }
    static let notification = Notification.Name("OKVideoMac.DanmakuPush")
    let requestID: UUID
    let siteKey: String
    let baseURL: URL
    let payload: JSONValue
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

/// CVDisplayLink supports the app's macOS 12 minimum. The realtime callback
/// never touches AppKit and can enqueue at most one outstanding main-thread frame.
final class DanmakuDisplayDriver {
    private var link: CVDisplayLink?
    private let lock = NSLock()
    private var running = false
    private var revision: UInt64 = 0
    private var pending: UInt64?
    private let frame: () -> Void
    init(frame: @escaping () -> Void) { self.frame = frame }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func start(displayID: CGDirectDisplayID) {
        guard !isRunning else { return }
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &created) == kCVReturnSuccess,
              let created else { return }
        guard CVDisplayLinkSetOutputHandler(created, { [weak self] _, _, _, _, _ in
            self?.enqueue(); return kCVReturnSuccess
        }) == kCVReturnSuccess else { return }
        link = created
        lock.lock(); revision &+= 1; running = true; lock.unlock()
        if CVDisplayLinkStart(created) != kCVReturnSuccess { stop() }
    }
    private func enqueue() {
        lock.lock()
        guard running, pending == nil else { lock.unlock(); return }
        let ticket = revision
        pending = ticket
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let deliver = self.running && self.revision == ticket && self.pending == ticket
            if self.pending == ticket { self.pending = nil }
            self.lock.unlock()
            if deliver { self.frame() }
        }
    }
    func stop() {
        lock.lock(); running = false; revision &+= 1; pending = nil; lock.unlock()
        if let link { CVDisplayLinkStop(link) }
        link = nil
    }
    deinit { stop() }
}

final class DanmakuOverlayNSView: NSView {
    private struct ActiveComment {
        let lane: Int
        let startTime: TimeInterval
        let width: CGFloat
        let laneHeight: CGFloat
        let lifetime: TimeInterval
        let mode: DanmakuMode
        let layer: CALayer
        let bytes: Int
    }
    private var timeline = DanmakuTimeline(comments: [])
    private var timelineRevision: UInt64?
    private var clock = DanmakuClock()
    private var generation: UInt64 = 1
    private var lastPresentedMediaTime: TimeInterval?
    private var active: [ActiveComment] = []
    private var scrollingScheduler = DanmakuLaneScheduler(laneCount: 0)
    private var displayDriver: DanmakuDisplayDriver?
    private var offset: TimeInterval = 0
    private var fontScale: Double = 1
    private var commentOpacity: Double = 0.86
    private var displayArea: DanmakuDisplayArea = .upperHalf
    private var density: DanmakuDensity = .medium
    private var lastBoundsSize: CGSize = .zero
    private let spriteRoot = CALayer()
    private(set) var rasterizationCount = 0
    private(set) var rasterBytes = 0
    static let maximumRasterBytes = 48 * 1_024 * 1_024
    var activeCommentCount: Int { active.count }
    var isDisplayDriverRunning: Bool { displayDriver?.isRunning == true }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        spriteRoot.masksToBounds = true
        // AppKit supplies the flipped view coordinates; do not flip sublayers again.
        layer?.addSublayer(spriteRoot)
        displayDriver = DanmakuDisplayDriver { [weak self] in
            guard let self else { return }
            self.renderFrame(at: ProcessInfo.processInfo.systemUptime)
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit { displayDriver?.stop(); NotificationCenter.default.removeObserver(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayDriver?.stop()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowDisplayChanged), name: name, object: window)
            }
        }
        refreshDriver()
    }
    @objc private func windowDisplayChanged() {
        displayDriver?.stop()
        refreshDriver()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resetPresentation(at: clock.currentTime(at: ProcessInfo.processInfo.systemUptime))
        refreshDriver()
    }
    private func refreshDriver() {
        guard let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor,
              clock.isAdvancing, !timeline.comments.isEmpty, bounds.width > 0 else {
            displayDriver?.stop(); return
        }
        let id = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        displayDriver?.start(displayID: id)
    }
    func update(timeline: DanmakuTimeline, timelineRevision: UInt64, snapshot: PlayerSnapshot,
                offset: TimeInterval, fontScale: Double, opacity: Double,
                displayArea: DanmakuDisplayArea, density: DanmakuDensity) {
        let now = ProcessInfo.processInfo.systemUptime
        var reset = self.timelineRevision != timelineRevision || self.offset != offset
            || self.fontScale != fontScale || self.displayArea != displayArea || self.density != density
        if self.timelineRevision != timelineRevision {
            self.timeline = timeline; self.timelineRevision = timelineRevision; generation &+= 1
        }
        self.offset = offset; self.fontScale = fontScale; self.displayArea = displayArea; self.density = density
        commentOpacity = opacity
        let discontinuity = clock.synchronize(mediaTime: snapshot.seekTarget ?? snapshot.position,
            sampleUptime: snapshot.isSeeking ? now : snapshot.positionSampleUptime, monotonicTime: now,
            rate: snapshot.speed, isPlaying: snapshot.status == .playing,
            isBuffering: snapshot.isPausedForCache || snapshot.status == .buffering,
            isSeeking: snapshot.isSeeking, generation: generation)
        reset = reset || discontinuity
        if reset { resetPresentation(at: clock.currentTime(at: now)) }
        // Also updates opacity and final paused/buffering positions without a running display link.
        renderFrame(at: now)
        refreshDriver()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spriteRoot.frame = bounds
        CATransaction.commit()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            resetPresentation(at: clock.currentTime(at: ProcessInfo.processInfo.systemUptime))
        }
        refreshDriver()
    }
    /// Main-thread frame entry shared by the display link and deterministic rendering tests.
    func renderFrame(at uptime: TimeInterval) {
        guard !timeline.comments.isEmpty, bounds.width > 0 else { return }
        let mediaTime = clock.currentTime(at: uptime)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        active.removeAll { item in
            guard mediaTime - item.startTime > item.lifetime else { return false }
            item.layer.removeFromSuperlayer(); rasterBytes -= item.bytes
            return true
        }
        presentComments(through: mediaTime)
        for item in active {
            let y = item.mode == .bottom
                ? max(0, bounds.height * displayArea.fraction - CGFloat(item.lane + 1) * item.laneHeight)
                : CGFloat(item.lane) * item.laneHeight
            let progress = min(max((mediaTime - item.startTime) / item.lifetime, 0), 1)
            let x = item.mode == .scrolling ? bounds.width - CGFloat(progress) * (bounds.width + item.width)
                : max(0, (bounds.width - item.width) / 2)
            item.layer.position = CGPoint(x: x, y: y)
            item.layer.opacity = Float(commentOpacity)
        }
    }
    private func presentComments(through mediaTime: TimeInterval) {
        let previous = lastPresentedMediaTime ?? max(0, mediaTime - 0.15)
        // A final pause observation can be a few milliseconds behind the last
        // interpolated frame. Keep its sprites; explicit seeks reset in update.
        guard mediaTime >= previous else { return }
        guard mediaTime - previous < 1.5 else {
            resetPresentation(at: mediaTime); return
        }
        for comment in timeline.comments(from: previous - offset + 0.000_001, through: mediaTime - offset) {
            guard active.count < density.maximumActiveComments else { break }
            add(comment, at: comment.time + offset)
        }
        lastPresentedMediaTime = mediaTime
    }
    private func add(_ comment: DanmakuComment, at time: TimeInterval) {
        let font = NSFont.systemFont(ofSize: CGFloat(min(max(comment.fontSize * fontScale, 13), 58)), weight: .semibold)
        let color = NSColor(calibratedRed: CGFloat((comment.color >> 16) & 0xFF) / 255,
            green: CGFloat((comment.color >> 8) & 0xFF) / 255, blue: CGFloat(comment.color & 0xFF) / 255, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color,
            .strokeColor: NSColor.black.withAlphaComponent(0.9), .strokeWidth: -2.5]
        let size = (comment.text as NSString).size(withAttributes: attributes)
        let width = ceil(size.width) + 8, height = ceil(size.height) + 8
        let scale = window?.backingScaleFactor ?? 2
        let pixelWidth = Int(ceil(width * scale)), pixelHeight = Int(ceil(height * scale))
        let bytes = pixelWidth * pixelHeight * 4
        guard pixelWidth > 0, pixelWidth <= 16_384, pixelHeight > 0,
              bytes <= Self.maximumRasterBytes - rasterBytes else { return }
        let laneHeight = font.pointSize + density.laneSpacing
        let laneCount = max(1, Int(max(laneHeight, bounds.height * displayArea.fraction) / laneHeight))
        let lane: Int
        if comment.mode == .scrolling {
            guard let reservation = scrollingScheduler.reserve(at: time, textWidth: Double(width),
                viewportWidth: Double(bounds.width), lifetime: 8) else { return }
            lane = reservation.lane
        } else {
            let occupied = Set(active.filter { $0.mode == comment.mode }.map(\.lane))
            guard let free = (0..<laneCount).first(where: { !occupied.contains($0) }) else { return }
            lane = free
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixelWidth * 4, bitsPerPixel: 32),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: scale, y: scale)
        (comment.text as NSString).draw(at: CGPoint(x: 4, y: 4), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { return }
        let sprite = CALayer()
        sprite.anchorPoint = .zero; sprite.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        sprite.contents = image; sprite.contentsScale = scale
        sprite.opacity = Float(commentOpacity)
        spriteRoot.addSublayer(sprite)
        rasterizationCount += 1; rasterBytes += bytes
        active.append(ActiveComment(lane: lane, startTime: time, width: width, laneHeight: laneHeight,
            lifetime: comment.mode == .scrolling ? 8 : 4, mode: comment.mode, layer: sprite, bytes: bytes))
    }
    private func resetPresentation(at mediaTime: TimeInterval) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        active.forEach { $0.layer.removeFromSuperlayer() }
        CATransaction.commit()
        active.removeAll(keepingCapacity: true); rasterBytes = 0
        let fontHeight = CGFloat(28 * fontScale) + density.laneSpacing
        scrollingScheduler.reset(laneCount: max(1, Int(max(1, bounds.height * displayArea.fraction) / max(1, fontHeight))))
        lastPresentedMediaTime = max(0, mediaTime - 0.15)
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

            Toggle("自动匹配本集", isOn: $coordinator.autoMatchEnabled)
                .toggleStyle(.checkbox)
            Text(coordinator.statusText)
                .font(.caption)
                .foregroundColor(.white.opacity(0.58))

            if let recovery = coordinator.recoveryDescription {
                Text(recovery).font(.caption).foregroundColor(.white.opacity(0.58))
            }
            HStack {
                Button("重试") { coordinator.retry() }
                Button("重新匹配") { coordinator.rematch() }
            }.buttonStyle(.bordered).controlSize(.small)
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
                Text(coordinator.offset == 0 ? "同步" : String(format: coordinator.offset > 0 ? "延后%.1fs" : "提前%.1fs", abs(coordinator.offset)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: 80)
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
