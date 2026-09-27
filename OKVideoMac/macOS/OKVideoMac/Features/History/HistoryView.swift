import AppKit
import OKVideoPersistence
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedIDs = Set<String>()
    @State private var isDeleting = false

    var body: some View {
        NativeLibraryList(rows: rows, selection: $selectedIDs, repository: state.imageRepository,
            openTitle: L10n.string("history.continue", fallback: "Continue Watching"),
            onOpen: { id in
                if let record = state.history.first(where: { $0.id == id }) { state.requestHistoryPlayback(record) }
            }, onDelete: requestDeletion)
        .overlay {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(L10n.string("history.empty.title", fallback: "No Watch History")).font(.headline)
                    Text(L10n.string("history.empty.message", fallback: "Playback progress appears here after a video starts. History is kept for 60 days by default.")).foregroundColor(.secondary)
                }.padding()
            }
        }
        .navigationTitle("")
        .toolbar {
            PrimaryPageToolbarLeadingContent(title: L10n.string(.sectionHistory))
            ToolbarItemGroup(placement: .primaryAction) {
                Button { selectedIDs = Set(rows.map(\.id)) } label: {
                    Label(L10n.string("common.select-all", fallback: "Select All"), systemImage: "checklist")
                }
                .primaryToolbarIconControl()
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .help(L10n.string("common.select-all", fallback: "Select All"))
                .disabled(rows.isEmpty)
                Button { requestDeletion(selectedIDs, nil) } label: {
                    Label(L10n.string("common.delete-selected", fallback: "Delete Selected"), systemImage: "trash")
                }
                .primaryToolbarIconControl()
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .help(L10n.string("common.delete-selected", fallback: "Delete Selected"))
                .disabled(selectedIDs.isEmpty || isDeleting)
                PrimaryToolbarDivider()
                    .frame(height: PrimaryToolbarMetrics.itemHeight)
                Button(L10n.string("history.clear", fallback: "Clear History")) {
                    requestDeletion(Set(rows.map(\.id)), nil)
                }
                .primaryToolbarTextControl()
                .frame(height: PrimaryToolbarMetrics.itemHeight)
                .help(L10n.string("history.clear", fallback: "Clear History"))
                .disabled(rows.isEmpty || isDeleting)
            }
        }
        .task { await state.refreshHistoryPresentation() }
        .onChange(of: state.isBrowserWindowKey) { key in
            if key { Task { await state.refreshHistoryPresentation() } }
        }
        .onChange(of: state.history.map(\.id)) { selectedIDs.formIntersection($0) }
    }

    private var rows: [NativeLibraryRow] {
        state.history.map { item in
            NativeLibraryRow(id: item.id, title: item.title,
                subtitle: [state.historySiteName(for: item), item.sourceName, AppState.historyEpisodeDisplayName(item)].compactMap { $0 }.joined(separator: " · "),
                posterURL: item.posterURL, date: item.watchedAt,
                progress: Self.displayedProgress(position: item.position, duration: item.duration),
                progressText: Self.progressText(position: item.position, duration: item.duration),
                isLoading: state.historyPlaybackLoadingID == item.id)
        }
    }

    static func displayedProgress(position: TimeInterval, duration: TimeInterval) -> Double? {
        guard position.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }
    static func progressText(position: TimeInterval, duration: TimeInterval) -> String {
        func time(_ value: TimeInterval) -> String {
            let seconds = Int(min(max(value.isFinite ? value : 0, 0), 359_999))
            return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        if duration.isFinite, duration > 0 { return "\(time(position)) / \(time(duration))" }
        return L10n.string("history.elapsed", fallback: "Watched %@ · Duration unknown", time(position))
    }
    private func requestDeletion(_ ids: Set<String>, _ window: NSWindow?) {
        guard !isDeleting else { return }
        let records = state.history.filter { ids.contains($0.id) }
        guard !records.isEmpty else { return }
        NativeLibraryConfirmation.present(
            title: L10n.string("history.delete.title", fallback: "Delete History?"),
            message: L10n.string("history.delete.message", fallback: "%d selected history items will be removed. This cannot be undone.", records.count),
            window: window) {
                isDeleting = true
                Task {
                    if await state.deleteHistory(records: records) { selectedIDs.subtract(records.map(\.id)) }
                    isDeleting = false
                }
            }
    }
}
