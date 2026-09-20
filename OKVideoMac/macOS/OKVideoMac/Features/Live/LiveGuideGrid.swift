import AppKit
import OKVideoCore

struct LiveGuideGridProgramme: Equatable, Identifiable {
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

struct LiveGuideGridRow: Equatable, Identifiable {
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

struct LiveGuideGridModel: Equatable {
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

final class LiveGuideGridView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let rowHeight: CGFloat = 64
    static let timeHeaderHeight: CGFloat = 42
    static let channelColumnWidth: CGFloat = 188
    static let pointsPerHour: CGFloat = 180

    private let cornerLabel = NSTextField(labelWithString: "Program Guide")
    private let timeHeader = LiveGuideTimeHeaderView()
    private let channelHeader = LiveGuideChannelHeaderView()
    private let scrollView = NSScrollView()
    private let grid = LiveGuideCollectionView()
    private let gridLayout = LiveGuideCollectionLayout()
    private let itemIdentifier = NSUserInterfaceItemIdentifier("LiveGuideProgrammeItem")
    private var boundsObserver: NSObjectProtocol?
    private(set) var model: LiveGuideGridModel?
    private var maximumVisibleProgrammeViews = 0
    private var realizedProgrammeViews: Set<ObjectIdentifier> = []
    var onProgrammeActivated: ((LiveGuideGridRow, LiveGuideGridProgramme) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        cornerLabel.alignment = .left
        cornerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        cornerLabel.lineBreakMode = .byTruncatingTail
        cornerLabel.setAccessibilityRole(.staticText)
        cornerLabel.setAccessibilityLabel("Program Guide")

        grid.collectionViewLayout = gridLayout
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = false
        grid.backgroundColors = [.clear]
        grid.register(LiveGuideProgrammeItem.self, forItemWithIdentifier: itemIdentifier)
        grid.onMoveSelection = { [weak self] horizontal, vertical in
            self?.moveSelection(horizontal: horizontal, vertical: vertical)
        }
        grid.onActivateSelection = { [weak self] in self?.activateSelection() }
        grid.setAccessibilityRole(.grid)
        grid.setAccessibilityLabel("Programme schedule")

        scrollView.documentView = grid
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeFixedViews() }
        }

        addSubview(cornerLabel)
        addSubview(timeHeader)
        addSubview(channelHeader)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    override func layout() {
        super.layout()
        let headerHeight = min(Self.timeHeaderHeight, bounds.height)
        let columnWidth = min(Self.channelColumnWidth, bounds.width)
        cornerLabel.frame = NSRect(x: 12, y: 0, width: max(0, columnWidth - 20), height: headerHeight)
        timeHeader.frame = NSRect(x: columnWidth, y: 0,
                                  width: max(0, bounds.width - columnWidth), height: headerHeight)
        channelHeader.frame = NSRect(x: 0, y: headerHeight, width: columnWidth,
                                     height: max(0, bounds.height - headerHeight))
        scrollView.frame = NSRect(x: columnWidth, y: headerHeight,
                                  width: max(0, bounds.width - columnWidth),
                                  height: max(0, bounds.height - headerHeight))
        gridLayout.invalidateLayout()
        synchronizeFixedViews()
    }

    func apply(_ model: LiveGuideGridModel, now: Date = Date()) {
        self.model = model
        grid.rows = model.rows
        grid.windowStart = model.windowStart
        grid.windowEnd = model.windowEnd
        grid.now = now
        gridLayout.rows = model.rows
        gridLayout.windowStart = model.windowStart
        gridLayout.windowEnd = model.windowEnd
        timeHeader.configure(start: model.windowStart, end: model.windowEnd,
                             timeZone: model.timeZone, pointsPerHour: Self.pointsPerHour)
        channelHeader.rows = model.rows
        grid.reloadData()
        gridLayout.invalidateLayout()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        maximumVisibleProgrammeViews = 0
        realizedProgrammeViews.removeAll(keepingCapacity: true)
        synchronizeFixedViews()
    }

    func updateNow(_ date: Date) {
        grid.now = date
        grid.needsDisplay = true
    }

    func scroll(to point: NSPoint) {
        let documentSize = gridLayout.collectionViewContentSize
        let viewport = scrollView.contentView.bounds.size
        let clamped = NSPoint(x: min(max(0, point.x), max(0, documentSize.width - viewport.width)),
                              y: min(max(0, point.y), max(0, documentSize.height - viewport.height)))
        scrollView.contentView.scroll(to: clamped)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        synchronizeFixedViews()
        grid.layoutSubtreeIfNeeded()
    }

    var scrollOffset: NSPoint { scrollView.contentView.bounds.origin }

    var debugFixedFrames: LiveGuideGridFixedFrames {
        LiveGuideGridFixedFrames(corner: cornerLabel.frame, timeHeader: timeHeader.frame,
                                 channelHeader: channelHeader.frame, content: scrollView.frame)
    }

    var debugSelectedIndexPath: IndexPath? { grid.selectionIndexPaths.first }

    var debugNowLineX: CGFloat? {
        guard let model, model.windowStart <= grid.now, grid.now <= model.windowEnd else { return nil }
        return CGFloat(grid.now.timeIntervalSince(model.windowStart) / 3600) * Self.pointsPerHour
    }

    var debugVisibleAccessibilityLabels: [String] {
        grid.visibleItems().compactMap { $0.view.accessibilityLabel() }
    }

    func debugSelect(item: Int, section: Int) {
        let indexPath = IndexPath(item: item, section: section)
        grid.selectionIndexPaths = [indexPath]
    }

    func debugMoveSelection(horizontal: Int, vertical: Int) {
        moveSelection(horizontal: horizontal, vertical: vertical)
    }

    func debugActivateSelection() {
        activateSelection()
    }

    var debugMetrics: LiveGuideGridDebugMetrics {
        let visible = grid.visibleItems().count
        maximumVisibleProgrammeViews = max(maximumVisibleProgrammeViews, visible)
        return LiveGuideGridDebugMetrics(
            totalProgrammes: model?.rows.reduce(0, { $0 + $1.programmes.count }) ?? 0,
            visibleProgrammeViews: visible,
            realizedProgrammeViews: realizedProgrammeViews.count,
            maximumVisibleProgrammeViews: maximumVisibleProgrammeViews,
            emittedLayoutAttributes: gridLayout.lastEmittedAttributeCount,
            cachedTimeLabels: timeHeader.cachedLabelCount)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        model?.rows.count ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        guard let rows = model?.rows, rows.indices.contains(section) else { return 0 }
        return rows[section].programmes.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath)
        guard let item = item as? LiveGuideProgrammeItem,
              let row = model?.rows[indexPath.section],
              row.programmes.indices.contains(indexPath.item) else { return item }
        realizedProgrammeViews.insert(ObjectIdentifier(item))
        item.configure(programme: row.programmes[indexPath.item], channelTitle: row.title,
                       timeZone: model?.timeZone ?? .current)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        maximumVisibleProgrammeViews = max(maximumVisibleProgrammeViews,
                                           collectionView.visibleItems().count)
    }

    private func synchronizeFixedViews() {
        let offset = scrollView.contentView.bounds.origin
        timeHeader.horizontalOffset = offset.x
        channelHeader.verticalOffset = offset.y
        maximumVisibleProgrammeViews = max(maximumVisibleProgrammeViews,
                                           grid.visibleItems().count)
    }

    private func moveSelection(horizontal: Int, vertical: Int) {
        guard let rows = model?.rows, !rows.isEmpty else { return }
        let current = grid.selectionIndexPaths.first
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
                sourceDate = value.start.addingTimeInterval(value.end.timeIntervalSince(value.start) / 2)
            } else {
                sourceDate = model?.windowStart ?? Date()
            }
            var target = section + vertical
            while rows.indices.contains(target), rows[target].programmes.isEmpty { target += vertical }
            guard rows.indices.contains(target), !rows[target].programmes.isEmpty else { return }
            section = target
            item = rows[section].programmes.enumerated().min { left, right in
                abs(midpoint(left.element).timeIntervalSince(sourceDate))
                    < abs(midpoint(right.element).timeIntervalSince(sourceDate))
            }?.offset ?? 0
        }
        let destination = IndexPath(item: item, section: section)
        grid.selectionIndexPaths = [destination]
        grid.scrollToItems(at: [destination], scrollPosition: [.centeredHorizontally, .centeredVertically])
    }

    private func activateSelection() {
        guard let indexPath = grid.selectionIndexPaths.first,
              let rows = model?.rows, rows.indices.contains(indexPath.section),
              rows[indexPath.section].programmes.indices.contains(indexPath.item) else { return }
        onProgrammeActivated?(rows[indexPath.section], rows[indexPath.section].programmes[indexPath.item])
    }

    private func midpoint(_ value: LiveGuideGridProgramme) -> Date {
        value.start.addingTimeInterval(value.end.timeIntervalSince(value.start) / 2)
    }
}

private final class LiveGuideCollectionLayout: NSCollectionViewLayout {
    var rows: [LiveGuideGridRow] = []
    var windowStart = Date()
    var windowEnd = Date()
    private(set) var lastEmittedAttributeCount = 0

    override var collectionViewContentSize: NSSize {
        let hours = max(0, windowEnd.timeIntervalSince(windowStart) / 3600)
        return NSSize(width: CGFloat(hours) * LiveGuideGridView.pointsPerHour,
                      height: CGFloat(rows.count) * LiveGuideGridView.rowHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard !rows.isEmpty else { lastEmittedAttributeCount = 0; return [] }
        let first = max(0, Int(floor(rect.minY / LiveGuideGridView.rowHeight)))
        let last = min(rows.count - 1, Int(floor(rect.maxY / LiveGuideGridView.rowHeight)))
        guard first <= last else { lastEmittedAttributeCount = 0; return [] }
        var result: [NSCollectionViewLayoutAttributes] = []
        for section in first...last {
            for item in rows[section].programmes.indices {
                let indexPath = IndexPath(item: item, section: section)
                let frame = frameForItem(at: indexPath)
                if frame.intersects(rect) {
                    let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
                    attributes.frame = frame
                    result.append(attributes)
                } else if frame.minX > rect.maxX {
                    break
                }
            }
        }
        lastEmittedAttributeCount = result.count
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath)
        -> NSCollectionViewLayoutAttributes? {
        guard rows.indices.contains(indexPath.section),
              rows[indexPath.section].programmes.indices.contains(indexPath.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frameForItem(at: indexPath)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { false }

    private func frameForItem(at indexPath: IndexPath) -> NSRect {
        let item = rows[indexPath.section].programmes[indexPath.item]
        let start = max(0, item.start.timeIntervalSince(windowStart))
        let end = min(windowEnd.timeIntervalSince(windowStart),
                      item.end.timeIntervalSince(windowStart))
        let x = CGFloat(start / 3600) * LiveGuideGridView.pointsPerHour
        let durationWidth = CGFloat(max(0, end - start) / 3600) * LiveGuideGridView.pointsPerHour
        return NSRect(x: x, y: CGFloat(indexPath.section) * LiveGuideGridView.rowHeight + 2,
                      width: max(44, durationWidth - 2), height: LiveGuideGridView.rowHeight - 4)
    }
}

private final class LiveGuideCollectionView: NSCollectionView {
    var rows: [LiveGuideGridRow] = []
    var windowStart = Date()
    var windowEnd = Date()
    var now = Date()
    var onMoveSelection: ((Int, Int) -> Void)?
    var onActivateSelection: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard windowStart <= now, now <= windowEnd else { return }
        let seconds = now.timeIntervalSince(windowStart)
        let x = CGFloat(seconds / 3600) * LiveGuideGridView.pointsPerHour
        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: x, y: dirtyRect.minY))
        path.line(to: NSPoint(x: x, y: dirtyRect.maxY))
        path.stroke()
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
}

private final class LiveGuideProgrammeItem: NSCollectionViewItem {
    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 7
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        view.addSubview(titleLabel)
        view.addSubview(timeLabel)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        titleLabel.frame = NSRect(x: 10, y: 8, width: max(0, view.bounds.width - 20), height: 20)
        timeLabel.frame = NSRect(x: 10, y: 31, width: max(0, view.bounds.width - 20), height: 16)
    }

    override var isSelected: Bool {
        didSet { updateColors() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.stringValue = ""
        timeLabel.stringValue = ""
        view.setAccessibilityLabel(nil)
        view.setAccessibilityValue(nil)
    }

    func configure(programme: LiveGuideGridProgramme, channelTitle: String, timeZone: TimeZone) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let range = "\(formatter.string(from: programme.start))–\(formatter.string(from: programme.end))"
        titleLabel.stringValue = programme.title
        timeLabel.stringValue = range
        view.setAccessibilityLabel("\(channelTitle), \(programme.title)")
        view.setAccessibilityValue(range)
        updateColors()
    }

    private func updateColors() {
        view.layer?.backgroundColor = (isSelected
            ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).cgColor
        titleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        timeLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
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
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Channels")
    }
    required init?(coder: NSCoder) { nil }

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
