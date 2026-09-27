import AppKit
import SwiftUI
import XCTest
import OKVideoCore
import OKVideoPersistence
@testable import OKVideoMac

@MainActor
final class HistoryNativeRepairTests: XCTestCase {
    func testContentRowSeparatorsRenderWithoutEmptyViewportGrid() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rows = (0..<3).map { NativeLibraryRow(id: "\($0)", title: "影片 \($0)", subtitle: "来源 · 第34集", posterURL: nil, date: Date()) }
            let host = NSHostingView(rootView: NativeLibraryList(rows: rows, selection: .constant(["1"]), repository: nil,
                openTitle: "播放", onOpen: { _ in }, onDelete: { _, _ in }))
            let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 700, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            defer { window.close() }
            try await Task.sleep(nanoseconds: 60_000_000)
            host.layoutSubtreeIfNeeded()
            let table = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NativeLibraryTableView }.first)
            XCTAssertTrue(table.gridStyleMask.isEmpty, "Empty space must not receive phantom row grid lines")
            for index in rows.indices {
                let row = try XCTUnwrap(table.rowView(atRow: index, makeIfNecessary: true) as? NativeLibrarySelectionRowView)
                row.setBrowserHovered(index == 2)
                row.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                row.cacheDisplay(in: row.bounds, to: bitmap)
                // Full-width tables extend the row beyond the clipped viewport.
                // Sample its visible center, not the clipped outer margin.
                let x = bitmap.pixelsWide / 2
                let middle = try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                let edge = [0, 1, bitmap.pixelsHigh - 2, bitmap.pixelsHigh - 1].compactMap {
                    bitmap.colorAt(x: x, y: $0)?.usingColorSpace(.deviceRGB)
                }
                XCTAssertTrue(edge.contains {
                    abs($0.redComponent - middle.redComponent) > 0.025 ||
                    abs($0.alphaComponent - middle.alphaComponent) > 0.025
                },
                    "Separator must be visible for regular, selected, and hovered rows in \(appearance)")
            }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: "/private/tmp/ok127-separators-\(appearance.rawValue).png"))
        }
    }
    private func fixture() throws -> (AppState, AppEnvironment, StoredConfiguration) {
        let environment = try AppEnvironment.live()
        let configuration = StoredConfiguration(name: "Fixture", sourceKind: .pasted, rawData: Data("{}".utf8))
        return (AppState(environment: environment), environment, configuration)
    }
    func testPeriodicWritePublishesAndCloseCapturesLastSeconds() async throws {
        let (state, environment, configuration) = try fixture()
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 3.8, duration: 2809)
        state.changeHistoryProgressForTesting(position: 4.8, duration: 2809)
        await state.finishHistoryForTesting()
        XCTAssertEqual(state.history.first?.position, 4.8)
        XCTAssertNotNil(HistoryView.displayedProgress(position: state.history[0].position, duration: state.history[0].duration))
        state.changeHistoryProgressForTesting(position: 5.2, duration: 2809)
        await state.closePlayer()
        let saved = try await environment.database.history()
        XCTAssertEqual(saved.first?.position, 5.2)
        XCTAssertEqual(state.history.first?.position, 5.2)
    }
    func testApplicationShutdownPersistsBeforeInvalidatingOwnership() async throws {
        let (state, environment, configuration) = try fixture()
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 3.4, duration: 100)
        await state.shutdown()
        let records = try await environment.database.history()
        XCTAssertEqual(records.first?.position, 3.4)
    }
    func testDeletionSuppressesQueuedAndFutureWritesAcrossQualitySwitch() async throws {
        let (state, environment, configuration) = try fixture()
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 10, duration: 100)
        await state.persistPlaybackProgress()
        let records = state.history
        state.changeHistoryProgressForTesting(position: 11, duration: 100)
        let success = await state.deleteHistory(records: records)
        XCTAssertTrue(success)
        state.qualityOwnershipForTesting()
        state.changeHistoryProgressForTesting(position: 12, duration: 100)
        await state.persistPlaybackProgress()
        await state.closePlayer()
        let saved = try await environment.database.history()
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(state.history.isEmpty)
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 2, duration: 100)
        await state.persistPlaybackProgress()
        let restarted = try await environment.database.history()
        XCTAssertEqual(restarted.first?.position, 2)
    }
    func testRapidTransitionPreservesEachImmutableFinalWrite() async throws {
        let (state, environment, configuration) = try fixture()
        for index in 1...3 {
            state.seedHistoryPlaybackForTesting(configuration: configuration, videoID: "video\(index)", position: Double(index), duration: 100)
            state.transitionHistoryForTesting()
        }
        await state.finishHistoryForTesting()
        let records = try await environment.database.history()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(Set(records.map(\.position)), [1, 2, 3])
    }
    func testQualityTransferKeepsCheckpointAndAllowsRewind() async throws {
        let (state, environment, configuration) = try fixture()
        state.seedHistoryPlaybackForTesting(configuration: configuration, position: 80, duration: 100)
        await state.persistPlaybackProgress()
        state.qualityOwnershipForTesting()
        state.changeHistoryProgressForTesting(position: 30, duration: 100)
        await state.persistPlaybackProgress()
        let records = try await environment.database.history()
        XCTAssertEqual(records.first?.position, 30)
    }
    func testUnknownAndNonfiniteProgressHasSafeText() {
        XCTAssertNil(HistoryView.displayedProgress(position: .nan, duration: 100))
        XCTAssertNil(HistoryView.displayedProgress(position: 12, duration: .infinity))
        XCTAssertTrue(HistoryView.progressText(position: 12, duration: 0).contains("00:12"))
        XCTAssertEqual(HistoryView.displayedProgress(position: 300, duration: 100), 1)
        var checkpoint = PlayerHistoryProgressCheckpoint(); let owner = UUID()
        checkpoint.reset(owner: owner)
        checkpoint.observe(.init(status: .playing, position: 5, duration: 0), owner: owner)
        XCTAssertEqual(checkpoint.resolve(position: 0, duration: 0, reliable: false, owner: owner)?.position, 5)
        XCTAssertNil(checkpoint.resolve(position: 9, duration: 10, reliable: true, owner: UUID()))
    }
    func testDeleteTransactionRollsBackHistoryWhenMarkersAreMalformed() async throws {
        let (_, environment, configuration) = try fixture()
        let store = environment.database
        let a = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "a", title: "A")
        let b = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "b", title: "B")
        try await store.saveHistory(a, incognito: false); try await store.saveHistory(b, incognito: false)
        try await store.setSetting(.string("invalid json"), forKey: "playback.completionMarkers.v1")
        let session = UUID()
        do { try await store.deleteWatchedHistory([a,b], suppressing: [session]); XCTFail("must fail") } catch {}
        let unchanged = try await store.history()
        XCTAssertEqual(Set(unchanged.map(\.id)), [a.id,b.id])
        var next = a; next.position = 4; next.watchedAt = Date().addingTimeInterval(1)
        let wrote = try await store.saveWatchedHistory(next, replacing: nil, sessionID: session)
        XCTAssertTrue(wrote, "failed deletion must not suppress the session")
    }
    func testDeleteOriginalIdentityAlsoDeletesCommittedReplacement() async throws {
        let (_, environment, configuration) = try fixture()
        let store = environment.database, session = UUID()
        let original = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "old", title: "A")
        let replacement = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "resolved", title: "A")
        try await store.saveHistory(original, incognito: false)
        _ = try await store.saveWatchedHistory(replacement, replacing: original, sessionID: session)
        try await store.deleteWatchedHistory([original], suppressing: [session])
        let rows = try await store.history()
        XCTAssertTrue(rows.isEmpty)
        let saved = try await store.saveWatchedHistory(replacement, replacing: original, sessionID: session)
        XCTAssertFalse(saved)
    }

    func testLateCheckpointCannotReplaceNewerEpisode() async throws {
        let (_, environment, configuration) = try fixture()
        let store = environment.database
        let a = HistoryRecord(configurationID: configuration.id, siteKey: "fixture", videoID: "a", title: "A", sourceName: "Line", episodeName: "E1", position: 80, duration: 100, watchedAt: Date(timeIntervalSince1970: 100))
        var b = a; b.episodeName = "E2"; b.position = 3; b.watchedAt = Date(timeIntervalSince1970: 200)
        _ = try await store.saveWatchedHistory(b, replacing: nil, sessionID: UUID())
        _ = try await store.saveWatchedHistory(a, replacing: nil, sessionID: UUID())
        let rows = try await store.history()
        XCTAssertEqual(rows.first?.episodeName, "E2"); XCTAssertEqual(rows.first?.position, 3)
    }
    func testNativeTableFillsWindowAndRetainsSelectionOnProgressRefresh() async throws {
        let first = NativeLibraryRow(id: "one", title: "Title", subtitle: "Source", posterURL: nil, date: Date(), progress: 0.2)
        var selected: Set<String> = ["one"]
        func root(_ row: NativeLibraryRow) -> NativeLibraryList {
            NativeLibraryList(rows: [row], selection: Binding(get: { selected }, set: { selected = $0 }), repository: nil,
                openTitle: "Open", onOpen: { _ in }, onDelete: { _, _ in })
        }
        let host = NSHostingView(rootView: root(first))
        let window = NSWindow(contentRect: .init(x: -2000, y: -2000, width: 950, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for width in [950.0, 500.0, 1200.0] {
            window.setContentSize(.init(width: width, height: 300))
            try await Task.sleep(nanoseconds: 30_000_000)
            host.layoutSubtreeIfNeeded()
            let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeLibraryTableView }.first)
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NativeLibraryCell)
            cell.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(cell.convert(cell.remove.bounds, from: cell.remove).maxX, width - 60)
            var updated = first; updated.progress = 0.8
            host.rootView = root(updated)
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
            XCTAssertEqual(selected, ["one"])
        }
    }

    func testLibrarySelectionAppearancePreservesKeyboardAndMultipleSelection() async throws {
        let rows = (0..<3).map { NativeLibraryRow(id: "\($0)", title: "影片 \($0 + 1) · 长标题布局检查", subtitle: "来源名称 · 第 12 集", posterURL: nil,
            date: Date(timeIntervalSince1970: 1_700_000_000), progress: 0.6, progressText: "18:00 / 30:00") }
        var selected: Set<String> = ["0", "1"]
        let host = NSHostingView(rootView: NativeLibraryList(rows: rows, selection: Binding(get: { selected }, set: { selected = $0 }),
            repository: nil, openTitle: "继续播放", onOpen: { _ in }, onDelete: { _, _ in }))
        final class AppearanceWindow: NSWindow {
            var presentsActive = true
            override var isKeyWindow: Bool { presentsActive }
        }
        let window = AppearanceWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 320), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let table = try XCTUnwrap(BrowserKeyboardView.descendants(of: host).compactMap { $0 as? NativeLibraryTableView }.first)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 1]))
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [500.0, 900.0] {
                window.setContentSize(.init(width: width, height: 320))
                try await Task.sleep(nanoseconds: 30_000_000)
                host.layoutSubtreeIfNeeded()
                let row = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true) as? NativeLibrarySelectionRowView)
                XCTAssertEqual(row.interiorBackgroundStyle, .normal)
                XCTAssertLessThanOrEqual(row.selectionRect.maxX, row.visibleRect.maxX - 9.5)
                let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NativeLibraryCell)
                cell.layoutSubtreeIfNeeded()
                XCTAssertEqual(cell.progress.frame.height, 2, accuracy: 0.01)
                XCTAssertGreaterThan(cell.remove.convert(cell.remove.bounds, to: cell).minX, 0)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/ok123-library-\(appearance.rawValue)-\(Int(width)).png"))
            }
        }
        window.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
        table.keyDown(with: down)
        XCTAssertTrue(table.showsKeyboardFocus)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(selected, ["1"])
        table.selectAll(nil)
        XCTAssertEqual(selected, ["0", "1", "2"])
        window.makeFirstResponder(nil)
        XCTAssertFalse(table.showsKeyboardFocus)
        window.presentsActive = false
        window.resignKey()
        XCTAssertEqual(selected.count, 3)
    }

    func testNativeButtonsOwnTheirEntireBoundsAndRetainStableTarget() {
        let cell = NativeLibraryCell(frame: .init(x: 0, y: 0, width: 900, height: 100))
        var removed: Set<String> = []; var opened = ""
        let row = NativeLibraryRow(id: "first", title: "First", subtitle: "Line", posterURL: nil, date: Date(), progress: 0.1, progressText: "00:10 / 01:40")
        cell.update(row, repository: nil, openTitle: "Open", onOpen: { opened = $0 }, onDelete: { ids, _ in removed = ids })
        cell.layoutSubtreeIfNeeded()
        let button = cell.remove
        for point in [NSPoint(x: 2, y: button.bounds.midY), NSPoint(x: button.bounds.maxX - 2, y: button.bounds.midY)] {
            XCTAssertTrue(button.hitTest(button.convert(point, to: button.superview)) === button)
        }
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        button.performClick(nil)
        XCTAssertEqual(removed, ["first"]); XCTAssertEqual(opened, "")
        cell.open.performClick(nil); XCTAssertEqual(opened, "first")
    }
}

@MainActor
final class BrowserHoverInteractionTests: XCTestCase {
    private final class Target: NSView, BrowserHoverTarget {
        var hovered = false
        var changes = 0
        func setBrowserHovered(_ value: Bool) {
            guard hovered != value else { return }
            hovered = value; changes += 1
        }
    }
    private final class Scroll: BrowserHoverScrollView {
        var pointerTarget: NSView?
        override func hoverTargetUnderMouse() -> NSView? { pointerTarget }
    }
    private func settled() async throws { try await Task.sleep(nanoseconds: 230_000_000) }

    func testTrackingOwnerReceivesAppKitSelectorsWithoutCallingRefreshDirectly() throws {
        let scroll = NSScrollView(), first = Target(), second = Target()
        let controller = BrowserHoverController.attached(to: scroll)
        var target: NSView? = first
        controller.resolveTarget = { target }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        for name in ["mouseEntered:", "mouseMoved:", "mouseExited:"] {
            XCTAssertTrue(controller.responds(to: NSSelectorFromString(name)), "Missing AppKit selector \(name)")
        }
        guard controller.responds(to: NSSelectorFromString("mouseEntered:")),
              controller.responds(to: NSSelectorFromString("mouseMoved:")),
              controller.responds(to: NSSelectorFromString("mouseExited:")) else { return }
        controller.perform(NSSelectorFromString("mouseEntered:"), with: event)
        XCTAssertTrue(first.hovered)
        target = second
        controller.perform(NSSelectorFromString("mouseMoved:"), with: event)
        XCTAssertFalse(first.hovered); XCTAssertTrue(second.hovered)
        controller.perform(NSSelectorFromString("mouseExited:"), with: event)
        XCTAssertFalse(second.hovered)
    }


    func testStationaryPointerRestoresOntoNewCardAfterWheelStops() async throws {
        let scroll = Scroll(), old = Target(), next = Target()
        scroll.pointerTarget = old; scroll.refreshBrowserHover()
        XCTAssertTrue(old.hovered)
        scroll.noteHoverScroll(phase: [], momentumPhase: [])
        XCTAssertFalse(old.hovered)
        scroll.pointerTarget = next; scroll.refreshBrowserHover()
        XCTAssertFalse(next.hovered)
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertTrue(scroll.hoverSuppressed)
        try await settled()
        XCTAssertTrue(next.hovered)
        XCTAssertFalse(old.hovered)
        XCTAssertEqual(old.changes, 2)
        XCTAssertEqual(next.changes, 1)
        scroll.resetBrowserHover()
    }

    func testGesturePauseAndMomentumNeverRestoreEarly() async throws {
        let scroll = Scroll(), card = Target()
        scroll.pointerTarget = card; scroll.refreshBrowserHover()
        scroll.noteHoverScroll(phase: .began, momentumPhase: [])
        try await settled()
        XCTAssertTrue(scroll.hoverSuppressed, "Finger held still must not restore hover")
        scroll.noteHoverScroll(phase: .ended, momentumPhase: [])
        scroll.noteHoverScroll(phase: [], momentumPhase: .began)
        try await settled()
        XCTAssertFalse(card.hovered)
        scroll.noteHoverScroll(phase: [], momentumPhase: .changed)
        scroll.noteHoverScroll(phase: [], momentumPhase: .ended)
        try await settled()
        XCTAssertTrue(card.hovered)
        scroll.resetBrowserHover()
    }

    func testRapidReverseAndScrollerDragRestartSettlement() async throws {
        let scroll = Scroll(), card = Target()
        scroll.pointerTarget = card; scroll.refreshBrowserHover()
        for _ in 0..<4 {
            scroll.noteHoverScroll(phase: [], momentumPhase: [])
            try await Task.sleep(nanoseconds: 65_000_000)
            XCTAssertFalse(card.hovered)
        }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        try await settled()
        XCTAssertFalse(card.hovered)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try await settled()
        XCTAssertTrue(card.hovered)
        scroll.resetBrowserHover()
    }

    func testViewportMoveReevaluatesPointerAndResetCancelsTimer() async throws {
        let scroll = Scroll(), card = Target()
        scroll.pointerTarget = card; scroll.refreshBrowserHover()
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertFalse(card.hovered)
        scroll.pointerTarget = nil
        try await settled()
        XCTAssertFalse(card.hovered)
        scroll.pointerTarget = card; scroll.refreshBrowserHover()
        scroll.noteHoverScroll(phase: .began, momentumPhase: [])
        scroll.noteHoverScroll(phase: .cancelled, momentumPhase: [])
        scroll.resetBrowserHover()
        try await settled()
        XCTAssertFalse(card.hovered, "Detached/closed surface must not restore its old target")
    }

    func testHoverOnlyTouchesOldAndNewTargets() {
        let scroll = Scroll(), old = Target(), next = Target()
        scroll.pointerTarget = old
        for _ in 0..<100 { scroll.refreshBrowserHover() }
        XCTAssertEqual(old.changes, 1)
        scroll.pointerTarget = next; scroll.refreshBrowserHover()
        XCTAssertEqual(old.changes, 2); XCTAssertEqual(next.changes, 1)
        scroll.resetBrowserHover()
        XCTAssertEqual(next.changes, 2)
    }

    func testScrollingPreservesPosterKeyboardHighlightAndLibrarySelection() async throws {
        let scroll = Scroll(), poster = PosterNativeCardView(frame: NSRect(x: 0, y: 0, width: 160, height: 280))
        poster.setKeyboardHighlighted(true)
        scroll.pointerTarget = poster; scroll.refreshBrowserHover()
        scroll.noteHoverScroll(phase: [], momentumPhase: [])
        XCTAssertEqual(poster.layer?.borderWidth, 1)
        try await settled()
        XCTAssertEqual(poster.layer?.borderWidth, 1)
        scroll.resetBrowserHover()
        poster.setKeyboardHighlighted(false)
        poster.setBrowserHovered(true)
        XCTAssertEqual(poster.layer?.borderWidth, 0, "Hover uses a quiet fill, not a selection outline")
        let row = NativeLibrarySelectionRowView(); row.isSelected = true
        let live = LiveChannelNativeCard(); live.selected = true
        for target in [row as NSView, live] {
            scroll.pointerTarget = target; scroll.refreshBrowserHover()
            scroll.noteHoverScroll(phase: [], momentumPhase: [])
        }
        XCTAssertTrue(row.isSelected); XCTAssertTrue(live.selected)
        scroll.resetBrowserHover()
    }
}

@MainActor
final class BrowserHoverSurfaceTests: XCTestCase {
    private final class Flipped: NSView { override var isFlipped: Bool { true } }
    func testNativeAndSwiftUICardHitTestingRespectsClippedViewport() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 280))
        let doc = Flipped(frame: NSRect(x: 0, y: 0, width: 400, height: 1000))
        scroll.documentView = doc
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        let card = PosterNativeCardView(frame: NSRect(x: 20, y: 30, width: 140, height: 240))
        doc.addSubview(card)
        let background = BrowserHoverBackground.Background(frame: NSRect(x: 200, y: 30, width: 140, height: 240))
        doc.addSubview(background)
        window.contentView?.layoutSubtreeIfNeeded()
        let controller = BrowserHoverController.attached(to: scroll)
        XCTAssertTrue(controller.hoverTarget(atWindowPoint: card.convert(NSPoint(x: 30, y: 40), to: nil)) === card, "hit=\(String(describing: controller.hoverTarget(atWindowPoint: card.convert(NSPoint(x: 30, y: 40), to: nil)))) doc=\(doc.frame) clip=\(scroll.contentView.bounds) card=\(card.frame) point=\(scroll.contentView.convert(card.convert(NSPoint(x: 30, y: 40), to: nil), from: nil)) direct=\(String(describing: card.hitTest(NSPoint(x: 50, y: 70))))")
        XCTAssertTrue(controller.hoverTarget(atWindowPoint: background.convert(NSPoint(x: 30, y: 40), to: nil)) === background)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 260))
        XCTAssertNil(controller.hoverTarget(atWindowPoint: card.convert(NSPoint(x: 30, y: 40), to: nil)), "Offscreen portion must not hover")
        background.detach()
        controller.resetBrowserHover()
    }

    func testHoverRenderingLightAndDark() throws {
        let output = URL(fileURLWithPath: "/private/tmp/ok126-hover-renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let canvas = Flipped(frame: NSRect(x: 0, y: 0, width: 780, height: 360))
            canvas.wantsLayer = true
            canvas.appearance = NSAppearance(named: name)
            canvas.effectiveAppearance.performAsCurrentDrawingAppearance {
                canvas.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            }
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = canvas
            let poster = PosterNativeCardView(frame: NSRect(x: 20, y: 25, width: 150, height: 270))
            let live = LiveChannelNativeCard()
            live.frame = NSRect(x: 200, y: 25, width: 260, height: LiveChannelCardMetrics.height(width: 260))
            let legacy = BrowserHoverBackground.Background(frame: NSRect(x: 500, y: 25, width: 250, height: 100))
            poster.bind(summary: VideoSummary(siteKey: "fixture", siteName: "示例", videoID: "1", title: "静止时的轻量悬浮"), repository: nil, pixels: 256, onSelect: {})
            live.bind(channel: LiveChannel(groupName: "示例", name: "示例频道", streams: []), favorite: false, urls: [], pixels: 256, repository: nil)
            canvas.addSubview(poster); canvas.addSubview(live); canvas.addSubview(legacy)
            canvas.layoutSubtreeIfNeeded()
            poster.setBrowserHovered(true); live.setBrowserHovered(true); legacy.setBrowserHovered(true)
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("hover-\(name.rawValue).png"))
            XCTAssertEqual(poster.layer?.borderWidth, 0)
            window.close()
        }
    }
}

@MainActor
final class DanmakuSmoothRenderingTests: XCTestCase {
    private func timeline() -> DanmakuTimeline {
        .init(comments: (0..<60).map { i in .init(id: "\(i)", time: 1,
            mode: i % 3 == 0 ? .scrolling : (i % 3 == 1 ? .top : .bottom),
            fontSize: 22, color: i % 2 == 0 ? 0xFFFFFF : 0xE0AAFF,
            text: "弹幕缓存与同步测试 \(i) · 流畅移动 ♡") })
    }
    private func makeView() -> (DanmakuOverlayNSView, NSWindow) {
        let view = DanmakuOverlayNSView(frame: .init(x: 0, y: 0, width: 2240, height: 1260))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }
    private func update(_ view: DanmakuOverlayNSView, timeline: DanmakuTimeline, snapshot: PlayerSnapshot,
                        revision: UInt64 = 1, opacity: Double = 0.86) {
        view.update(timeline: timeline, timelineRevision: revision, snapshot: snapshot, offset: 0,
                    fontScale: 1, opacity: opacity, displayArea: .full, density: .high)
    }
    func testFramesOnlyMoveCachedSpritesAndRemainMemoryBounded() throws {
        let (view, window) = makeView(); defer { window.close() }
        let timeline = timeline()
        let now = ProcessInfo.processInfo.systemUptime
        var snapshot = PlayerSnapshot(status: .playing, position: 1)
        snapshot.positionSampleUptime = now
        update(view, timeline: timeline, snapshot: snapshot)
        XCTAssertEqual(view.activeCommentCount, 60)
        let rasterizations = view.rasterizationCount, bytes = view.rasterBytes
        let layers = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers)
        let original = layers[0].position
        let start = ProcessInfo.processInfo.systemUptime
        for frame in 1...240 { view.renderFrame(at: now + Double(frame) / 120) }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(layers[0].position.x, original.x)
        XCTAssertEqual(view.rasterizationCount, rasterizations)
        XCTAssertEqual(view.rasterBytes, bytes)
        XCTAssertLessThanOrEqual(bytes, DanmakuOverlayNSView.maximumRasterBytes)
        XCTAssertNil(layers[0].animationKeys(), "No implicit per-frame animation may fight media time")
        // A same-snapshot appearance update changes compositing, not the cached text.
        update(view, timeline: timeline, snapshot: snapshot, opacity: 0.5)
        XCTAssertEqual(view.rasterizationCount, rasterizations)
        XCTAssertEqual(layers[0].opacity, 0.5)
        let output = "60 comments, 240 position-only frames: \(elapsed * 1000) ms total; rasterizations=\(rasterizations); bytes=\(bytes)\n"
        try output.write(toFile: "/private/tmp/ok128-danmaku-render-metrics.txt", atomically: true, encoding: .utf8)
        view.renderFrame(at: now + 12)
        XCTAssertEqual(view.activeCommentCount, 0)
        XCTAssertEqual(view.rasterBytes, 0)
    }
    func testPausedSpritesFreezeAndSeekOrNewTimelineClearsOldContents() throws {
        let (view, window) = makeView(); defer { window.close() }
        let timeline = timeline()
        let now = ProcessInfo.processInfo.systemUptime
        var snapshot = PlayerSnapshot(status: .paused, position: 1)
        update(view, timeline: timeline, snapshot: snapshot)
        XCTAssertEqual(view.activeCommentCount, 60)
        let layers = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers)
        let positions = layers.map(\.position)
        view.renderFrame(at: now + 10)
        XCTAssertEqual(layers.map(\.position), positions)
        XCTAssertFalse(view.isDisplayDriverRunning)
        snapshot.isSeeking = true; snapshot.seekTarget = 100
        update(view, timeline: timeline, snapshot: snapshot)
        XCTAssertEqual(view.activeCommentCount, 0)
        XCTAssertEqual(view.rasterBytes, 0)
        snapshot = .init(status: .paused, position: 1)
        update(view, timeline: timeline, snapshot: snapshot, revision: 2)
        XCTAssertEqual(view.activeCommentCount, 60)
        XCTAssertTrue(layers.allSatisfy { $0.superlayer == nil })
        update(view, timeline: .init(comments: []), snapshot: snapshot, revision: 3)
        XCTAssertEqual(view.rasterBytes, 0)
    }
    func testRetinaRasterShowsLegibleTextAndColor() throws {
        let (view, window) = makeView(); defer { window.close() }
        let timeline = DanmakuTimeline(comments: [.init(id: "top", time: 1, mode: .top, fontSize: 38,
            color: 0xE0AAFF, text: "兰香如故 · 弹幕流畅度测试 128 ♡")])
        update(view, timeline: timeline, snapshot: .init(status: .paused, position: 1))
        let sprite = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers?.first)
        let contents = try XCTUnwrap(sprite.contents)
        let image = contents as! CGImage
        XCTAssertEqual(image.width, Int(ceil(sprite.bounds.width * sprite.contentsScale)))
        let bitmap = NSBitmapImageRep(cgImage: image)
        var visiblePixels = 0, purplePixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                visiblePixels += 1
                if color.blueComponent > color.greenComponent + 0.1 { purplePixels += 1 }
            }
        }
        XCTAssertGreaterThan(visiblePixels, 100)
        XCTAssertGreaterThan(purplePixels, 100)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ok128-danmaku-sprite.png"))
        // Render the real layer tree to verify text orientation and top placement.
        let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1120, pixelsHigh: 630,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4480, bitsPerPixel: 32)!
        let graphics = NSGraphicsContext(bitmapImageRep: canvas)!
        graphics.cgContext.setFillColor(NSColor.darkGray.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 1120, height: 630))
        // Match AppKit's flipped NSView context when rendering the layer tree.
        graphics.cgContext.translateBy(x: 0, y: 630)
        graphics.cgContext.scaleBy(x: 0.5, y: -0.5)
        view.layer!.render(in: graphics.cgContext)
        try XCTUnwrap(canvas.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ok128-danmaku-layer.png"))
    }
    func testDisplayDriverStopsWithoutDeliveringQueuedFrames() async throws {
        var count = 0
        let driver = DanmakuDisplayDriver { count += 1 }
        driver.start(displayID: CGMainDisplayID())
        XCTAssertTrue(driver.isRunning)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertGreaterThan(count, 0)
        driver.stop()
        let stopped = count
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(count, stopped)
        driver.start(displayID: CGMainDisplayID())
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertGreaterThan(count, stopped)
        driver.stop()
    }
}
