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

    /// Deliberately not published: changing sections must not invalidate the
    /// mounted live grid. It only gates source-loading side effects.
    var isActive = false

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
        }
        .onChange(of: navigation.selectedSection) { section in
            updateActivation(for: section)
        }
        .onChange(of: session.selectedSourceID) { _ in
            session.searchText = ""
            session.selectedGroupID = nil
            session.showsFavoritesOnly = false
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
        .onChange(of: state.shortcutLiveSourceSelection) { request in
            guard let request,
                  state.liveSourceDescriptors.contains(where: {
                      $0.id == request.sourceID
                  }) else { return }
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
            if let catalog = state.liveCatalog(for: source.id) {
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

    private func playlistContent(
        _ playlist: LiveCatalogSnapshot,
        sourceID: LiveSourceID,
        sourceName: String
    ) -> some View {
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
        let programmeDate = Date()
        return GeometryReader { viewport in
            ScrollView {
                BrowserToolbarScrollMarker(
                    coordinateSpaceName: channelScrollCoordinateSpace
                )
                VStack(spacing: 0) {
                    liveSourceBackgroundStatus(sourceID: sourceID)

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
                                let programmes = state.liveProgrammes(
                                    for: channel,
                                    sourceID: sourceID,
                                    at: programmeDate
                                )
                                LiveChannelCard(
                                    channel: channel,
                                    artworkURLs: logoURLCache.urls(
                                        for: channel,
                                        allowsFallback: allowsLogoFallback
                                    ),
                                    navigationChannels: channels,
                                    sourceID: sourceID,
                                    sourceName: sourceName,
                                    currentEPGProgramme: programmes.current,
                                    nextEPGProgramme: programmes.next
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

    @ViewBuilder
    private func liveSourceBackgroundStatus(sourceID: LiveSourceID) -> some View {
        if let message = state.liveCatalogError(for: sourceID) {
            backgroundStatusLabel(
                message,
                systemImage: "exclamationmark.triangle",
                color: .orange
            )
        }
        // Xtream Basic Live deliberately has no EPG or background channel
        // probing. Keep the existing imported-source status domain intact.
        if case .imported(let importedID) = sourceID {
            importedSourceBackgroundStatus(sourceID: importedID)
        }
    }

    @ViewBuilder
    private func importedSourceBackgroundStatus(sourceID: UUID) -> some View {
        if let epgStatus = state.liveSourceEPGStatuses[sourceID] {
            switch epgStatus {
            case .loading:
                backgroundStatusLabel(
                    L10n.string("live.epg.loading", fallback: "Downloading and preparing the program guide in the background…"),
                    systemImage: "clock.arrow.circlepath",
                    color: .secondary,
                    showsProgress: true
                )
            case .ready:
                backgroundStatusLabel(
                    L10n.string("live.epg.ready", fallback: "Program guide ready"),
                    systemImage: "checkmark.circle",
                    color: .green
                )
            case .failed(let message):
                backgroundStatusLabel(
                    L10n.string("live.epg.failed", fallback: "EPG unavailable: %@", message),
                    systemImage: "exclamationmark.triangle",
                    color: .orange
                )
            }
        }

        if let validation = state.liveSourceValidationStatuses[sourceID] {
            switch validation {
            case .checking(let completed, let total):
                backgroundStatusLabel(
                    L10n.string("live.health-check.progress", fallback: "Checking channels in the background: %d/%d", completed, total),
                    systemImage: "waveform.path.ecg",
                    color: .secondary,
                    showsProgress: true
                )
            case .completed(let removed, let total):
                backgroundStatusLabel(
                    removed == 0
                        ? L10n.string("live.health-check.clean", fallback: "Checked %d channels; no confirmed failures found", total)
                        : L10n.string("live.health-check.removed", fallback: "Checked %d channels; removed %d recoverable failures", total, removed),
                    systemImage: removed == 0
                        ? "checkmark.circle"
                        : "trash.slash",
                    color: .secondary
                )
            case .failed(let message):
                backgroundStatusLabel(
                    L10n.string("live.health-check.failed", fallback: "Background channel check did not finish: %@", message),
                    systemImage: "exclamationmark.triangle",
                    color: .orange
                )
            }
        }
    }

    private func backgroundStatusLabel(
        _ title: String,
        systemImage: String,
        color: Color,
        showsProgress: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                AppActivityIndicator(size: .mini)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
                .lineLimit(2)
        }
        .font(.caption)
        .foregroundColor(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(color.opacity(0.07))
    }

    private var selectedSource: LiveSourceDescriptor? {
        guard let selectedSourceID = session.selectedSourceID else { return nil }
        return state.liveSourceDescriptors.first { $0.id == selectedSourceID }
    }

    private var selectedCatalog: LiveCatalogSnapshot? {
        guard let selectedSourceID = session.selectedSourceID else { return nil }
        return state.liveCatalog(for: selectedSourceID)
    }

    private func filteredChannels(
        _ channels: [LiveChannel],
        sourceID: LiveSourceID
    ) -> [LiveChannel] {
        let query = session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return channels.filter { channel in
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
    }

    private func selectFirstSourceIfNeeded() {
        session.reconcileSources(state.liveSourceDescriptors)
    }

    private func updateActivation(for section: AppSection) {
        session.isActive = section == .live
        guard session.isActive else { return }

        let previousSourceID = session.selectedSourceID
        selectFirstSourceIfNeeded()
        if previousSourceID == session.selectedSourceID {
            Task { await loadSelectedIfNeeded() }
        }
    }

    private func loadSelectedIfNeeded() async {
        guard let source = selectedSource,
              state.liveCatalog(for: source.id) == nil,
              !state.isLiveCatalogLoading(source.id) else {
            return
        }
        await state.loadLiveSource(source.id)
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
                let groups = (state.liveCatalog(for: source.id)?.groups ?? [])
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

private struct LiveChannelCard: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    let channel: LiveChannel
    let artworkURLs: [URL]
    let navigationChannels: [LiveChannel]
    let sourceID: LiveSourceID
    let sourceName: String
    let currentEPGProgramme: EPGProgramme?
    let nextEPGProgramme: EPGProgramme?

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
                play(channel.streams.first)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    play(channel.streams.first)
                } label: {
                    Text(channel.name)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if channel.streams.count > 1 {
                    streamMenu
                } else {
                    Image(systemName: "tv")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help(L10n.string("live.channel", fallback: "Live TV Channel"))
                }
            }

            if let programmeSummary {
                Text(programmeSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let nextProgramme {
                Text(L10n.string("live.next-program", fallback: "Next: %@", nextProgramme))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
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
        .onHover { isHovering = $0 }
        .contextMenu {
            ForEach(channel.streams) { stream in
                Button {
                    play(stream)
                } label: {
                    Label(stream.name, systemImage: "play.fill")
                }
            }
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
            ForEach(channel.streams) { stream in
                Button {
                    play(stream)
                } label: {
                    Label(stream.name, systemImage: "play.fill")
                }
            }
        } label: {
            Text(L10n.string("live.stream-count-short", fallback: "%d streams", channel.streams.count))
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

    private var programmeSummary: String? {
        if let current = currentEPGProgramme {
            return L10n.string("live.now-playing", fallback: "Now Playing: %@", current.title)
        }
        guard channel.streams.count > 1 else { return nil }
        let format = channel.streams.first?.format?.uppercased()
            ?? L10n.string("live.format", fallback: "Live")
        return L10n.string("live.format-stream-count", fallback: "%@ · %d streams", format, channel.streams.count)
    }

    private var nextProgramme: String? {
        nextEPGProgramme?.title
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

    private func play(_ stream: LiveStream?) {
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
