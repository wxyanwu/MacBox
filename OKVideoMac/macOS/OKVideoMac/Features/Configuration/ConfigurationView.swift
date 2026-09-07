import AppKit
import OKVideoCore
import OKVideoPersistence
import SwiftUI
import UniformTypeIdentifiers

enum ImportURLInput {
    /// Removes only leading/trailing whitespace and newline scalars. Internal
    /// userinfo, host, path, query, and fragment bytes remain untouched.
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func httpURL(from value: String) -> URL? {
        let value = normalized(value)
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }
}

/// A narrowly scoped AppKit bridge for the URL field. `NSTextFieldDelegate`
/// commits the field editor's value to SwiftUI in the same change event, so a
/// paste does not depend on a later focus change to redraw or validate.
struct ImportURLTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("configuration-import-url")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        guard field.stringValue != text else { return }
        field.stringValue = text
        if let editor = field.currentEditor(), editor.string != text {
            editor.string = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let value = field.currentEditor()?.string ?? field.stringValue
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
        }
    }
}

struct ConfigurationView: View {
    @EnvironmentObject private var state: AppState
    let embedded: Bool
    @State private var showingImport = false
    @State private var showingFileImporter = false
    @State private var showingCatPawProfileImporter = false
    @State private var pendingDelete: StoredConfiguration?

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded {
                embeddedContent
            } else {
                standaloneContent
            }
        }
        .navigationTitle(
            embedded
                ? L10n.string(.sectionSettings)
                : L10n.string("configuration.title", fallback: "Video Providers")
        )
        .sheet(isPresented: $showingImport) {
            ConfigurationImportSheet(isPresented: $showingImport)
                .environmentObject(state)
                .frame(width: 620, height: 470)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        _ = await state.importConfiguration(
                            source: .localFile(url),
                            name: url.deletingPathExtension().lastPathComponent
                        )
                    }
                }
            case .failure(let error):
                state.presentedError = UserFacingError(
                    title: L10n.string("configuration.file-selection.failed", fallback: "Unable to Select File"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
        .fileImporter(
            isPresented: $showingCatPawProfileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await state.importCatPawProfile(from: url) }
                }
            case .failure(let error):
                state.presentedError = UserFacingError(
                    title: L10n.string("configuration.catpaw-selection.failed", fallback: "Unable to Select CatPaw Configuration"),
                    message: RuntimeUserFacingMessageMapper.message(for: error)
                )
            }
        }
        .alert(
            item: $pendingDelete
        ) { record in
            Alert(
                title: Text(L10n.string("configuration.delete.title", fallback: "Delete “%@”?", record.name)),
                message: Text(L10n.string("configuration.delete.message", fallback: "Favorites and history will not be deleted with the configuration.")),
                primaryButton: .destructive(Text(L10n.string("common.delete", fallback: "Delete"))) {
                    Task { await state.deleteConfiguration(record.id) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var standaloneContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingImport = true
                } label: {
                    Label(L10n.string("configuration.import", fallback: "Import Video Provider Configuration"), systemImage: "plus")
                }
                Button {
                    showingFileImporter = true
                } label: {
                    Label(L10n.string("configuration.choose-file", fallback: "Choose Video Provider Configuration File"), systemImage: "folder")
                }
                Button {
                    showingCatPawProfileImporter = true
                } label: {
                    Label(L10n.string("configuration.import-catpaw", fallback: "Import CatPaw Configuration"), systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(!state.canImportCatPawProfile)
                Spacer()
                Button {
                    Task { await state.refreshActiveConfiguration() }
                } label: {
                    Label(L10n.string("configuration.refresh-current", fallback: "Refresh Current Video Provider Configuration"), systemImage: "arrow.clockwise")
                }
                .disabled(state.activeConfigurationRecord?.sourceKind != .remote)
            }
            .padding()

            Divider()

            SourceSwitchFeedbackView(
                feedback: state.configurationSwitchFeedback
            )
            .padding(.horizontal)
            .padding(.top, 8)

            if state.configurations.isEmpty {
                EmptyStateView(
                    systemImage: "doc.badge.plus",
                    title: L10n.string("configuration.empty.title", fallback: "No Video Provider Configurations"),
                    message: L10n.string("configuration.empty.message", fallback: "Video provider configurations are managed here. Add Live TV sources separately in Settings → Live TV Sources.")
                )
            } else {
                List {
                    ForEach(state.configurations) { record in
                        ConfigurationRow(record: record) {
                            Task { await state.activateConfiguration(record.id) }
                        } export: {
                            export(record)
                        } delete: {
                            pendingDelete = record
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var embeddedContent: some View {
        SourceSwitchFeedbackView(
            feedback: state.configurationSwitchFeedback
        )
        .padding(.bottom, 4)

        SettingsSectionTitle(L10n.string("configuration.import-update.section", fallback: "Import & Update"))
        SettingsCard {
            SettingsControlRow(
                icon: "plus",
                color: .indigo,
                title: L10n.string("configuration.import", fallback: "Import Video Provider Configuration"),
                subtitle: L10n.string("configuration.import.subtitle", fallback: "Import a video provider configuration from a URL or pasted content.")
            ) {
                Button(L10n.string("configuration.import.action", fallback: "Import…")) {
                    showingImport = true
                }
            }

            SettingsDivider()

            SettingsControlRow(
                icon: "person.crop.circle.badge.plus",
                color: .orange,
                title: L10n.string("configuration.import-catpaw", fallback: "Import CatPaw Configuration"),
                subtitle: L10n.string("configuration.import-catpaw.subtitle", fallback: "Choose test0.db.json. Accounts and mounts are written only to the protected runtime profile.")
            ) {
                Button(L10n.string("common.choose", fallback: "Choose…")) {
                    showingCatPawProfileImporter = true
                }
                .disabled(!state.canImportCatPawProfile)
            }

            SettingsDivider()

            SettingsControlRow(
                icon: "folder.fill",
                color: .blue,
                title: L10n.string("configuration.choose-file.title", fallback: "Choose a Configuration File"),
                subtitle: L10n.string("configuration.choose-file.subtitle", fallback: "Import JSON or text configuration from this Mac")
            ) {
                Button(L10n.string("common.choose", fallback: "Choose…")) {
                    showingFileImporter = true
                }
            }

            SettingsDivider()

            SettingsControlRow(
                icon: "arrow.clockwise",
                color: .teal,
                title: L10n.string("configuration.refresh.title", fallback: "Refresh Current Configuration"),
                subtitle: L10n.string("configuration.refresh.subtitle", fallback: "Download and load the current remote configuration again")
            ) {
                Button(L10n.string("common.refresh", fallback: "Refresh")) {
                    Task { await state.refreshActiveConfiguration() }
                }
                .disabled(state.activeConfigurationRecord?.sourceKind != .remote)
            }
        }

        SettingsSectionTitle(L10n.string("configuration.imported.section", fallback: "Imported Configurations"))
        SettingsCard {
            if state.configurations.isEmpty {
                Label(
                    L10n.string("configuration.imported.empty", fallback: "No video provider configurations yet. Import one above."),
                    systemImage: "doc.badge.plus"
                )
                .foregroundColor(.secondary)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(state.configurations.enumerated()), id: \.element.id) {
                    index, record in
                    ConfigurationRow(
                        record: record,
                        cardStyle: true
                    ) {
                        Task { await state.activateConfiguration(record.id) }
                    } export: {
                        export(record)
                    } delete: {
                        pendingDelete = record
                    }

                    if index < state.configurations.count - 1 {
                        SettingsDivider()
                    }
                }
            }
        }
    }

    private func export(_ record: StoredConfiguration) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(record.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.exportData(for: record, to: url)
        } catch {
            state.presentedError = UserFacingError(
                title: L10n.string("configuration.export.failed", fallback: "Export Failed"),
                message: RuntimeUserFacingMessageMapper.message(for: error)
            )
        }
    }
}

private struct ConfigurationRow: View {
    let record: StoredConfiguration
    var cardStyle = false
    let activate: () -> Void
    let export: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if cardStyle {
                SettingsRowIcon(
                    systemImage: record.isActive
                        ? "checkmark.circle.fill"
                        : "doc.text.fill",
                    color: record.isActive ? .green : .indigo
                )
            } else {
                Image(systemName: record.isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(record.isActive ? .accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(.headline)
                Text(sourceDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(
                    record.updatedAt.formatted(
                        Date.FormatStyle(
                            date: .abbreviated,
                            time: .shortened,
                            locale: L10n.locale
                        )
                    )
                )
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if record.isActive, cardStyle {
                Text(L10n.string("configuration.active", fallback: "Active"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !record.isActive {
                Button(L10n.string("configuration.activate", fallback: "Activate"), action: activate)
            }
            Button(L10n.string("common.export", fallback: "Export"), action: export)
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, cardStyle ? 16 : 0)
        .padding(.vertical, cardStyle ? 14 : 5)
    }

    private var sourceDescription: String {
        switch record.sourceKind {
        case .remote:
            guard let value = record.sourceValue,
                  let url = URL(string: value) else {
                return L10n.string("configuration.source.remote-url", fallback: "Remote URL")
            }
            return LogRedactor.url(url)
        case .localFile: return record.sourceValue ?? L10n.string("configuration.source.local-file", fallback: "Local File")
        case .pasted: return L10n.string("configuration.source.pasted", fallback: "Pasted Content")
        }
    }
}

private struct ConfigurationImportSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case remote
        case pasted

        var id: String { rawValue }

        var title: String {
            switch self {
            case .remote: return "URL"
            case .pasted:
                return L10n.string("configuration.source.pasted", fallback: "Pasted Content")
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
    @State private var importPhase: ConfigurationImportPhase?
    @State private var submissionTask: Task<Void, Never>?
    @State private var activeOperationID: UUID?
    @State private var importError: UserFacingError?
    @State private var importSummary: ConfigurationImportSummary?
    @State private var liveSyncResult: EmbeddedLiveSourceSyncResult?
    @State private var liveSyncTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("configuration.import", fallback: "Import Video Provider Configuration"))
                    .font(.title2)
                Text(L10n.string("configuration.import.formats", fallback: "Supports JSON, limited JSONC, image, and Base64-wrapped formats. You can sync included Live TV lists after import."))
                    .font(.callout)
                    .foregroundColor(.secondary)
                Picker(L10n.string("common.method", fallback: "Method"), selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isSubmitting)

                TextField(L10n.string("configuration.name.optional", fallback: "Configuration Name (Optional)"), text: $name)
                    .disabled(isSubmitting)
                if mode == .remote {
                    ImportURLTextField(
                        text: $remoteURL,
                        placeholder: "https://example.com/config.json"
                    )
                    .frame(height: 22)
                    .disabled(isSubmitting)
                    Text(L10n.string("configuration.remote.security-note", fallback: "Standard configurations allow HTTP and HTTPS. HTTPS is recommended for remote Node bundles. For an HTTP bundle, append #sha256=<64-character hash> to the .js.md5 URL; &source=<source ID>&version=<version> are optional."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    TextEditor(text: $pastedText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 240)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                        .disabled(isSubmitting)
                    TextField(L10n.string("configuration.base-url.optional", fallback: "Relative Resource Base URL (Optional)"), text: $baseURL)
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
                        cancelOrDismiss()
                    }
                    .disabled(isCommitInProgress)
                    Button {
                        importValue()
                    } label: {
                        if isSubmitting {
                            HStack(spacing: 6) {
                                AppActivityIndicator(size: .small)
                                Text(L10n.string("configuration.importing", fallback: "Importing"))
                            }
                        } else {
                            Text(L10n.string("configuration.import.action-short", fallback: "Import"))
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canImport)
                }
            }

            if let importSummary {
                completionView(importSummary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .padding(22)
        .interactiveDismissDisabled(isCommitInProgress)
        .onDisappear {
            detachActiveImport()
        }
        .alert(item: $importError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text(L10n.string(.commonOK)))
            )
        }
    }

    private var canImport: Bool {
        guard !isSubmitting else { return false }
        switch mode {
        case .remote:
            return ImportURLInput.httpURL(from: remoteURL) != nil
        case .pasted:
            return !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var isSubmitting: Bool {
        submissionTask != nil
    }

    private var isCommitInProgress: Bool {
        guard isSubmitting else { return false }
        return importPhase == .saving || importPhase == .activating
    }

    private func importValue() {
        guard !isSubmitting else { return }
        let source: ConfigurationSource
        switch mode {
        case .remote:
            let normalized = ImportURLInput.normalized(remoteURL)
            guard let url = ImportURLInput.httpURL(from: normalized) else { return }
            remoteURL = normalized
            source = .remote(url)
        case .pasted:
            let normalizedBaseURL = ImportURLInput.normalized(baseURL)
            source = .pasted(
                text: pastedText,
                baseURL: normalizedBaseURL.isEmpty ? nil : URL(string: normalizedBaseURL)
            )
        }
        let operationID = UUID()
        activeOperationID = operationID
        importError = nil
        importPhase = initialPhase(for: source)
        submissionTask = Task {
            let result = await state.importConfigurationForSheet(
                source: source,
                name: name,
                progress: { phase in
                    guard activeOperationID == operationID,
                          !Task.isCancelled else { return }
                    importPhase = phase
                },
                onCommitStarted: {
                    guard activeOperationID == operationID,
                          !Task.isCancelled else { return }
                    importPhase = .saving
                }
            )
            guard activeOperationID == operationID else { return }
            activeOperationID = nil
            submissionTask = nil
            switch result {
            case .success(let summary) where !Task.isCancelled:
                importPhase = nil
                importSummary = summary
            case .failure(let error):
                importPhase = nil
                importError = error
            case .cancelled, .success(_):
                importPhase = nil
            }
        }
    }

    private func cancelOrDismiss() {
        if isSubmitting && !isCommitInProgress {
            cancelActiveImport()
        }
        isPresented = false
    }

    private func cancelActiveImport() {
        guard !isCommitInProgress else { return }
        activeOperationID = nil
        let task = submissionTask
        submissionTask = nil
        importPhase = nil
        task?.cancel()
    }

    private func detachActiveImport() {
        let shouldCancel = isSubmitting && !isCommitInProgress
        activeOperationID = nil
        let task = submissionTask
        submissionTask = nil
        importPhase = nil
        if shouldCancel {
            task?.cancel()
        }
        liveSyncTask?.cancel()
        liveSyncTask = nil
    }

    @ViewBuilder
    private func completionView(
        _ summary: ConfigurationImportSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.string("configuration.import.success", fallback: "Configuration Imported"), systemImage: "checkmark.circle.fill")
                .font(.title2)
                .foregroundColor(.green)
            Text(summary.configurationName)
                .font(.headline)
            Text(
                L10n.string(
                    "configuration.import.summary",
                    fallback: "%d providers found: %d require Android Bridge, %d use JavaScript, and %d use other built-in capabilities.",
                    summary.siteCount,
                    summary.javaDexSiteCount,
                    summary.javaScriptSiteCount,
                    summary.otherSiteCount
                )
            )
            .fixedSize(horizontal: false, vertical: true)

            if summary.androidBridgeUnavailable,
               summary.javaDexSiteCount > 0 {
                Label(
                    L10n.string("configuration.import.android-unavailable", fallback: "Android Bridge is unavailable. %d imported Java/Dex providers cannot run yet.", summary.javaDexSiteCount),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if summary.liveCount > 0 {
                Text(L10n.string(
                    "configuration.import.live-summary",
                    fallback: "%d Live TV configurations found; %d can be synced to Live TV Sources.%@",
                    summary.liveCount,
                    summary.synchronizableLiveCount,
                    summary.unsupportedLiveCount > 0
                        ? L10n.string("configuration.import.live-unsupported", fallback: " %d dynamic Live TV plugins cannot be synced yet.", summary.unsupportedLiveCount)
                        : ""
                ))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let liveSyncResult {
                Label(
                    L10n.string(
                        "configuration.import.live-sync-summary",
                        fallback: "Live TV sync finished: %d added, %d skipped, %d failed.",
                        liveSyncResult.importedCount,
                        liveSyncResult.skippedCount,
                        liveSyncResult.failedCount
                    ),
                    systemImage: liveSyncResult.failedCount == 0
                        ? "checkmark.circle"
                        : "exclamationmark.triangle"
                )
                .foregroundColor(
                    liveSyncResult.failedCount == 0 ? .secondary : .orange
                )
            }

            Spacer()
            HStack {
                Spacer()
                Button(L10n.string("common.done", fallback: "Done")) {
                    isPresented = false
                }
                .disabled(liveSyncTask != nil)
                if summary.synchronizableLiveCount > 0,
                   liveSyncResult == nil {
                    Button {
                        synchronizeLives(from: summary)
                    } label: {
                        if liveSyncTask != nil {
                            HStack(spacing: 6) {
                                AppActivityIndicator(size: .small)
                                Text(L10n.string("configuration.syncing", fallback: "Syncing"))
                            }
                        } else {
                            Text(L10n.string("configuration.sync-live", fallback: "Sync Live TV Sources"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(liveSyncTask != nil)
                }
            }
        }
    }

    private func synchronizeLives(
        from summary: ConfigurationImportSummary
    ) {
        guard liveSyncTask == nil else { return }
        liveSyncTask = Task {
            let result = await state.synchronizeEmbeddedLiveSources(
                configurationID: summary.configurationID
            )
            guard !Task.isCancelled else { return }
            liveSyncResult = result
            liveSyncTask = nil
        }
    }

    private func initialPhase(
        for source: ConfigurationSource
    ) -> ConfigurationImportPhase {
        if case .remote(let url) = source {
            return NodeBundleRuntimeService.supports(url)
                ? .startingNodeRuntime
                : .downloadingAndParsing
        }
        return .parsing
    }
}
