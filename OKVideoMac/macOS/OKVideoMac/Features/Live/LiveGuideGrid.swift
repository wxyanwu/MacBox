import AppKit
import OKVideoCore
import SwiftUI

struct LiveGuideDemandDebounce: Equatable {
    static let quietInterval: UInt64 = 100_000_000
    static let maximumWait: UInt64 = 250_000_000
    private(set) var startedAt: UInt64?

    mutating func register(at uptime: UInt64) {
        if startedAt == nil { startedAt = uptime }
    }

    func delay(at uptime: UInt64) -> UInt64 {
        guard let startedAt else { return Self.quietInterval }
        let elapsed = uptime >= startedAt ? uptime - startedAt : Self.maximumWait
        let remaining = elapsed < Self.maximumWait ? Self.maximumWait - elapsed : 0
        return min(Self.quietInterval, remaining)
    }

    mutating func reset() { startedAt = nil }
}

enum LiveGuideFreshness: Equatable {
    case fresh
    case stale
}

enum LiveGuideRefreshPhase: Equatable {
    case idle
    case loading
    case backoff
}

struct LiveGuideContentState: Equatable {
    let snapshot: EPGGuideSnapshot
    var freshness: LiveGuideFreshness
    var refreshPhase: LiveGuideRefreshPhase
    let failures: [String: EPGGuideFailure]
}

struct LiveGuideEmptyState: Equatable {
    let snapshot: EPGGuideSnapshot
    var freshness: LiveGuideFreshness
    var refreshPhase: LiveGuideRefreshPhase
}

enum LiveGuideLifecycleState: Equatable {
    case inactive
    case loadingInitial
    case content(LiveGuideContentState)
    case empty(LiveGuideEmptyState)
    case unsupported
    case failed(EPGGuideFailure)
}

struct LiveGuideDeliveryIdentity: Equatable {
    let source: EPGSourceKey
    let revision: String
    let demandRevision: UUID
    let serviceIncarnation: UUID
    let capability: EPGGuideCapability
}

/// Main-actor publication boundary. It owns only one bounded snapshot and
/// rejects every late result using one delivery identity comparison.
@MainActor
final class LiveGuideState: ObservableObject {
    @Published private(set) var lifecycle: LiveGuideLifecycleState = .inactive
    private var expectedIdentity: LiveGuideDeliveryIdentity?

    var snapshot: EPGGuideSnapshot? {
        switch lifecycle {
        case .content(let value): return value.snapshot
        case .empty(let value): return value.snapshot
        default: return nil
        }
    }

    var retainedSnapshotCost: Int { snapshot?.estimatedByteCost ?? 0 }

    func begin(_ identity: LiveGuideDeliveryIdentity, refreshing: Bool) {
        let retainable = snapshot?.source == identity.source
            && snapshot?.revision == identity.revision
            && snapshot.map { canRetain($0, for: identity) } == true
        expectedIdentity = identity
        guard retainable else {
            lifecycle = .loadingInitial
            return
        }
        setRefreshPhase(refreshing ? .loading : .idle)
    }

    func setUnsupported() {
        expectedIdentity = nil
        lifecycle = .unsupported
    }

    func deactivate() {
        expectedIdentity = nil
        lifecycle = .inactive
    }

    func suspend() {
        expectedIdentity = nil
        switch lifecycle {
        case .content(var value):
            value.freshness = .stale
            value.refreshPhase = .idle
            lifecycle = .content(value)
        case .empty(var value):
            value.freshness = .stale
            value.refreshPhase = .idle
            lifecycle = .empty(value)
        default:
            lifecycle = .inactive
        }
    }

    @discardableResult
    func publish(_ value: EPGGuideSnapshot,
                 identity: LiveGuideDeliveryIdentity) -> Bool {
        guard expectedIdentity == identity,
              value.source == identity.source,
              value.revision == identity.revision,
              value.demandRevision == identity.demandRevision,
              validatesCoherence(value, identity: identity) else { return false }

        let failures = Dictionary(uniqueKeysWithValues: value.rows.compactMap { row in
            if case .failed(let failure) = row.state { return (row.id, failure) }
            return nil
        })
        let usableRows = value.rows.filter { row in
            if case .failed = row.state { return false }
            if row.state == .unsupported { return false }
            return true
        }
        guard !usableRows.isEmpty else {
            lifecycle = value.rows.contains(where: { $0.state == .unsupported })
                ? .unsupported
                : .failed(failures.values.first ?? .unavailable)
            return true
        }
        let freshness: LiveGuideFreshness = value.rows.contains(where: {
            $0.availability == .stale || $0.availability == .failed
        }) ? .stale : .fresh
        if usableRows.allSatisfy({ $0.programmes.isEmpty }) {
            lifecycle = .empty(LiveGuideEmptyState(
                snapshot: value, freshness: freshness, refreshPhase: .idle
            ))
        } else {
            lifecycle = .content(LiveGuideContentState(
                snapshot: value, freshness: freshness,
                refreshPhase: .idle, failures: failures
            ))
        }
        return true
    }

    private func validatesCoherence(_ value: EPGGuideSnapshot,
                                    identity: LiveGuideDeliveryIdentity) -> Bool {
        switch (identity.capability, value.coherence) {
        case (.xmltv, .xmltv(let token)):
            return token.serviceIncarnation == identity.serviceIncarnation
                && token.demandRevision == identity.demandRevision
        case (.xtreamShort, .perRowToken):
            return value.rows.allSatisfy { row in
                guard let token = row.token else { return row.programmes.isEmpty }
                return token.serviceIncarnation == identity.serviceIncarnation
                    && token.demandRevision == identity.demandRevision
            }
        default:
            return false
        }
    }

    private func canRetain(_ value: EPGGuideSnapshot,
                           for identity: LiveGuideDeliveryIdentity) -> Bool {
        switch (identity.capability, value.coherence) {
        case (.xmltv, .xmltv(let token)):
            return token.serviceIncarnation == identity.serviceIncarnation
        case (.xtreamShort, .perRowToken):
            return value.rows.allSatisfy {
                $0.token?.serviceIncarnation == identity.serviceIncarnation
                    || ($0.token == nil && $0.programmes.isEmpty)
            }
        default:
            return false
        }
    }

    func fail(_ failure: EPGGuideFailure,
              identity: LiveGuideDeliveryIdentity) {
        guard expectedIdentity == identity else { return }
        switch lifecycle {
        case .content(var value):
            value.freshness = .stale
            value.refreshPhase = .backoff
            lifecycle = .content(value)
        case .empty(var value):
            value.freshness = .stale
            value.refreshPhase = .backoff
            lifecycle = .empty(value)
        default:
            lifecycle = failure == .cancelled ? .inactive : .failed(failure)
        }
    }

    private func setRefreshPhase(_ phase: LiveGuideRefreshPhase) {
        switch lifecycle {
        case .content(var value):
            value.refreshPhase = phase
            lifecycle = .content(value)
        case .empty(var value):
            value.refreshPhase = phase
            lifecycle = .empty(value)
        default:
            break
        }
    }
}

struct LiveGuideGridProgramme: Equatable, Identifiable, Sendable {
    let id: EPGProgrammeRecordIdentity
    let title: String
    let start: Date
    let end: Date

    init(_ value: EPGWindowProgramme) {
        id = value.id
        title = value.title
        start = value.start
        end = value.end
    }
}

struct LiveGuideGridRow: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let state: EPGGuideRowState
    let programmes: [LiveGuideGridProgramme]

    init(id: String, title: String, subtitle: String? = nil,
         state: EPGGuideRowState = .ready, programmes: [LiveGuideGridProgramme]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.programmes = programmes
    }
}

struct LiveGuideGridModel: Equatable, Sendable {
    let windowStart: Date
    let windowEnd: Date
    let timeZone: TimeZone
    let rows: [LiveGuideGridRow]

    init(windowStart: Date, windowEnd: Date, timeZone: TimeZone,
         rows: [LiveGuideGridRow]) throws {
        let programmeCount = rows.reduce(0) { $0 + $1.programmes.count }
        guard windowStart < windowEnd,
              windowEnd.timeIntervalSince(windowStart) <= 24 * 60 * 60,
              !rows.isEmpty, rows.count <= EPGGuideLimits.maximumDesiredRows,
              Set(rows.map(\.id)).count == rows.count,
              programmeCount <= EPGGuideLimits.maximumProgrammes,
              rows.allSatisfy({ row in
                  row.programmes.count <= EPGGuideLimits.maximumProgrammesPerRow
                      && Set(row.programmes.map(\.id)).count == row.programmes.count
                      && row.programmes.allSatisfy { $0.start < $0.end }
              }) else {
            throw EPGGuideValidationError.invalidResult
        }
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.timeZone = timeZone
        self.rows = rows
    }

    init(snapshot: EPGGuideSnapshot, timeZone: TimeZone,
         subtitles: [String: String] = [:]) throws {
        try self.init(
            windowStart: snapshot.slices.first?.start ?? .distantPast,
            windowEnd: snapshot.slices.last?.end ?? .distantFuture,
            timeZone: timeZone,
            rows: snapshot.rows.map { row in
                LiveGuideGridRow(
                    id: row.id,
                    title: row.channel.name,
                    subtitle: subtitles[row.id] ?? row.channel.number,
                    state: row.state,
                    programmes: row.programmes.map(LiveGuideGridProgramme.init)
                )
            }
        )
    }
}

struct LiveGuideTimeAxisTick: Equatable {
    let date: Date
    let label: String
}

enum LiveGuideTimeAxisFormatter {
    static func ticks(from start: Date, to end: Date, timeZone: TimeZone,
                      interval: TimeInterval = 30 * 60) -> [LiveGuideTimeAxisTick] {
        guard start < end, interval > 0 else { return [] }
        var dates: [Date] = []
        var value = start
        while value <= end, dates.count < 64 {
            dates.append(value)
            value = value.addingTimeInterval(interval)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let base = dates.map(formatter.string)
        let duplicateLabels = Set(Dictionary(grouping: base, by: { $0 })
            .filter { $0.value.count > 1 }.map(\.key))
        let offset = DateFormatter()
        offset.locale = formatter.locale
        offset.timeZone = timeZone
        offset.dateFormat = "ZZZZZ"
        return zip(dates, base).map { date, label in
            let final = duplicateLabels.contains(label)
                ? "\(label) GMT\(offset.string(from: date))" : label
            return LiveGuideTimeAxisTick(date: date, label: final)
        }
    }
}

struct LiveGuideGridDebugMetrics: Equatable {
    let totalProgrammes: Int
    let visibleProgrammeViews: Int
    let realizedProgrammeViews: Int
    let maximumVisibleProgrammeViews: Int
    let emittedLayoutAttributes: Int
    let cachedTimeLabels: Int
}

struct LiveGuideGridFixedFrames: Equatable {
    let corner: NSRect
    let timeHeader: NSRect
    let channelHeader: NSRect
    let content: NSRect
}

final class LiveGuideGridView: NSView {
    static let rowHeight: CGFloat = 64
    static let timeHeaderHeight: CGFloat = 42
    static let channelColumnWidth: CGFloat = 188
    static let pointsPerHour: CGFloat = 180
    static let minimumProgrammeWidth: CGFloat = 128

    private let cornerLabel = NSTextField(labelWithString: "Program Guide")
    private let timeHeader = LiveGuideTimeHeaderView()
    private let channelHeader = LiveGuideChannelHeaderView()
    private let grid = LiveGuideViewportView()
    private let horizontalScroller = NSScroller()
    private let verticalScroller = NSScroller()
    private(set) var model: LiveGuideGridModel?
    private var maximumVisibleProgrammeViews = 0
    private var selectedProgrammeIndexPath: IndexPath?
    private var virtualOffset = NSPoint.zero
    private var updatingScrollers = false
    var onProgrammeActivated: ((LiveGuideGridRow, LiveGuideGridProgramme) -> Void)?
    var onProgrammeSelected: ((LiveGuideGridRow, LiveGuideGridProgramme) -> Void)?
    var onChannelActivated: ((LiveGuideGridRow) -> Void)? {
        didSet { channelHeader.onChannelActivated = onChannelActivated }
    }
    var onVisibleRangeChanged: ((Range<Int>) -> Void)?
    private var lastVisibleRange: Range<Int>?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        cornerLabel.alignment = .left
        cornerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        cornerLabel.lineBreakMode = .byTruncatingTail
        cornerLabel.setAccessibilityRole(.staticText)
        cornerLabel.setAccessibilityLabel("Program Guide")

        grid.onMoveSelection = { [weak self] horizontal, vertical in
            self?.moveSelection(horizontal: horizontal, vertical: vertical)
        }
        grid.onActivateSelection = { [weak self] in self?.activateSelection() }
        grid.onSelectProgramme = { [weak self] programmeIndex, rowIndex, activate in
            self?.selectProgramme(item: programmeIndex, section: rowIndex, activate: activate)
        }
        grid.onScroll = { [weak self] delta in self?.scroll(by: delta) }

        horizontalScroller.scrollerStyle = .overlay
        horizontalScroller.knobStyle = .default
        horizontalScroller.target = self
        horizontalScroller.action = #selector(scrollerChanged(_:))
        verticalScroller.scrollerStyle = .overlay
        verticalScroller.knobStyle = .default
        verticalScroller.target = self
        verticalScroller.action = #selector(scrollerChanged(_:))

        addSubview(cornerLabel)
        addSubview(timeHeader)
        addSubview(channelHeader)
        addSubview(grid)
        addSubview(horizontalScroller)
        addSubview(verticalScroller)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let headerHeight = min(Self.timeHeaderHeight, bounds.height)
        let columnWidth = min(Self.channelColumnWidth, bounds.width)
        let scrollerThickness = NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay)
        let contentWidth = max(0, bounds.width - columnWidth - scrollerThickness)
        let contentHeight = max(0, bounds.height - headerHeight - scrollerThickness)
        cornerLabel.frame = NSRect(x: 12, y: 0,
            width: max(0, columnWidth - 20), height: headerHeight)
        timeHeader.frame = NSRect(x: columnWidth, y: 0,
            width: contentWidth, height: headerHeight)
        channelHeader.frame = NSRect(x: 0, y: headerHeight,
            width: columnWidth, height: contentHeight)
        grid.frame = NSRect(x: columnWidth, y: headerHeight,
            width: contentWidth, height: contentHeight)
        horizontalScroller.frame = NSRect(x: columnWidth,
            y: headerHeight + contentHeight, width: contentWidth,
            height: scrollerThickness)
        verticalScroller.frame = NSRect(x: columnWidth + contentWidth,
            y: headerHeight, width: scrollerThickness, height: contentHeight)
        setVirtualOffset(virtualOffset)
    }

    func apply(_ model: LiveGuideGridModel, now: Date = Date()) {
        self.model = model
        let pointsPerHour = Self.layoutPointsPerHour(for: model)
        grid.configure(rows: model.rows, windowStart: model.windowStart,
            windowEnd: model.windowEnd, pointsPerHour: pointsPerHour,
            timeZone: model.timeZone, now: now)
        timeHeader.configure(start: model.windowStart, end: model.windowEnd,
            timeZone: model.timeZone, pointsPerHour: pointsPerHour)
        channelHeader.rows = model.rows
        maximumVisibleProgrammeViews = 0
        selectedProgrammeIndexPath = nil
        virtualOffset = .zero
        lastVisibleRange = nil
        setVirtualOffset(.zero)
    }

    func updateNow(_ date: Date) {
        grid.now = date
        grid.needsDisplay = true
    }

    func scroll(to point: NSPoint) { setVirtualOffset(point) }

    var scrollOffset: NSPoint { virtualOffset }

    var debugFixedFrames: LiveGuideGridFixedFrames {
        LiveGuideGridFixedFrames(corner: cornerLabel.frame, timeHeader: timeHeader.frame,
                                 channelHeader: channelHeader.frame, content: grid.frame)
    }

    var debugSelectedIndexPath: IndexPath? { selectedProgrammeIndexPath }

    var debugNowLineX: CGFloat? {
        guard let model, model.windowStart <= grid.now, grid.now <= model.windowEnd else {
            return nil
        }
        return CGFloat(grid.now.timeIntervalSince(model.windowStart) / 3_600)
            * grid.pointsPerHour
    }

    var debugVisibleAccessibilityLabels: [String] {
        grid.visibleAccessibilityLabels
    }

    func debugSelect(item: Int, section: Int) {
        selectProgramme(item: item, section: section, activate: false)
    }

    func debugMoveSelection(horizontal: Int, vertical: Int) {
        moveSelection(horizontal: horizontal, vertical: vertical)
    }

    func debugActivateSelection() { activateSelection() }

    var debugMetrics: LiveGuideGridDebugMetrics {
        let visible = grid.visibleProgrammeCount
        maximumVisibleProgrammeViews = max(maximumVisibleProgrammeViews, visible)
        return LiveGuideGridDebugMetrics(
            totalProgrammes: model?.rows.reduce(0, { $0 + $1.programmes.count }) ?? 0,
            visibleProgrammeViews: visible,
            realizedProgrammeViews: model == nil ? 0 : 1,
            maximumVisibleProgrammeViews: maximumVisibleProgrammeViews,
            emittedLayoutAttributes: visible,
            cachedTimeLabels: timeHeader.cachedLabelCount)
    }

    @objc private func scrollerChanged(_ sender: NSScroller) {
        guard !updatingScrollers else { return }
        let maximum = maximumOffset
        var proposed = virtualOffset
        if sender === horizontalScroller {
            proposed.x = CGFloat(sender.doubleValue) * maximum.x
        } else {
            proposed.y = CGFloat(sender.doubleValue) * maximum.y
        }
        setVirtualOffset(proposed)
    }

    private func scroll(by delta: NSPoint) {
        setVirtualOffset(NSPoint(x: virtualOffset.x + delta.x,
                                 y: virtualOffset.y + delta.y))
    }

    private var contentSize: NSSize {
        guard let model else { return .zero }
        return NSSize(
            width: CGFloat(model.windowEnd.timeIntervalSince(model.windowStart) / 3_600)
                * grid.pointsPerHour,
            height: CGFloat(model.rows.count) * Self.rowHeight)
    }

    private var maximumOffset: NSPoint {
        NSPoint(x: max(0, contentSize.width - grid.bounds.width),
                y: max(0, contentSize.height - grid.bounds.height))
    }

    private func setVirtualOffset(_ proposed: NSPoint) {
        let maximum = maximumOffset
        virtualOffset = NSPoint(x: min(max(0, proposed.x), maximum.x),
                                y: min(max(0, proposed.y), maximum.y))
        grid.virtualOffset = virtualOffset
        timeHeader.horizontalOffset = virtualOffset.x
        channelHeader.verticalOffset = virtualOffset.y
        updateScrollers(maximum: maximum)
        updateVisibleRange()
        maximumVisibleProgrammeViews = max(maximumVisibleProgrammeViews,
                                           grid.visibleProgrammeCount)
    }

    private func updateScrollers(maximum: NSPoint) {
        updatingScrollers = true
        defer { updatingScrollers = false }
        horizontalScroller.knobProportion = contentSize.width > 0
            ? min(1, grid.bounds.width / contentSize.width) : 1
        verticalScroller.knobProportion = contentSize.height > 0
            ? min(1, grid.bounds.height / contentSize.height) : 1
        horizontalScroller.doubleValue = maximum.x > 0
            ? Double(virtualOffset.x / maximum.x) : 0
        verticalScroller.doubleValue = maximum.y > 0
            ? Double(virtualOffset.y / maximum.y) : 0
        horizontalScroller.isEnabled = maximum.x > 0
        verticalScroller.isEnabled = maximum.y > 0
    }

    private func updateVisibleRange() {
        guard let rows = model?.rows, !rows.isEmpty, grid.bounds.height > 0 else { return }
        let first = min(rows.count - 1,
            max(0, Int(floor(virtualOffset.y / Self.rowHeight))))
        let last = min(rows.count,
            max(first + 1, Int(ceil((virtualOffset.y + grid.bounds.height) / Self.rowHeight))))
        let range = first..<last
        if range != lastVisibleRange {
            lastVisibleRange = range
            onVisibleRangeChanged?(range)
        }
    }

    private func moveSelection(horizontal: Int, vertical: Int) {
        guard let rows = model?.rows, !rows.isEmpty else { return }
        let current = selectedProgrammeIndexPath
        var section = current?.section ?? 0
        var item = current?.item ?? 0
        if vertical == 0 {
            let count = rows[section].programmes.count
            guard count > 0 else { return }
            item = min(max(0, item + horizontal), count - 1)
        } else {
            let sourceDate: Date
            if rows[section].programmes.indices.contains(item) {
                let value = rows[section].programmes[item]
                sourceDate = midpoint(value)
            } else {
                sourceDate = model?.windowStart ?? Date()
            }
            var target = section + vertical
            while rows.indices.contains(target), rows[target].programmes.isEmpty {
                target += vertical
            }
            guard rows.indices.contains(target), !rows[target].programmes.isEmpty else { return }
            section = target
            item = rows[section].programmes.enumerated().min { left, right in
                abs(midpoint(left.element).timeIntervalSince(sourceDate))
                    < abs(midpoint(right.element).timeIntervalSince(sourceDate))
            }?.offset ?? 0
        }
        selectProgramme(item: item, section: section, activate: false)
        scrollSelectedProgrammeToVisible()
    }

    private func activateSelection() {
        guard let indexPath = selectedProgrammeIndexPath,
              let rows = model?.rows, rows.indices.contains(indexPath.section),
              rows[indexPath.section].programmes.indices.contains(indexPath.item) else { return }
        onProgrammeActivated?(rows[indexPath.section], rows[indexPath.section].programmes[indexPath.item])
    }

    private func selectProgramme(item: Int, section: Int, activate: Bool) {
        guard let rows = model?.rows, rows.indices.contains(section),
              rows[section].programmes.indices.contains(item) else { return }
        selectedProgrammeIndexPath = IndexPath(item: item, section: section)
        window?.makeFirstResponder(grid)
        grid.selectedProgrammeID = rows[section].programmes[item].id
        let row = rows[section]
        let programme = row.programmes[item]
        onProgrammeSelected?(row, programme)
        if activate { onProgrammeActivated?(row, programme) }
    }

    private func scrollSelectedProgrammeToVisible() {
        guard let selectedProgrammeIndexPath,
              let model, model.rows.indices.contains(selectedProgrammeIndexPath.section),
              model.rows[selectedProgrammeIndexPath.section].programmes.indices
                .contains(selectedProgrammeIndexPath.item) else { return }
        let programme = model.rows[selectedProgrammeIndexPath.section]
            .programmes[selectedProgrammeIndexPath.item]
        let start = max(0, programme.start.timeIntervalSince(model.windowStart))
        let end = min(model.windowEnd.timeIntervalSince(model.windowStart),
                      programme.end.timeIntervalSince(model.windowStart))
        let x = CGFloat(start / 3_600) * grid.pointsPerHour
        let width = max(Self.minimumProgrammeWidth,
                        CGFloat(max(0, end - start) / 3_600) * grid.pointsPerHour - 2)
        let y = CGFloat(selectedProgrammeIndexPath.section) * Self.rowHeight
        var proposed = virtualOffset
        if x < proposed.x { proposed.x = x }
        if x + width > proposed.x + grid.bounds.width {
            proposed.x = x + width - grid.bounds.width
        }
        if y < proposed.y { proposed.y = y }
        if y + Self.rowHeight > proposed.y + grid.bounds.height {
            proposed.y = y + Self.rowHeight - grid.bounds.height
        }
        setVirtualOffset(proposed)
    }

    private func midpoint(_ value: LiveGuideGridProgramme) -> Date {
        value.start.addingTimeInterval(value.end.timeIntervalSince(value.start) / 2)
    }

    private static func layoutPointsPerHour(for model: LiveGuideGridModel) -> CGFloat {
        let shortest = model.rows.lazy.flatMap(\.programmes).reduce(nil as TimeInterval?) {
            current, programme in
            let clippedStart = max(programme.start, model.windowStart)
            let clippedEnd = min(programme.end, model.windowEnd)
            let duration = clippedEnd.timeIntervalSince(clippedStart)
            guard duration > 0 else { return current }
            return min(current ?? duration, duration)
        }
        guard let shortest else { return pointsPerHour }
        return max(pointsPerHour, minimumProgrammeWidth * 3_600 / CGFloat(shortest))
    }
}

private struct LiveGuideVisibleProgramme {
    let rowIndex: Int
    let programmeIndex: Int
    let row: LiveGuideGridRow
    let programme: LiveGuideGridProgramme
    let frame: NSRect
    let timeRange: String
}

/// A fixed-size viewport whose backing surface is bounded by the window.
/// It virtualizes rows and time horizontally using `virtualOffset`; the
/// potentially very large logical guide never becomes an AppKit view or layer.
private final class LiveGuideViewportView: NSCollectionView {
    private(set) var rows: [LiveGuideGridRow] = []
    private(set) var windowStart = Date()
    private(set) var windowEnd = Date()
    private(set) var pointsPerHour = LiveGuideGridView.pointsPerHour
    private var timeZone = TimeZone.current
    var now = Date()
    var virtualOffset = NSPoint.zero { didSet { needsDisplay = true } }
    var selectedProgrammeID: EPGProgrammeRecordIdentity? {
        didSet { if oldValue != selectedProgrammeID { needsDisplay = true } }
    }
    var onMoveSelection: ((Int, Int) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onSelectProgramme: ((Int, Int, Bool) -> Void)?
    var onScroll: ((NSPoint) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundColors = [.clear]
        isSelectable = false
        setAccessibilityElement(true)
        setAccessibilityRole(.grid)
        setAccessibilityLabel("Programme schedule")
    }

    required init?(coder: NSCoder) { nil }

    func configure(rows: [LiveGuideGridRow], windowStart: Date, windowEnd: Date,
                   pointsPerHour: CGFloat, timeZone: TimeZone, now: Date) {
        self.rows = rows
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.pointsPerHour = pointsPerHour
        self.timeZone = timeZone
        self.now = now
        selectedProgrammeID = nil
        needsDisplay = true
    }

    var visibleProgrammeCount: Int { visibleProgrammes().count }
    var visibleAccessibilityLabels: [String] {
        visibleProgrammes().map { "\($0.row.title), \($0.programme.title)" }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for value in visibleProgrammes() where value.frame.intersects(dirtyRect) {
            let selected = value.programme.id == selectedProgrammeID
            let background = selected ? NSColor.controlAccentColor : NSColor.controlBackgroundColor
            background.setFill()
            NSBezierPath(roundedRect: value.frame, xRadius: 7, yRadius: 7).fill()
            let foreground = selected
                ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor
            let secondary = selected
                ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor
            value.programme.title.draw(
                in: NSRect(x: value.frame.minX + 10, y: value.frame.minY + 8,
                           width: max(0, value.frame.width - 20), height: 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                 .foregroundColor: foreground,
                                 .paragraphStyle: paragraph]
            )
            value.timeRange.draw(
                in: NSRect(x: value.frame.minX + 10, y: value.frame.minY + 31,
                           width: max(0, value.frame.width - 20), height: 16),
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(
                                     ofSize: 10, weight: .regular),
                                 .foregroundColor: secondary,
                                 .paragraphStyle: paragraph]
            )
        }
        if windowStart <= now, now <= windowEnd {
            let x = CGFloat(now.timeIntervalSince(windowStart) / 3_600)
                * pointsPerHour - virtualOffset.x
            if bounds.minX...bounds.maxX ~= x {
                NSColor.systemRed.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 1
                path.move(to: NSPoint(x: x, y: dirtyRect.minY))
                path.line(to: NSPoint(x: x, y: dirtyRect.maxY))
                path.stroke()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onMoveSelection?(-1, 0)
        case 124: onMoveSelection?(1, 0)
        case 125: onMoveSelection?(0, 1)
        case 126: onMoveSelection?(0, -1)
        case 36, 49: onActivateSelection?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let value = visibleProgrammes().last(where: { $0.frame.contains(point) }) else {
            return super.mouseDown(with: event)
        }
        onSelectProgramme?(value.programmeIndex, value.rowIndex, event.clickCount >= 2)
    }

    override func scrollWheel(with event: NSEvent) {
        let horizontal = event.hasPreciseScrollingDeltas
            ? -event.scrollingDeltaX : -event.deltaX * 12
        let vertical = event.hasPreciseScrollingDeltas
            ? -event.scrollingDeltaY : -event.deltaY * 12
        if event.modifierFlags.contains(.shift), abs(vertical) > abs(horizontal) {
            onScroll?(NSPoint(x: vertical, y: 0))
        } else {
            onScroll?(NSPoint(x: horizontal, y: vertical))
        }
    }

    override func accessibilityChildren() -> [Any]? {
        visibleProgrammes().map { value in
            let element = LiveGuideProgrammeAccessibilityElement { [weak self] in
                self?.onSelectProgramme?(value.programmeIndex, value.rowIndex, true)
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("\(value.row.title), \(value.programme.title)")
            element.setAccessibilityValue(value.timeRange)
            let windowFrame = convert(value.frame, to: nil)
            element.setAccessibilityFrame(window?.convertToScreen(windowFrame) ?? .zero)
            return element
        }
    }

    private func visibleProgrammes() -> [LiveGuideVisibleProgramme] {
        guard !rows.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let firstRow = max(0, Int(floor(virtualOffset.y / LiveGuideGridView.rowHeight)))
        let lastRow = min(rows.count - 1,
            Int(floor((virtualOffset.y + bounds.height - 0.001)
                / LiveGuideGridView.rowHeight)))
        guard firstRow <= lastRow else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let minimumX = virtualOffset.x
        let maximumX = virtualOffset.x + bounds.width
        var result: [LiveGuideVisibleProgramme] = []
        result.reserveCapacity((lastRow - firstRow + 1) * 12)
        for rowIndex in firstRow...lastRow {
            let row = rows[rowIndex]
            for (programmeIndex, programme) in row.programmes.enumerated() {
                let clippedStart = max(windowStart, programme.start)
                let clippedEnd = min(windowEnd, programme.end)
                guard clippedStart < clippedEnd else { continue }
                let startX = CGFloat(clippedStart.timeIntervalSince(windowStart) / 3_600)
                    * pointsPerHour
                let durationWidth = CGFloat(clippedEnd.timeIntervalSince(clippedStart) / 3_600)
                    * pointsPerHour
                let width = max(LiveGuideGridView.minimumProgrammeWidth, durationWidth - 2)
                guard startX + width >= minimumX, startX <= maximumX else { continue }
                let frame = NSRect(
                    x: startX - virtualOffset.x,
                    y: CGFloat(rowIndex) * LiveGuideGridView.rowHeight - virtualOffset.y + 2,
                    width: width,
                    height: LiveGuideGridView.rowHeight - 4
                ).intersection(bounds)
                guard !frame.isNull, !frame.isEmpty else { continue }
                result.append(LiveGuideVisibleProgramme(
                    rowIndex: rowIndex, programmeIndex: programmeIndex,
                    row: row, programme: programme, frame: frame,
                    timeRange: "\(formatter.string(from: programme.start))–\(formatter.string(from: programme.end))"
                ))
            }
        }
        return result
    }
}

struct LiveGuideGridRepresentable: NSViewRepresentable {
    let model: LiveGuideGridModel
    let now: Date
    let onProgrammeSelected: (LiveGuideGridRow, LiveGuideGridProgramme) -> Void
    let onProgrammeActivated: (LiveGuideGridRow, LiveGuideGridProgramme) -> Void
    let onChannelActivated: (LiveGuideGridRow) -> Void
    let onVisibleRangeChanged: (Range<Int>) -> Void

    final class Coordinator {
        var model: LiveGuideGridModel?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LiveGuideGridView {
        let view = LiveGuideGridView()
        connect(view)
        return view
    }

    func updateNSView(_ view: LiveGuideGridView, context: Context) {
        connect(view)
        if context.coordinator.model != model {
            context.coordinator.model = model
            view.apply(model, now: now)
        } else {
            view.updateNow(now)
        }
    }

    private func connect(_ view: LiveGuideGridView) {
        view.onProgrammeSelected = onProgrammeSelected
        view.onProgrammeActivated = onProgrammeActivated
        view.onChannelActivated = onChannelActivated
        view.onVisibleRangeChanged = onVisibleRangeChanged
    }
}

private final class LiveGuideProgrammeAccessibilityElement: NSAccessibilityElement {
    private let press: () -> Void

    init(press: @escaping () -> Void) {
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

private final class LiveGuideTimeHeaderView: NSView {
    private var start = Date()
    private var end = Date()
    private var timeZone = TimeZone.current
    private var pointsPerHour: CGFloat = 180
    private var ticks: [LiveGuideTimeAxisTick] = []
    var horizontalOffset: CGFloat = 0 { didSet { needsDisplay = true } }
    var cachedLabelCount: Int { ticks.count }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Time axis")
    }
    required init?(coder: NSCoder) { nil }

    func configure(start: Date, end: Date, timeZone: TimeZone, pointsPerHour: CGFloat) {
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.pointsPerHour = pointsPerHour
        ticks = LiveGuideTimeAxisFormatter.ticks(from: start, to: end, timeZone: timeZone)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        for tick in ticks {
            let x = CGFloat(tick.date.timeIntervalSince(start) / 3600) * pointsPerHour
                - horizontalOffset
            guard x >= dirtyRect.minX - 100, x <= dirtyRect.maxX + 10 else { continue }
            tick.label.draw(at: NSPoint(x: x + 6, y: 13), withAttributes: attributes)
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: bounds.maxY - 8))
            path.line(to: NSPoint(x: x, y: bounds.maxY))
            path.stroke()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: 0, y: bounds.maxY - 0.5),
                                to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
    }
}

private final class LiveGuideChannelHeaderView: NSView {
    var rows: [LiveGuideGridRow] = [] { didSet { needsDisplay = true } }
    var verticalOffset: CGFloat = 0 { didSet { needsDisplay = true } }
    var onChannelActivated: ((LiveGuideGridRow) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Channels")
    }
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount >= 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(floor((point.y + verticalOffset) / LiveGuideGridView.rowHeight))
        guard rows.indices.contains(index) else { return }
        onChannelActivated?(rows[index])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let first = max(0, Int(floor((dirtyRect.minY + verticalOffset) / LiveGuideGridView.rowHeight)))
        let last = min(rows.count - 1,
            Int(floor((dirtyRect.maxY + verticalOffset) / LiveGuideGridView.rowHeight)))
        guard first <= last, !rows.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for index in first...last {
            let y = CGFloat(index) * LiveGuideGridView.rowHeight - verticalOffset
            let row = rows[index]
            let title: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ]
            row.title.draw(in: NSRect(x: 12, y: y + 13, width: bounds.width - 24, height: 19),
                           withAttributes: title)
            if let subtitle = row.subtitle {
                subtitle.draw(in: NSRect(x: 12, y: y + 34, width: bounds.width - 24, height: 16),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                     .foregroundColor: NSColor.secondaryLabelColor,
                                     .paragraphStyle: paragraph])
            }
            NSColor.separatorColor.setStroke()
            NSBezierPath.strokeLine(from: NSPoint(x: 0, y: y + LiveGuideGridView.rowHeight - 0.5),
                                    to: NSPoint(x: bounds.maxX, y: y + LiveGuideGridView.rowHeight - 0.5))
        }
    }
}
