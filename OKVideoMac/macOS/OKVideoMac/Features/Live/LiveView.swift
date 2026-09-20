import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI

@MainActor
final class LiveBrowserSession: ObservableObject {
    @Published var selectedSourceID: LiveSourceID?
    @Published var searchText = ""
    @Published var selectedGroupID: String?
    @Published var showsFavoritesOnly = false
    @Published var showsGuide = false
    @Published var guideWindowStart = LiveBrowserSession.roundedGuideStart(Date())
    @Published var guideVisibleRange: Range<Int> = 0..<1

    /// Deliberately not published: changing sections must not invalidate the
    /// mounted live grid. It only gates source-loading side effects.
    var isActive = false

    static func roundedGuideStart(_ date: Date) -> Date {
        let interval: TimeInterval = 60 * 60
        return Date(timeIntervalSinceReferenceDate:
            floor(date.timeIntervalSinceReferenceDate / interval) * interval)
    }

    func reconcileSources(_ sources: [LiveSourceDescriptor]) {
        if let selectedSourceID,
           sources.contains(where: { $0.id == selectedSourceID }) {
            return
        }
        selectedSourceID = sources.first?.id
    }

    func reconcileGroups(_ groups: [LiveGroup]) {
        guard let selectedGroupID,
              !groups.contains(where: { $0.id == selectedGroupID }) else {
            return
        }
        self.selectedGroupID = nil
    }
}

struct LiveView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject var session: LiveBrowserSession
    @StateObject private var logoURLCache = LiveChannelLogoURLCache()
    private let channelScrollCoordinateSpace = "live-channel-scroll"

    var body: some View {
        Group {
            if state.liveSourceDescriptors.isEmpty {
                emptyLibrary
            } else {
                channelContent
                    .frame(minWidth: 520)
            }
        }
        .onAppear {
            updateActivation(for: navigation.selectedSection)
        }
        .onDisappear {
            session.isActive = false
            updateEPGDemand()
            state.clearLiveGuideDemand()
        }
        .onChange(of: navigation.selectedSection) { section in
            updateActivation(for: section)
        }
        .onChange(of: session.selectedSourceID) { _ in
            state.selectImportedIdentitySource(session.selectedSourceID)
            session.searchText = ""
            session.selectedGroupID = nil
            session.showsFavoritesOnly = false
            updateEPGDemand()
            guard session.isActive else { return }
            Task { await loadSelectedIfNeeded() }
        }
        .onChange(of: state.liveSourceDescriptors) { _ in
            let previousSourceID = session.selectedSourceID
            selectFirstSourceIfNeeded()
            guard session.isActive,
                  previousSourceID == session.selectedSourceID else {
                return
            }
            Task { await loadSelectedIfNeeded() }
        }
        .onChange(of: selectedCatalog?.groups.filter { $0.password == nil }.map(\.id) ?? []) { _ in
            // A temporary loading state is not evidence that a category was
            // removed. Reconcile only against a completed catalog snapshot.
            if let selectedCatalog {
                session.reconcileGroups(selectedCatalog.groups.filter { $0.password == nil })
            }
        }
        .onChange(of: state.shortcutLiveRefreshRequest) { _ in
            guard session.isActive,
                  let source = selectedSource,
                  source.canRefresh else { return }
            Task { await state.refreshLiveSource(source.id) }
        }
        .onChange(of: session.selectedGroupID) { _ in updateEPGDemand() }
        .onChange(of: session.searchText) { _ in updateEPGDemand() }
        .onChange(of: session.showsFavoritesOnly) { _ in updateEPGDemand() }
        .onChange(of: session.showsGuide) { enabled in
            if !enabled { state.clearLiveGuideDemand() }
            updateEPGDemand()
        }
        .onChange(of: state.liveEPGCatalogRevision) { _ in updateEPGDemand() }
        .onChange(of: state.shortcutLiveSourceSelection) { request in
            guard let request,
                  state.liveSourceDescriptors.contains(where: {
                      $0.id == request.sourceID
                  }) else { return }
            state.selectImportedIdentitySource(request.sourceID)
            session.selectedSourceID = request.sourceID
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                systemImage: "dot.radiowaves.left.and.right",
                title: L10n.string("live.no-sources.title", fallback: "No Live TV Sources"),
                message: L10n.string("live.no-sources.message", fallback: "Use the button below to add an M3U, M3U8, TXT, or JSON source from a URL, pasted content, or a local file.")
            )
            Button {
                state.selectedSettingsPane = .liveSources
                state.selectSection(.settings)
            } label: {
                Label(L10n.string("live.open-settings", fallback: "Open Live TV Source Settings"), systemImage: "gearshape")
            }
        }
    }

    @ViewBuilder
    private var channelContent: some View {
        if let source = selectedSource {
            if let catalog = state.presentedLiveCatalog(for: source.id) {
                playlistContent(
                    catalog,
                    sourceID: source.id,
                    sourceName: source.name
                )
            } else if state.isLiveCatalogLoading(source.id) {
                AppActivityLabel(L10n.string("live.loading-source", fallback: "Loading Live TV source…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 18) {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: L10n.string("live.source.load.failed", fallback: "Live TV Source Failed to Load"),
                        message: state.liveCatalogError(for: source.id)
                            ?? L10n.string("live.choose-source.message", fallback: "Choose a source from the menu above.")
                    )
                    if source.canRefresh {
                        Button {
                            Task { await state.refreshLiveSource(source.id) }
                        } label: {
                            Label(L10n.string("live.refresh-current", fallback: "Refresh Current Live TV Source"), systemImage: "arrow.clockwise")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            EmptyStateView(
                systemImage: "list.bullet.rectangle",
                title: L10n.string("live.choose-source.title", fallback: "Choose a Live TV Source"),
                message: L10n.string("live.choose-source.message", fallback: "Choose a source from the menu above.")
            )
        }
    }

    @ViewBuilder
    private func playlistContent(
        _ playlist: LiveCatalogSnapshot,
        sourceID: LiveSourceID,
        sourceName: String
    ) -> some View {
        let importedCatalog = importedCatalog(for: sourceID)
        let visibleGroups = playlist.groups.filter { $0.password == nil }
        let hiddenCount = playlist.groups.count - visibleGroups.count
        let allowsLogoFallback: Bool = {
            if case .imported = sourceID { return true }
            return false
        }()
        let channels = filteredChannels(
            visibleGroups.flatMap(\.channels),
            sourceID: sourceID
        )
        if session.showsGuide, !channels.isEmpty {
            LiveGuideScreen(
                guide: state.liveGuide,
                session: session,
                sourceID: sourceID,
                channels: channels,
                importedCatalog: importedCatalog
            )
            .environmentObject(state)
        } else {
        GeometryReader { viewport in
            ScrollView {
                BrowserToolbarScrollMarker(
                    coordinateSpaceName: channelScrollCoordinateSpace
                )
                VStack(spacing: 0) {
                    if channels.isEmpty {
                        EmptyStateView(
                            systemImage: session.showsFavoritesOnly
                                ? "star"
                                : "magnifyingglass",
                            title: session.showsFavoritesOnly
                                ? L10n.string("live.empty.favorites.title", fallback: "No Favorite Channels")
                                : L10n.string("live.empty.filtered.title", fallback: "No Matching Channels"),
                            message: session.showsFavoritesOnly
                                ? L10n.string("live.empty.favorites.message", fallback: "Use the star on a channel card to add it to Favorites.")
                                : L10n.string("live.empty.filtered.message", fallback: "Choose another group or search term.")
                        )
                        .frame(
                            maxWidth: .infinity,
                            minHeight: max(0, viewport.size.height - 72)
                        )
                    } else {
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 238, maximum: 340),
                                    spacing: 18,
                                    alignment: .top
                                )
                            ],
                            alignment: .leading,
                            spacing: 20
                        ) {
                            ForEach(channels) { channel in
                                LiveChannelCard(
                                    channel: channel,
                                    artworkURLs: logoURLCache.urls(
                                        for: channel,
                                        allowsFallback: allowsLogoFallback
                                    ),
                                    navigationChannels: channels,
                                    sourceID: sourceID,
                                    sourceName: sourceName,
                                    importedCatalog: importedCatalog
                                )
                                .environmentObject(state)
                            }
                        }
                        .padding(20)

                        if hiddenCount > 0 {
                            Label(
                                L10n.string("live.protected-groups.hidden", fallback: "%d protected groups hidden", hiddenCount),
                                systemImage: "lock"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 20)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .browserToolbarScrollSurface(
                named: channelScrollCoordinateSpace
            )
        }
        }
    }


    private var selectedSource: LiveSourceDescriptor? {
        guard let selectedSourceID = session.selectedSourceID else { return nil }
        return state.liveSourceDescriptors.first { $0.id == selectedSourceID }
    }

    private func importedCatalog(for sourceID: LiveSourceID) -> AcceptedImportedCatalog? {
        guard case .imported(let id) = sourceID else { return nil }
        return state.acceptedImportedCatalogs[id]
    }

    private var selectedCatalog: LiveCatalogSnapshot? {
        guard let selectedSourceID = session.selectedSourceID else { return nil }
        return state.presentedLiveCatalog(for: selectedSourceID)
    }

    private func filteredChannels<S: Sequence>(
        _ channels: S,
        sourceID: LiveSourceID,
        limit: Int? = nil
    ) -> [LiveChannel] where S.Element == LiveChannel {
        let query = session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = channels.lazy.filter { channel in
            let isDeleted = state.isLiveChannelDeleted(
                sourceID: sourceID,
                channel: channel
            )
            let groupMatches = session.selectedGroupID == nil
                || channel.groupID == session.selectedGroupID
            let favoriteMatches = !session.showsFavoritesOnly
                || state.isLiveFavorite(sourceID: sourceID, channel: channel)
            let queryMatches = query.isEmpty
                || channel.name.localizedCaseInsensitiveContains(query)
                || channel.groupName.localizedCaseInsensitiveContains(query)
                || (channel.tvgName?.localizedCaseInsensitiveContains(query) ?? false)
                || (channel.number?.localizedCaseInsensitiveContains(query) ?? false)
            return !isDeleted
                && groupMatches
                && favoriteMatches
                && queryMatches
        }
        if let limit { return Array(matches.prefix(limit)) }
        return Array(matches)
    }

    private func selectFirstSourceIfNeeded() {
        session.reconcileSources(state.liveSourceDescriptors)
    }

    private func updateActivation(for section: AppSection) {
        session.isActive = section == .live
        updateEPGDemand()
        guard session.isActive else { return }

        let previousSourceID = session.selectedSourceID
        selectFirstSourceIfNeeded()
        state.selectImportedIdentitySource(session.selectedSourceID)
        if previousSourceID == session.selectedSourceID {
            Task { await loadSelectedIfNeeded() }
        }
    }

    private func loadSelectedIfNeeded() async {
        defer { updateEPGDemand() }
        guard let source = selectedSource,
              state.liveCatalog(for: source.id) == nil,
              !state.isLiveCatalogLoading(source.id) else {
            return
        }
        await state.loadLiveSource(source.id)
    }

    private func updateEPGDemand() {
        guard session.isActive, let catalog = selectedCatalog else {
            state.setEPGBrowserDemand(source: nil, channels: [])
            return
        }
        let channels = filteredChannels(catalog.groups.lazy.filter { $0.password == nil }.flatMap(\.channels),
                                        sourceID: catalog.sourceID, limit: 8)
        state.setEPGBrowserDemand(source: catalog.sourceID, channels: channels)
    }
}

private struct LiveGuideSelection: Equatable {
    let rowID: String
    let title: String
    let start: Date
    let end: Date
}

struct LiveGuideScreen: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var guide: LiveGuideState
    @ObservedObject var session: LiveBrowserSession
    let sourceID: LiveSourceID
    let channels: [LiveChannel]
    let importedCatalog: AcceptedImportedCatalog?
    @State private var selection: LiveGuideSelection?

    private var boundedChannels: [LiveChannel] {
        Array(channels.prefix(EPGGuideLimits.maximumDesiredRows))
    }

    private var windowEnd: Date {
        session.guideWindowStart.addingTimeInterval(12 * 60 * 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            content
            if let selection {
                Divider()
                detailBar(selection)
            }
        }
        .onAppear { requestGuide() }
        .onDisappear { state.clearLiveGuideDemand() }
        .onChange(of: session.guideWindowStart) { _ in requestGuide() }
        .onChange(of: channels.map(\.id)) { _ in requestGuide() }
    }

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button { moveWindow(-12 * 60 * 60) } label: {
                Label(L10n.string("live.guide.previous", fallback: "Previous 12 Hours"),
                      systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            DatePicker(
                L10n.string("live.guide.date", fallback: "Guide Date"),
                selection: guideDateBinding,
                displayedComponents: .date
            )
            .labelsHidden()
            Button(L10n.string("live.guide.now", fallback: "Now")) {
                session.guideWindowStart = LiveBrowserSession.roundedGuideStart(Date())
            }
            Button { moveWindow(12 * 60 * 60) } label: {
                Label(L10n.string("live.guide.next", fallback: "Next 12 Hours"),
                      systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            Text(session.guideWindowStart, format: .dateTime.month().day().hour().minute())
                .font(.subheadline.monospacedDigit())
                .foregroundColor(.secondary)
            Spacer()
            if channels.count > boundedChannels.count {
                Text(L10n.string("live.guide.filtered-limit",
                                 fallback: "Showing the first %d matching channels",
                                 boundedChannels.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if sourceID.isXtream {
                Text(L10n.string("live.guide.xtream-nearby-only",
                                 fallback: "This source provides nearby programmes only"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            statusLabel
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch guide.lifecycle {
        case .content(let value):
            if !value.failures.isEmpty {
                Label(L10n.string("live.guide.partial", fallback: "%d rows unavailable",
                                  value.failures.count), systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.caption)
            } else if value.refreshPhase == .loading {
                AppActivityLabel(L10n.string("live.guide.refreshing", fallback: "Refreshing…"))
                    .font(.caption)
            } else if value.freshness == .stale {
                Label(L10n.string("live.guide.stale", fallback: "Saved schedule"),
                      systemImage: "clock.arrow.circlepath")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        case .empty(let value) where value.refreshPhase == .loading:
            AppActivityLabel(L10n.string("live.guide.refreshing", fallback: "Refreshing…"))
                .font(.caption)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch guide.lifecycle {
        case .inactive, .loadingInitial:
            AppActivityLabel(L10n.string("live.guide.loading", fallback: "Loading programme guide…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content(let value):
            grid(value.snapshot)
        case .empty(let value):
            ZStack(alignment: .topTrailing) {
                grid(value.snapshot)
                Label(L10n.string("live.guide.empty", fallback: "No programme entries in this window"),
                      systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .padding(10)
            }
        case .unsupported:
            channelFallback(
                title: L10n.string("live.guide.short.unsupported", fallback: "This source does not provide a full schedule yet."),
                systemImage: "calendar.badge.exclamationmark"
            )
        case .failed:
            channelFallback(
                title: L10n.string("live.guide.failed", fallback: "The programme guide could not be loaded. Channel playback is still available."),
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private func grid(_ snapshot: EPGGuideSnapshot) -> some View {
        let rows = snapshot.rows.map { row in
            LiveGuideGridRow(
                id: row.id,
                title: row.channel.name,
                subtitle: rowSubtitle(row.state),
                state: row.state,
                programmes: row.programmes.map(LiveGuideGridProgramme.init)
            )
        }
        let model = try? LiveGuideGridModel(
            windowStart: snapshot.slices.first?.start ?? session.guideWindowStart,
            windowEnd: snapshot.slices.last?.end ?? windowEnd,
            timeZone: .current,
            rows: rows
        )
        return Group {
            if let model {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LiveGuideGridRepresentable(
                        model: model,
                        now: context.date,
                        onProgrammeSelected: { row, programme in
                            selection = LiveGuideSelection(
                                rowID: row.id, title: programme.title,
                                start: programme.start, end: programme.end
                            )
                        },
                        onProgrammeActivated: { row, _ in playChannel(row.id) },
                        onChannelActivated: { row in playChannel(row.id) },
                        onVisibleRangeChanged: { range in
                            guard range != session.guideVisibleRange else { return }
                            DispatchQueue.main.async {
                                session.guideVisibleRange = range
                                requestGuide()
                            }
                        }
                    )
                }
            } else {
                channelFallback(
                    title: L10n.string("live.guide.invalid", fallback: "The programme guide returned an invalid window."),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private func channelFallback(title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .foregroundColor(.secondary)
                .padding(.top, 18)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(boundedChannels) { channel in
                        HStack {
                            Text(channel.name).lineLimit(1)
                            Spacer()
                            Button(L10n.string("live.guide.play-channel", fallback: "Play Channel")) {
                                playChannel(channel.id)
                            }
                            .disabled(!canPlay(channel))
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 42)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailBar(_ value: LiveGuideSelection) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(value.title).font(.headline).lineLimit(1)
                Text(value.start, format: .dateTime.hour().minute())
                    + Text("–")
                    + Text(value.end, format: .dateTime.hour().minute())
            }
            Spacer()
            Button {
                playChannel(value.rowID)
            } label: {
                Label(L10n.string("live.guide.play-channel", fallback: "Play Channel"),
                      systemImage: "play.fill")
            }
            .disabled(boundedChannels.first(where: { $0.id == value.rowID }).map(canPlay) != true)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    private var guideDateBinding: Binding<Date> {
        Binding(get: { session.guideWindowStart }, set: { date in
            let calendar = Calendar.current
            let time = calendar.dateComponents([.hour, .minute], from: session.guideWindowStart)
            var day = calendar.dateComponents([.year, .month, .day], from: date)
            day.hour = time.hour
            day.minute = time.minute
            session.guideWindowStart = calendar.date(from: day)
                ?? LiveBrowserSession.roundedGuideStart(date)
        })
    }

    private func moveWindow(_ seconds: TimeInterval) {
        session.guideWindowStart = session.guideWindowStart.addingTimeInterval(seconds)
    }

    private func requestGuide() {
        let bounded = boundedChannels
        guard !bounded.isEmpty else {
            state.clearLiveGuideDemand()
            return
        }
        let lower = min(max(0, session.guideVisibleRange.lowerBound), bounded.count - 1)
        let upper = min(bounded.count, max(lower + 1, session.guideVisibleRange.upperBound))
        state.setLiveGuideDemand(
            source: sourceID,
            channels: bounded,
            windowStart: session.guideWindowStart,
            windowEnd: windowEnd,
            visibleRange: lower..<upper,
            focusedChannelID: selection?.rowID
        )
    }

    private func canPlay(_ channel: LiveChannel) -> Bool {
        if case .imported = sourceID {
            return !(importedCatalog?.selections(for: channel).isEmpty ?? true)
        }
        return !channel.streams.isEmpty
    }

    private func playChannel(_ channelID: String) {
        guard let channel = boundedChannels.first(where: { $0.id == channelID }) else { return }
        if case .imported = sourceID {
            guard let selection = importedCatalog?.selections(for: channel).first else { return }
            Task { await state.playImportedLive(selection, navigationChannels: boundedChannels) }
        } else {
            guard let stream = channel.streams.first else { return }
            Task {
                await state.playLive(channel: channel, stream: stream,
                                     sourceID: sourceID,
                                     navigationChannels: boundedChannels)
            }
        }
    }

    private func rowSubtitle(_ state: EPGGuideRowState) -> String? {
        switch state {
        case .loading: return L10n.string("live.guide.row.loading", fallback: "Loading…")
        case .empty: return L10n.string("live.guide.row.empty", fallback: "No programmes")
        case .unmatched: return L10n.string("live.guide.row.unmatched", fallback: "Channel not matched")
        case .ambiguous: return L10n.string("live.guide.row.ambiguous", fallback: "Multiple channel matches")
        case .unsupported: return L10n.string("live.guide.row.unsupported", fallback: "Not provided")
        case .failed: return L10n.string("live.guide.row.failed", fallback: "Unavailable")
        case .truncated: return L10n.string("live.guide.row.truncated", fallback: "Partially loaded")
        case .ready: return nil
        }
    }
}

struct LiveToolbarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.primaryToolbarLayout) private var toolbarLayout
    @ObservedObject var session: LiveBrowserSession

    var body: some View {
        Group {
            if let source = selectedSource {
                // Source selection and retry must survive an absent/failed
                // catalog. Do not condition the toolbar on loading success.
                let groups = (state.presentedLiveCatalog(for: source.id)?.groups ?? [])
                    .filter { $0.password == nil }
                let allChannels = groups.flatMap(\.channels)
                let deletedChannels = allChannels.filter {
                    state.isLiveChannelDeleted(
                        sourceID: source.id,
                        channel: $0
                    )
                }
                let channelCount = allChannels.count - deletedChannels.count
                toolbarControls(
                    source: source,
                    groups: groups,
                    deletedChannels: deletedChannels,
                    channelCount: channelCount
                )
            }
        }
    }

    @ViewBuilder
    private func toolbarControls(
        source: LiveSourceDescriptor,
        groups: [LiveGroup],
        deletedChannels: [LiveChannel],
        channelCount: Int
    ) -> some View {
        HStack(spacing: PrimaryToolbarMetrics.itemSpacing) {
            switch toolbarLayout {
            case .expanded:
                sourceMenu(
                    channelCount: channelCount,
                    sourceName: source.name,
                    compact: false
                )
                .primaryToolbarMenuControl()
                groupMenu(groups, compact: false)
                    .primaryToolbarMenuControl()
                favoritesButton
                    .primaryToolbarIconControl(
                        isSelected: session.showsFavoritesOnly,
                        selectedColor: .yellow
                    )
                guideModeButton
                    .primaryToolbarIconControl(isSelected: session.showsGuide)
                if !deletedChannels.isEmpty {
                    deletedChannelsMenu(
                        deletedChannels,
                        sourceID: source.id
                    )
                    .primaryToolbarMenuControl()
                }
            case .compact:
                sourceMenu(
                    channelCount: channelCount,
                    sourceName: source.name,
                    compact: true
                )
                .primaryToolbarMenuControl()
                groupMenu(groups, compact: true)
                    .primaryToolbarMenuControl()
                favoritesButton
                    .primaryToolbarIconControl(
                        isSelected: session.showsFavoritesOnly,
                        selectedColor: .yellow
                    )
                guideModeButton
                    .primaryToolbarIconControl(isSelected: session.showsGuide)
                if !deletedChannels.isEmpty {
                    deletedChannelsMenu(
                        deletedChannels,
                        sourceID: source.id
                    )
                    .primaryToolbarMenuControl()
                }
            case .minimal:
                condensedMenu(
                    source: source,
                    groups: groups,
                    deletedChannels: deletedChannels,
                    channelCount: channelCount
                )
                .primaryToolbarMenuControl()
            }

            PrimaryToolbarDivider()
            LiveBackgroundActivityControl(epgState: state.liveEPG,
                validationToolbar: state.liveValidationActivity.toolbar, source: source)
            refreshControl(sourceID: source.id)
                .primaryToolbarIconControl()
        }
    }

    private func sourceMenu(
        channelCount: Int,
        sourceName: String,
        compact: Bool
    ) -> some View {
        Menu {
            ForEach(state.liveSourceDescriptors) { source in
                Button {
                    state.selectImportedIdentitySource(source.id)
                    session.selectedSourceID = source.id
                } label: {
                    menuLabel(
                        source.name,
                        selected: source.id == session.selectedSourceID
                    )
                }
            }
        } label: {
            Label {
                Text(compact ? sourceName : "\(sourceName) · \(channelCount)")
                    .lineLimit(1)
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
        }
        .frame(maxWidth: compact ? 132 : 220)
        .controlSize(.regular)
        .disabled(state.liveSourceDescriptors.count < 2)
        .help(L10n.string("live.current-source", fallback: "Current source: %@; %d channels", sourceName, channelCount))
    }

    private func groupMenu(_ groups: [LiveGroup], compact: Bool) -> some View {
        Menu {
            Button {
                session.selectedGroupID = nil
            } label: {
                menuLabel(
                    L10n.string("live.all-channels", fallback: "All Channels"),
                    selected: session.selectedGroupID == nil
                )
            }
            Divider()
            ForEach(groups) { group in
                Button {
                    session.selectedGroupID = group.id
                } label: {
                    menuLabel(
                        L10n.string(
                            "live.group-count",
                            fallback: "%1$@ (%2$lld)",
                            group.name,
                            group.channels.count
                        ),
                        selected: session.selectedGroupID == group.id
                    )
                }
            }
        } label: {
            Label(
                compact
                    ? (selectedGroupName(in: groups) ?? L10n.string("common.all", fallback: "All"))
                    : (selectedGroupName(in: groups) ?? L10n.string("live.all-channels", fallback: "All Channels")),
                systemImage: "rectangle.3.group"
            )
            .lineLimit(1)
        }
        .frame(maxWidth: compact ? 108 : 180)
        .controlSize(.regular)
        .help(L10n.string("live.filter-groups", fallback: "Filter Channel Groups"))
    }

    private func selectedGroupName(in groups: [LiveGroup]) -> String? {
        groups.first { $0.id == session.selectedGroupID }?.name
    }

    private func condensedMenu(
        source: LiveSourceDescriptor,
        groups: [LiveGroup],
        deletedChannels: [LiveChannel],
        channelCount: Int
    ) -> some View {
        Menu {
            sourceMenu(
                channelCount: channelCount,
                sourceName: source.name,
                compact: false
            )
            groupMenu(groups, compact: false)
            Divider()
            favoritesButton
            guideModeButton
            if !deletedChannels.isEmpty {
                deletedChannelsMenu(
                    deletedChannels,
                    sourceID: source.id
                )
            }
        } label: {
            Label(L10n.string("live.options", fallback: "Live TV Options"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help(L10n.string("live.options.help", fallback: "Manage Live TV sources, groups, and channels"))
    }

    private var favoritesButton: some View {
        Button {
            session.showsFavoritesOnly.toggle()
        } label: {
            Label(
                L10n.string("live.favorites-only", fallback: "Favorites Only"),
                systemImage: session.showsFavoritesOnly ? "star.fill" : "star"
            )
        }
        .help(
            session.showsFavoritesOnly
                ? L10n.string("live.show-all", fallback: "Show All Channels")
                : L10n.string("live.show-favorites", fallback: "Show Favorite Channels Only")
        )
    }

    private var guideModeButton: some View {
        Button {
            session.showsGuide.toggle()
        } label: {
            Label(
                session.showsGuide
                    ? L10n.string("live.channels", fallback: "Channels")
                    : L10n.string("live.guide", fallback: "Programme Guide"),
                systemImage: session.showsGuide ? "square.grid.2x2" : "calendar"
            )
        }
        .help(session.showsGuide
            ? L10n.string("live.channels.show", fallback: "Show channel cards")
            : L10n.string("live.guide.show", fallback: "Show programme guide"))
    }

    private func deletedChannelsMenu(
        _ channels: [LiveChannel],
        sourceID: LiveSourceID
    ) -> some View {
        Menu {
            ForEach(channels) { channel in
                Button {
                    Task {
                        await state.restoreDeletedLiveChannel(
                            sourceID: sourceID,
                            channel: channel
                        )
                    }
                } label: {
                    Label(
                        L10n.string("live.restore-channel", fallback: "Restore %@", channel.name),
                        systemImage: "arrow.uturn.backward"
                    )
                }
            }
            Divider()
            Button {
                Task {
                    await state.restoreAllDeletedLiveChannels(
                        sourceID: sourceID
                    )
                }
            } label: {
                Label(L10n.string("live.restore-all", fallback: "Restore All"), systemImage: "arrow.counterclockwise")
            }
        } label: {
            Label(
                L10n.string("live.deleted-count", fallback: "%d Deleted", channels.count),
                systemImage: "trash"
            )
        }
        .help(L10n.string("live.deleted.help", fallback: "View or restore deleted channels"))
    }

    @ViewBuilder
    private func refreshControl(sourceID: LiveSourceID) -> some View {
        if state.isLiveCatalogLoading(sourceID) {
            AppActivityIndicator(size: .small)
                .help(L10n.string("live.refreshing", fallback: "Refreshing Live TV source"))
        } else {
            Button {
                Task { await state.refreshLiveSource(sourceID) }
            } label: {
                Label(L10n.string("live.refresh", fallback: "Refresh Live TV Source"), systemImage: "arrow.clockwise")
            }
            .disabled(selectedSource?.canRefresh != true)
            .help(L10n.string("live.refresh-current", fallback: "Refresh Current Live TV Source"))
        }
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
                // The toolbar's icon-only style must not hide menu row titles.
                .labelStyle(.titleAndIcon)
        } else {
            Text(title)
        }
    }

    private var selectedSource: LiveSourceDescriptor? {
        guard let selectedSourceID = session.selectedSourceID else {
            return nil
        }
        return state.liveSourceDescriptors.first { $0.id == selectedSourceID }
    }
}


@MainActor
final class LiveEPGState: ObservableObject {
    @Published private(set) var revision = 0
    private struct ChannelKey: Hashable {
        let source: EPGSourceKey
        let channelID: String
    }
    private struct StoredResult {
        let item: EPGNowNextItem
        let token: EPGResultToken
        let availability: EPGAvailability
        let cost: Int
    }
    private var revisions: [EPGSourceKey: String] = [:]
    private var generations: [EPGSourceKey: UUID] = [:]
    private var results: [ChannelKey: StoredResult] = [:]
    private var order: [ChannelKey] = []
    private var statuses: [EPGRequestKey: EPGRepositoryStatus] = [:]
    var isEmpty: Bool { results.isEmpty }

    func tick() { revision &+= 1 }
    func nextBoundary(after date: Date) -> Date? {
        results.values.flatMap {
            [$0.item.current?.end, $0.item.next?.start, $0.item.next?.end]
                .compactMap { $0 }
        }
        .filter { $0 > date }
        .min()
    }
    func status(_ key: EPGRequestKey) -> EPGRepositoryStatus? { statuses[key] }
    func setStatus(_ status: EPGRepositoryStatus) {
        guard revisions[status.key.source] == status.key.revision else { return }
        statuses[status.key] = status
        tick()
    }

    @discardableResult
    func prepare(source: LiveSourceID, revision: String) -> UUID {
        let sourceKey = EPGSourceKey(source)
        if revisions[sourceKey] == revision, let generation = generations[sourceKey] { return generation }
        remove(source)
        revisions[sourceKey] = revision
        let generation = UUID()
        generations[sourceKey] = generation
        return generation
    }

    @discardableResult
    func publish(_ batch: EPGNowNextBatch, channels: [LiveChannel], source: LiveSourceID,
                 revision: String, generation: UUID, demandRevision: UUID,
                 serviceIncarnation: UUID) -> Bool {
        let sourceKey = EPGSourceKey(source)
        guard revisions[sourceKey] == revision, generations[sourceKey] == generation,
              batch.token.serviceIncarnation == serviceIncarnation,
              batch.token.demandRevision == demandRevision,
              batch.items.count == channels.count else { return false }
        if let priorEpoch = results.first(where: { $0.key.source == sourceKey })?.value.token.sourceEpoch,
           priorEpoch != batch.token.sourceEpoch {
            removeResults(sourceKey)
        }
        for key in order where results[key]?.token.resourceIdentity == batch.token.resourceIdentity
            && results[key]?.token.dataVersion != batch.token.dataVersion {
            results[key] = nil
        }
        order.removeAll { results[$0] == nil }
        for (channel, item) in zip(channels, batch.items) {
            let key = ChannelKey(source: sourceKey, channelID: channel.id)
            let cost = Self.cost(item) + batch.token.resourceIdentity.utf8.count
                + batch.token.sourceEpoch.utf8.count + batch.token.dataVersion.utf8.count + 128
            results[key] = StoredResult(item: item, token: batch.token,
                                        availability: batch.availability, cost: cost)
            order.removeAll { $0 == key }
            order.append(key)
        }
        while order.count > 100 || results.values.reduce(0, { $0 + $1.cost }) > 8 * 1_024 * 1_024 {
            results[order.removeFirst()] = nil
        }
        tick()
        return true
    }

    func remove(_ source: LiveSourceID) {
        let key = EPGSourceKey(source)
        removeResults(key)
        statuses = statuses.filter { $0.key.source != key }
        revisions[key] = nil
        generations[key] = nil
        tick()
    }

    func removeAll() {
        revisions.removeAll()
        generations.removeAll()
        results.removeAll()
        statuses.removeAll()
        order.removeAll()
        tick()
    }

    func removeNativeSources() {
        for key in Array(revisions.keys) where key.kind == .xtream {
            remove(.xtream(key.id))
        }
    }

    func nowNext(channel: LiveChannel, source: LiveSourceID, at date: Date) -> EPGNowNextSnapshot {
        let key = ChannelKey(source: EPGSourceKey(source), channelID: channel.id)
        guard let stored = results[key] else { return EPGNowNextSnapshot() }
        var current = stored.item.current, next = stored.item.next
        if let value = current, !(value.start <= date && date < value.end) { current = nil }
        if current == nil, let value = next, value.start <= date && date < value.end {
            current = value; next = nil
        } else if let value = next, value.start <= date { next = nil }
        return EPGNowNextSnapshot(current: current, next: next, availability: stored.availability)
    }

    private func removeResults(_ source: EPGSourceKey) {
        results = results.filter { $0.key.source != source }
        order.removeAll { $0.source == source }
    }

    #if DEBUG
    var storedResultCountForTesting: Int { results.count }
    func containsForTesting(source: LiveSourceID, channel: LiveChannel) -> Bool {
        results[ChannelKey(source: EPGSourceKey(source), channelID: channel.id)] != nil
    }
    #endif

    private static func cost(_ item: EPGNowNextItem) -> Int {
        [item.current, item.next].compactMap { $0 }.reduce(64) {
            $0 + $1.channelID.utf8.count + $1.title.utf8.count + 96
        }
    }
}

/// Presentation clock only: no per-card tasks, requests, or visibility tracking.
struct EPGTimelineSchedule: TimelineSchedule {
    var boundaries: [Date]
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        AnySequence {
            var next = startDate
            return AnyIterator<Date> {
                let value = next
                next = min(value.addingTimeInterval(mode == .lowFrequency ? 60 : 15),
                           boundaries.filter { $0 > value }.min() ?? .distantFuture)
                return value
            }
        }
    }
}

struct LiveNowNextView: View {
    @ObservedObject var epg: LiveEPGState
    let channel: LiveChannel
    let source: LiveSourceID

    var body: some View {
        let initial = epg.nowNext(channel: channel, source: source, at: Date())
        let boundaries = [initial.current?.end, initial.next?.start, initial.next?.end].compactMap { $0 }
        TimelineView(EPGTimelineSchedule(boundaries: boundaries)) { context in
            let info = epg.nowNext(channel: channel, source: source, at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                if let current = info.current {
                    Text(L10n.string("live.now-playing", fallback: "Now Playing: %@", current.title))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(current.start, style: .time)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                        if let progress = info.progress(at: context.date) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(L10n.string("live.epg.progress", fallback: "Programme progress"))
                        }
                        Text(current.end, style: .time)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    if info.availability == .stale {
                        Text(L10n.string("live.epg.cached", fallback: "Cached"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(emptyLabel(info.availability))
                        .foregroundColor(.secondary)
                }
                if let next = info.next {
                    HStack(spacing: 4) {
                        Text(next.start, style: .time)
                        Text(L10n.string("live.next-program", fallback: "Next: %@", next.title))
                    }
                    .lineLimit(1)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                } else {
                    Text(L10n.string("live.epg.no-next", fallback: "Next: —"))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emptyLabel(_ availability: EPGAvailability) -> String {
        switch availability {
        case .unsupported: return L10n.string("live.epg.unsupported", fallback: "Provider has no programme guide")
        case .failed: return L10n.string("live.epg.unavailable", fallback: "Programme guide unavailable")
        default: return L10n.string("live.epg.no-current", fallback: "No current programme")
        }
    }
}

private struct LiveChannelCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    let channel: LiveChannel
    let artworkURLs: [URL]
    let navigationChannels: [LiveChannel]
    let sourceID: LiveSourceID
    let sourceName: String
    let importedCatalog: AcceptedImportedCatalog?

    @State private var isHovering = false
    @State private var showsDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                channelArtwork

                HStack(alignment: .top) {
                    if let number = channel.number, !number.isEmpty {
                        badge(number)
                    }
                    Spacer()
                    favoriteButton
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(8)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(0.10),
                radius: 4,
                y: 2
            )
            .contentShape(Rectangle())
            .onTapGesture {
                playDefaultRoute()
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    playDefaultRoute()
                } label: {
                    Text(channel.name)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if routeCount > 1 {
                    streamMenu
                } else {
                    Image(systemName: "tv")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help(L10n.string("live.channel", fallback: "Live TV Channel"))
                }
            }

            LiveNowNextView(epg: state.liveEPG, channel: channel, source: sourceID)
        }
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.accentColor.opacity(isHovering ? 0.055 : 0))
                .padding(-6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    Color.accentColor.opacity(isHovering ? 0.30 : 0),
                    lineWidth: 1
                )
                .padding(-6)
        }
        .scaleEffect(isHovering ? 1.015 : 1)
        .offset(y: isHovering ? -1 : 0)
        .shadow(
            color: Color.black.opacity(isHovering ? 0.11 : 0),
            radius: isHovering ? 8 : 0,
            y: isHovering ? 4 : 0
        )
        .zIndex(isHovering ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onAppear {
            state.setEPGChannelVisibility(source: sourceID, channel: channel, visible: true)
        }
        .onDisappear {
            state.setEPGChannelVisibility(source: sourceID, channel: channel, visible: false)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            routeMenuItems
            Divider()
            Button {
                toggleFavorite()
            } label: {
                Label(
                    isFavorite
                        ? L10n.string("live.unfavorite", fallback: "Remove from Favorites")
                        : L10n.string("live.favorite", fallback: "Favorite Channel"),
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }
            Divider()
            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label(L10n.string("live.delete-channel.action", fallback: "Delete Channel…"), systemImage: "trash")
            }
        }
        .confirmationDialog(
            L10n.string("live.delete-channel.title", fallback: "Delete “%@”?", channel.name),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("live.delete-channel.confirm", fallback: "Delete Channel"), role: .destructive) {
                deleteChannel()
            }
            Button(L10n.string(.commonCancel), role: .cancel) {}
        } message: {
            Text(
                L10n.string("live.delete-channel.message", fallback: "This channel will be removed only from the local “%@” source and will not return after a refresh. You can restore it later from Deleted Channels in the toolbar.", sourceName)
            )
        }
    }

    private var channelArtwork: some View {
        ZStack {
            LinearGradient(
                colors: channelArtworkBackgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 240
            )

            RemoteImageCandidates(
                urls: artworkURLs
            ) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .padding(22)
                    .shadow(color: Color.black.opacity(0.34), radius: 4, y: 2)
            } placeholder: {
                VStack(spacing: 7) {
                    Image(systemName: "tv")
                        .font(.system(size: 30, weight: .medium))
                    Text(channel.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundColor(
                    colorScheme == .dark
                        ? Color.white.opacity(0.82)
                        : Color.primary.opacity(0.72)
                )
                .padding(.horizontal, 18)
            }
        }
    }

    private var channelArtworkBackgroundColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.22, green: 0.24, blue: 0.29),
                Color(red: 0.13, green: 0.15, blue: 0.19)
            ]
        }
        return [
            Color(red: 0.94, green: 0.95, blue: 0.97),
            Color(red: 0.82, green: 0.85, blue: 0.90)
        ]
    }

    private var favoriteButton: some View {
        Button {
            toggleFavorite()
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isFavorite ? .yellow : .white)
                .frame(width: 24, height: 24)
                .background(Color.black.opacity(0.44))
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .help(
            isFavorite
                ? L10n.string("live.unfavorite", fallback: "Remove from Favorites")
                : L10n.string("live.favorite", fallback: "Favorite Channel")
        )
    }

    private var streamMenu: some View {
        Menu {
            routeMenuItems
        } label: {
            Text(L10n.string("live.stream-count-short", fallback: "%d streams", routeCount))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.string("live.choose-stream", fallback: "Choose Stream"))
    }

    private var isFavorite: Bool {
        state.isLiveFavorite(sourceID: sourceID, channel: channel)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.48))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private var routeMenuItems: some View {
        if case .imported = sourceID {
            ForEach(importedCatalog?.selections(for: channel) ?? []) { selection in
                Button { play(selection) } label: {
                    Label(selection.stream.name, systemImage: "play.fill")
                }
            }
        } else {
            // Native route IDs retain their provider locator semantics.
            ForEach(channel.streams) { stream in
                Button { playNative(stream) } label: {
                    Label(stream.name, systemImage: "play.fill")
                }
            }
        }
    }

    private var routeCount: Int {
        if case .imported = sourceID { return importedCatalog?.selections(for: channel).count ?? 0 }
        return channel.streams.count
    }

    private func playDefaultRoute() {
        if case .imported = sourceID {
            guard let selection = importedCatalog?.selections(for: channel).first else { return }
            play(selection)
        } else {
            playNative(channel.streams.first)
        }
    }

    private func play(_ selection: ImportedRouteSelection) {
        Task { await state.playImportedLive(selection, navigationChannels: navigationChannels) }
    }

    private func playNative(_ stream: LiveStream?) {
        guard let stream else { return }
        Task {
            await state.playLive(
                channel: channel,
                stream: stream,
                sourceID: sourceID,
                navigationChannels: navigationChannels
            )
        }
    }

    private func toggleFavorite() {
        Task {
            await state.toggleLiveFavorite(
                sourceID: sourceID,
                channel: channel
            )
        }
    }

    private func deleteChannel() {
        Task {
            await state.deleteLiveChannel(
                sourceID: sourceID,
                sourceName: sourceName,
                channel: channel
            )
        }
    }
}

enum LiveChannelLogoResolver {
    private static let fallbackBaseURL = URL(
        string: "https://upload.112114.xyz/logo/"
    )!

    static func urls(
        for channel: LiveChannel,
        allowsFallback: Bool = true
    ) -> [URL] {
        var values: [URL] = []
        if let explicit = channel.logoURL {
            values.append(explicit)
        }
        // Provider catalogs already validate their explicit artwork URLs.
        // Never disclose Xtream channel names to the imported-source fallback
        // service or invent third-party artwork requests for these catalogs.
        guard allowsFallback else { return values }

        let names = [channel.tvgID, channel.tvgName, channel.name]
            .compactMap { $0 }
        for name in names {
            guard let key = lookupKey(name) else { continue }
            let url = fallbackBaseURL.appendingPathComponent("\(key).png")
            if !values.contains(url) {
                values.append(url)
            }
        }
        return values
    }

    static func lookupKey(_ rawName: String) -> String? {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        name = name.replacingOccurrences(
            of: #"^[0-9]{1,4}\s+"#,
            with: "",
            options: .regularExpression
        )
        name = name.replacingOccurrences(
            of: #"[（(][^）)]*[）)]"#,
            with: "",
            options: .regularExpression
        )

        let compact = name
            .uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let range = compact.range(
            of: #"CCTV(?:4K|[0-9]{1,2}\+?)"#,
            options: .regularExpression
        ) {
            return String(compact[range])
        }

        name = name.replacingOccurrences(
            of: #"(?i)(超高清|高清|标清|频道|HD)$"#,
            with: "",
            options: .regularExpression
        )
        name = name.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "-_·")
            )
        )
        return name.isEmpty ? nil : name
    }
}

final class LiveChannelLogoURLCache: ObservableObject {
    private struct Key: Hashable {
        let logoURL: URL?
        let tvgID: String?
        let tvgName: String?
        let name: String
        let allowsFallback: Bool
    }

    private var values: [Key: [URL]] = [:]
    private(set) var computationCount = 0

    func urls(
        for channel: LiveChannel,
        allowsFallback: Bool = true
    ) -> [URL] {
        let key = Key(
            logoURL: channel.logoURL,
            tvgID: channel.tvgID,
            tvgName: channel.tvgName,
            name: channel.name,
            allowsFallback: allowsFallback
        )
        if let cached = values[key] {
            return cached
        }
        let urls = LiveChannelLogoResolver.urls(
            for: channel,
            allowsFallback: allowsFallback
        )
        values[key] = urls
        computationCount += 1
        return urls
    }
}

struct LiveSourceImportSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case remote
        case pasted

        var id: String { rawValue }

        var title: String {
            switch self {
            case .remote: return "URL"
            case .pasted: return L10n.string("live.source.pasted", fallback: "Pasted Content")
            }
        }
    }

    @EnvironmentObject private var state: AppState
    @Binding var isPresented: Bool
    @State private var mode: Mode = .remote
    @State private var name = ""
    @State private var remoteURL = ""
    @State private var pastedText = ""
    @State private var baseURL = ""
    @State private var importPhase: LiveSourceImportPhase?
    @State private var submissionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("live.add.title", fallback: "Add Live TV Source"))
                .font(.title2)
            Text(L10n.string("live.add.subtitle", fallback: "Live TV sources are stored separately from video provider configurations. M3U, M3U8, TXT, and JSON are supported."))
                .font(.callout)
                .foregroundColor(.secondary)
            Picker(L10n.string("common.method", fallback: "Method"), selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSubmitting)
            TextField(L10n.string("live.add.name.optional", fallback: "Source Name (Optional)"), text: $name)
                .disabled(isSubmitting)
            if mode == .remote {
                TextField("https://example.com/channels.m3u", text: $remoteURL)
                    .disabled(isSubmitting)
                Text(L10n.string("live.add.remote.note", fallback: "HTTP and HTTPS only. Responses are limited to 32 MiB with a 30-second timeout."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                TextEditor(text: $pastedText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                    .disabled(isSubmitting)
                TextField(L10n.string("live.add.base-url.optional", fallback: "Relative Channel Base URL (Optional)"), text: $baseURL)
                    .disabled(isSubmitting)
            }
            Spacer()
            if let importPhase {
                HStack(spacing: 8) {
                    AppActivityIndicator(size: .small)
                    Text(importPhase.title)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(L10n.string(.commonCancel)) {
                    submissionTask?.cancel()
                    submissionTask = nil
                    isPresented = false
                }
                .disabled(isCommitInProgress)
                Button {
                    importValue()
                } label: {
                    if isSubmitting {
                        HStack(spacing: 6) {
                            AppActivityIndicator(size: .small)
                            Text(L10n.string("live.add.adding", fallback: "Adding"))
                        }
                    } else {
                        Text(L10n.string("live.add.action", fallback: "Add"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
            }
        }
        .padding(22)
        .interactiveDismissDisabled(isCommitInProgress)
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
        }
    }

    private var canImport: Bool {
        guard !isSubmitting else { return false }
        switch mode {
        case .remote:
            guard let url = URL(string: normalizedRemoteURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return false
            }
            return true
        case .pasted:
            return !pastedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    private var isSubmitting: Bool {
        submissionTask != nil
    }

    private var isCommitInProgress: Bool {
        guard isSubmitting else { return false }
        return importPhase == .saving || importPhase == .publishing
    }

    private var normalizedRemoteURL: String {
        remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importValue() {
        let input: LiveSourceInput
        switch mode {
        case .remote:
            guard let url = URL(string: normalizedRemoteURL) else { return }
            input = .remote(url)
        case .pasted:
            input = .pasted(
                text: pastedText,
                baseURL: baseURL.isEmpty ? nil : URL(string: baseURL)
            )
        }
        importPhase = mode == .remote ? .downloadingAndParsing : .parsing
        submissionTask = Task {
            let succeeded = await state.importLiveSource(
                source: input,
                name: name
            ) { phase in
                importPhase = phase
            }
            guard !Task.isCancelled else { return }
            submissionTask = nil
            if succeeded {
                isPresented = false
            } else {
                importPhase = nil
            }
        }
    }
}
