import AppKit
import OKVideoPersistence
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.primaryToolbarLayout) private var toolbarLayout
    @State private var isSelecting = false
    @State private var selectedIDs: Set<HistoryRecord.ID> = []
    @State private var pendingDeletion: HistoryDeletion?
    @State private var focusedID: HistoryRecord.ID?
    private let scrollCoordinateSpace = "history-scroll"

    var body: some View {
        Group {
            if state.history.isEmpty {
                EmptyStateView(
                    systemImage: "clock",
                    title: L10n.string("history.empty.title", fallback: "No Watch History"),
                    message: L10n.string("history.empty.message", fallback: "Playback progress appears here after a video starts. History is kept for 60 days by default.")
                )
            } else {
                ScrollView {
                    BrowserToolbarScrollMarker(
                        coordinateSpaceName: scrollCoordinateSpace
                    )
                    LazyVStack(spacing: 0) {
                        ForEach(state.history) { item in
                            historyRow(item)
                            Divider()
                                .padding(.leading, isSelecting ? 56 : 20)
                        }
                    }
                }
                .browserToolbarScrollSurface(named: scrollCoordinateSpace)
            }
        }
        .navigationTitle("")
        .toolbar {
            PrimaryPageToolbarLeadingContent(title: L10n.string(.sectionHistory))
            ToolbarItemGroup(placement: .primaryAction) {
                if !state.isDetailPagePresented,
                   !state.history.isEmpty {
                    historyManagementControls
                }
            }
        }
        .alert(
            deletionTitle,
            isPresented: deletionAlertIsPresented
        ) {
            Button(L10n.string(.commonCancel), role: .cancel) {}
            Button(L10n.string("common.delete", fallback: "Delete"), role: .destructive) {
                performDeletion()
            }
        } message: {
            Text(deletionMessage)
        }
        .onChange(of: state.history.map(\.id)) { availableIDs in
            selectedIDs.formIntersection(availableIDs)
            if focusedID.map({ availableIDs.contains($0) }) != true {
                focusedID = availableIDs.first
            }
            if state.history.isEmpty {
                isSelecting = false
            }
        }
        .onAppear {
            focusedID = focusedID ?? state.history.first?.id
        }
        .background {
            AppKeyCommandMonitor(handler: handleKeyCommand)
                .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func historyRow(_ item: HistoryRecord) -> some View {
        HStack(spacing: 6) {
            Button {
                if isSelecting {
                    toggleSelection(item.id)
                } else {
                    state.requestHistoryPlayback(item)
                }
            } label: {
                HStack(spacing: 14) {
                    if isSelecting {
                        Image(
                            systemName: selectedIDs.contains(item.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(
                            selectedIDs.contains(item.id)
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .frame(width: 22)
                    }

                    historyContent(item)
                }
                .contentShape(Rectangle())
                .padding(.leading, 20)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .appInteractiveHover(
                cornerRadius: 10,
                selected: selectedIDs.contains(item.id) || focusedID == item.id
            )
            .contextMenu {
                Button(role: .destructive) {
                    pendingDeletion = .items([item.id])
                } label: {
                    Label(L10n.string("history.delete-one", fallback: "Delete History Item"), systemImage: "trash")
                }
            }

            if !isSelecting {
                Button(role: .destructive) {
                    pendingDeletion = .items([item.id])
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .appInteractiveHover(cornerRadius: 8, destructive: true)
                .foregroundStyle(.secondary)
                .help(L10n.string("history.delete-one", fallback: "Delete History Item"))
                .padding(.trailing, 14)
            }
        }
    }

    private func historyContent(_ item: HistoryRecord) -> some View {
        HStack(spacing: 14) {
            RemoteImage(url: item.posterURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ZStack {
                    Color.secondary.opacity(0.10)
                    Image(systemName: "film")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 48, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(
                    [
                        state.historySiteName(for: item),
                        item.sourceName,
                        item.episodeName
                    ]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                if let progress = Self.displayedProgress(position: item.position, duration: item.duration) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 200, alignment: .leading)
                        .accessibilityLabel(L10n.string("history.playback-progress", fallback: "Watch Progress"))
                        .accessibilityValue("\(Int(progress * 100))%")
                }
            }
            Spacer()
            Text(
                item.watchedAt.formatted(
                    Date.FormatStyle(
                        date: .abbreviated,
                        time: .shortened,
                        locale: L10n.locale
                    )
                )
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // Presentation-only: retain the previous visibility guard and clamp.
    static func displayedProgress(position: TimeInterval, duration: TimeInterval) -> Double? {
        guard duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    @ViewBuilder
    private var historyManagementControls: some View {
        if isSelecting {
            switch toolbarLayout {
            case .expanded, .compact:
                selectAllButton
                    .primaryToolbarIconControl(isSelected: allItemsSelected)
                deleteSelectedButton
                    .primaryToolbarIconControl(destructive: true)
                finishSelectionButton
                    .primaryToolbarTextControl()
            case .minimal:
                selectionManagementMenu
                    .primaryToolbarMenuControl()
                finishSelectionButton
                    .primaryToolbarTextControl()
            }
        } else {
            switch toolbarLayout {
            case .expanded, .compact:
                beginSelectionButton
                    .primaryToolbarIconControl()
                clearAllButton
                    .primaryToolbarIconControl(destructive: true)
            case .minimal:
                normalManagementMenu
                    .primaryToolbarMenuControl()
            }
        }
    }

    private var selectAllButton: some View {
        Button {
            selectedIDs = allItemsSelected
                ? []
                : Set(state.history.map(\.id))
        } label: {
            Label(
                allItemsSelected
                    ? L10n.string("common.deselect-all", fallback: "Deselect All")
                    : L10n.string("common.select-all", fallback: "Select All"),
                systemImage: allItemsSelected
                    ? "checkmark.circle.badge.xmark"
                    : "checkmark.circle"
            )
        }
        .help(
            allItemsSelected
                ? L10n.string("common.deselect-all", fallback: "Deselect All")
                : L10n.string("common.select-all", fallback: "Select All")
        )
    }

    private var deleteSelectedButton: some View {
        Button(role: .destructive) {
            pendingDeletion = .items(selectedIDs)
        } label: {
            Label(
                selectedIDs.isEmpty
                    ? L10n.string("common.delete-selected", fallback: "Delete Selected")
                    : L10n.string("common.delete-selected-count", fallback: "Delete Selected (%d)", selectedIDs.count),
                systemImage: "trash"
            )
        }
        .disabled(selectedIDs.isEmpty)
        .help(
            selectedIDs.isEmpty
                ? L10n.string("history.select-first", fallback: "Select history items first")
                : L10n.string("history.delete-selected", fallback: "Delete Selected History")
        )
    }

    private var finishSelectionButton: some View {
        Button(L10n.string("common.done", fallback: "Done")) {
            isSelecting = false
            selectedIDs.removeAll()
        }
    }

    private var beginSelectionButton: some View {
        Button {
            isSelecting = true
        } label: {
            Label(L10n.string("common.select", fallback: "Select"), systemImage: "checklist")
        }
        .help(L10n.string("history.select", fallback: "Select History"))
    }

    private var clearAllButton: some View {
        Button(role: .destructive) {
            pendingDeletion = .all
        } label: {
            Label(L10n.string("history.clear", fallback: "Clear History"), systemImage: "trash")
        }
        .help(L10n.string("history.clear", fallback: "Clear History"))
    }

    private var selectionManagementMenu: some View {
        Menu {
            selectAllButton
            deleteSelectedButton
        } label: {
            Label(L10n.string("common.selection-actions", fallback: "Selection Actions"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help(L10n.string("common.selection-actions", fallback: "Selection Actions"))
    }

    private var normalManagementMenu: some View {
        Menu {
            beginSelectionButton
            clearAllButton
        } label: {
            Label(L10n.string("history.manage", fallback: "Manage History"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help(L10n.string("history.manage", fallback: "Manage History"))
    }

    private var allItemsSelected: Bool {
        !state.history.isEmpty && selectedIDs.count == state.history.count
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var deletionTitle: String {
        if case .some(.all) = pendingDeletion {
            return L10n.string("history.clear.title", fallback: "Clear All History?")
        }
        return L10n.string("history.delete.title", fallback: "Delete History?")
    }

    private var deletionMessage: String {
        switch pendingDeletion {
        case .some(.all):
            return L10n.string("history.clear.message", fallback: "All watch history for the current video configuration will be removed. This cannot be undone.")
        case let .some(.items(ids)):
            return L10n.string("history.delete.message", fallback: "%d selected history items will be removed. This cannot be undone.", ids.count)
        case nil:
            return ""
        }
    }

    private func toggleSelection(_ id: HistoryRecord.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func performDeletion() {
        let deletion = pendingDeletion
        pendingDeletion = nil
        Task {
            switch deletion {
            case .some(.all):
                await state.clearHistory()
            case let .some(.items(ids)):
                await state.deleteHistory(ids: ids)
            case nil:
                break
            }
            selectedIDs.removeAll()
            isSelecting = false
        }
    }

    private func handleKeyCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            [.command, .option, .control, .shift]
        )
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            isSelecting = true
            selectedIDs = Set(state.history.map(\.id))
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125:
            moveFocus(by: 1)
        case 126:
            moveFocus(by: -1)
        case 36, 76:
            guard let focusedID,
                  let item = state.history.first(where: {
                      $0.id == focusedID
                  }) else { return false }
            if isSelecting {
                toggleSelection(focusedID)
            } else {
                state.requestHistoryPlayback(item)
            }
        case 51, 117:
            guard let focusedID else { return false }
            pendingDeletion = .items(
                isSelecting && !selectedIDs.isEmpty
                    ? selectedIDs : [focusedID]
            )
        case 53:
            guard isSelecting else { return false }
            isSelecting = false
            selectedIDs.removeAll()
        default:
            return false
        }
        return true
    }

    private func moveFocus(by offset: Int) {
        let ids = state.history.map(\.id)
        guard !ids.isEmpty else { return }
        let currentIndex = focusedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        focusedID = ids[min(max(currentIndex + offset, 0), ids.count - 1)]
    }
}

private enum HistoryDeletion {
    case items(Set<HistoryRecord.ID>)
    case all
}
