import RelayProtocol
import RelayUI
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Tab = .general
    @State private var tooltips = TooltipPresenter()

    enum Tab: String, CaseIterable, Identifiable {
        case general
        case shortcuts
        case notifications
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .notifications: "Notifications"
            case .about: "About"
            }
        }

        var symbolName: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .notifications: "bell"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            RelayDivider(axis: .vertical)
            content
        }
        .background(Theme.Palette.base)
        // Up and down change section. Everything inside a section is a standard
        // control, so Tab reaches it once macOS keyboard navigation is on;
        // arrows are for the one list that is ours.
        .background {
            KeyCaptureView(
                onMoveDown: { moveSection(by: 1) },
                onMoveUp: { moveSection(by: -1) }
            )
        }
        .tooltipRoot(tooltips)
    }

    private func moveSection(by offset: Int) {
        let tabs = Tab.allCases
        guard let current = tabs.firstIndex(of: selection) else { return }
        selection = tabs[ListNavigation.movingRow(
            ListFocus(row: current),
            by: offset,
            rowCount: tabs.count
        ).row]
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Tab.allCases) { tab in
                SidebarRow(
                    title: relayLocalized(tab.title),
                    systemImage: tab.symbolName,
                    isSelected: selection == tab,
                    action: { selection = tab }
                )
            }
            Spacer()
        }
        .padding(Theme.Spacing.small)
        .frame(width: 176)
        .background(Theme.Palette.sidebar)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general: GeneralSettingsPane()
        case .shortcuts: ShortcutSettingsPane()
        case .notifications: NotificationSettingsPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model

    /// Written without a trailing zero, since half a point is a real setting
    /// and `12.0 pt` reads like a rounding error.
    private var sizeLabel: String {
        let size = model.terminalFontSize
        return String(format: size == size.rounded() ? "%.0f pt" : "%.1f pt", size)
    }

    /// Says that the GPU path is running only once a terminal is actually on
    /// it. Before that there is nothing to report — a machine that cannot
    /// manage Metal is indistinguishable from one with no terminal open yet,
    /// and guessing between them would put a claim on screen rather than a
    /// reading.
    private var rendererDetail: String {
        model.terminalUsesGPURendering && model.isDrawingTerminalsOnGPU
            ? relayLocalized("Drawing on the GPU")
            : relayLocalized("What keeps a long scroll smooth. Turn it off if the terminal draws wrongly")
    }

    var body: some View {
        SettingsScroll(title: relayLocalized("General")) {
            SettingsGroup(relayLocalized("Appearance")) {
                SettingsRow(
                    title: relayLocalized("Language"),
                    detail: relayLocalized("Applies immediately, no restart needed")
                ) {
                    Picker("", selection: Binding(
                        get: { model.language },
                        set: { model.setLanguage($0) }
                    )) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            SettingsGroup(relayLocalized("Terminal")) {
                SettingsRow(
                    title: relayLocalized("Text size"),
                    detail: relayLocalized("Applies to every terminal at once")
                ) {
                    HStack(spacing: Theme.Spacing.xsmall) {
                        Text(verbatim: sizeLabel)
                            .font(Theme.Typography.rowSecondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .monospacedDigit()
                        RelayButton("−") { model.stepTerminalFontSize(by: -1) }
                        RelayButton("+") { model.stepTerminalFontSize(by: 1) }
                        RelayButton(relayLocalized("Reset")) { model.resetTerminalFontSize() }
                    }
                }
                SettingsRow(
                    title: relayLocalized("Draw on the GPU"),
                    detail: rendererDetail
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.terminalUsesGPURendering },
                        set: { model.setTerminalUsesGPURendering($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            SettingsGroup(relayLocalized("Workspace")) {
                SettingsRow(
                    title: relayLocalized("Projects"),
                    detail: String(format: relayLocalized("Projects: %d"), model.projects.count)
                ) {
                    RelayButton(relayLocalized("Add Project…")) { model.presentModal(.addProject) }
                }
                SettingsRow(
                    title: relayLocalized("Status bar"),
                    detail: relayLocalized("Shows what each agent has left of its rate limits")
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.showsStatusBar },
                        set: { model.setShowsStatusBar($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                SettingsRow(
                    title: relayLocalized("Sidebar width"),
                    detail: "\(Int(model.sidebarWidth)) pt"
                ) {
                    RelayButton(relayLocalized("Reset")) {
                        model.sidebarWidth = Theme.Metrics.sidebarWidth
                        model.persist()
                    }
                }
            }

            SettingsGroup(relayLocalized("Session presets")) {
                ForEach(model.presets) { preset in
                    SettingsRow(title: preset.name, detail: preset.subtitle) {
                        HStack(spacing: Theme.Spacing.xsmall) {
                            RelayButton(relayLocalized("Edit…")) { model.presentModal(.presetEditor(presetID: preset.id)) }
                            if !preset.isProtected {
                                IconButton(systemImage: "trash", help: relayLocalized("Remove")) {
                                    model.removePreset(preset)
                                }
                            }
                        }
                    }
                }

                SettingsRow(
                    title: relayLocalized("Add a preset"),
                    detail: relayLocalized("Start from a template or write your own command")
                ) {
                    HStack(spacing: Theme.Spacing.xsmall) {
                        RelayButton(relayLocalized("Reset to defaults")) { model.resetPresets() }
                        RelayButton(relayLocalized("Add…"), kind: .primary) { model.presentModal(.presetEditor(presetID: nil)) }
                    }
                }
            }

            SettingsGroup(relayLocalized("Session daemon")) {
                SettingsRow(
                    title: relayLocalized("Status"),
                    detail: model.connectionState.isConnected
                        ? relayLocalized("Connected — sessions keep running when Relay is closed")
                        : relayLocalized("Disconnected")
                ) {
                    if !model.connectionState.isConnected {
                        RelayButton(relayLocalized("Reconnect"), kind: .primary) { model.retryConnection() }
                    }
                }
                SettingsRow(
                    title: relayLocalized("Logs"),
                    detail: RelayPaths.daemonLogURL.path
                ) {
                    RelayButton(relayLocalized("Reveal")) {
                        NSWorkspace.shared.selectFile(
                            RelayPaths.daemonLogURL.path,
                            inFileViewerRootedAtPath: RelayPaths.logsDirectory.path
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(relayLocalized("Shortcuts"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                RelayButton(relayLocalized("Reset All")) { model.resetAllShortcuts() }
            }
            .padding(.horizontal, Theme.Spacing.xlarge)
            .padding(.top, Theme.Spacing.xlarge)
            .padding(.bottom, Theme.Spacing.medium)

            RelayTextField(relayLocalized("Search commands"), text: $query, systemImage: "magnifyingglass")
                .padding(.horizontal, Theme.Spacing.xlarge)
                .padding(.bottom, Theme.Spacing.medium)

            RelayDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    ForEach(ShortcutCategory.allCases) { category in
                        let commands = filteredCommands(in: category)
                        if !commands.isEmpty {
                            SettingsGroup(category.localizedTitle) {
                                ForEach(commands) { command in
                                    shortcutRow(command)
                                }
                            }
                        }
                    }

                    SettingsGroup(relayLocalized("Quick switching")) {
                        SettingsRow(
                            title: relayLocalized("Jump by number"),
                            detail: relayLocalized("⌘1…⌘9 selects a session, ⌥⌘1…⌥⌘9 selects a project")
                        ) {
                            Toggle("", isOn: Binding(
                                get: { model.shortcutSettings.indexShortcutsEnabled },
                                set: { model.setIndexShortcutsEnabled($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }
                .padding(Theme.Spacing.xlarge)
            }
        }
    }

    private func filteredCommands(in category: ShortcutCategory) -> [RelayCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        return RelayCommand.allCases
            .filter { $0.category == category }
            .filter { trimmed.isEmpty || $0.title.lowercased().contains(trimmed) }
    }

    private func shortcutRow(_ command: RelayCommand) -> some View {
        let binding = model.binding(for: command)
        let conflicts = binding.map {
            ShortcutResolver.conflictingCommands(
                with: $0,
                excluding: command,
                settings: model.shortcutSettings
            )
        } ?? []

        return SettingsRow(
            title: command.localizedTitle,
            detail: conflicts.isEmpty ? nil : String(format: relayLocalized("Also used by %@"), conflicts.map(\.localizedTitle).joined(separator: ", ")),
            detailTint: conflicts.isEmpty ? nil : Theme.Palette.statusWaiting
        ) {
            KeyRecorderField(
                binding: binding,
                isDefault: !ShortcutResolver.isCustomised(command, settings: model.shortcutSettings),
                conflictsWith: conflicts,
                onRecord: { model.rebind(command, to: $0) },
                onReset: { model.resetShortcut(command) }
            )
        }
    }
}

// MARK: - Notifications

struct NotificationSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsScroll(title: relayLocalized("Notifications")) {
            SettingsGroup(relayLocalized("When to interrupt")) {
                toggleRow(
                    relayLocalized("Enabled"),
                    detail: relayLocalized("Turn everything off without losing your other choices"),
                    value: \.isEnabled
                ) { settings, value in settings.isEnabled = value }

                toggleRow(
                    relayLocalized("Agent is waiting for you"),
                    detail: relayLocalized("The only notification that plays a sound"),
                    value: \.waitingForInput
                ) { settings, value in settings.waitingForInput = value }

                toggleRow(
                    relayLocalized("Something failed"),
                    detail: relayLocalized("A session, service or container exited with an error"),
                    value: \.failures
                ) { settings, value in settings.failures = value }

                toggleRow(
                    relayLocalized("Work finished"),
                    detail: relayLocalized("Agents and services only — a shell returning to its prompt is not an event"),
                    value: \.completions
                ) { settings, value in settings.completions = value }
            }

            SettingsGroup(relayLocalized("Muted projects")) {
                if model.projects.isEmpty {
                    SettingsRow(title: relayLocalized("No projects yet"), detail: nil) { EmptyView() }
                } else {
                    ForEach(model.projects) { project in
                        SettingsRow(title: project.name, detail: project.displayPath) {
                            Toggle("", isOn: Binding(
                                get: { model.notificationSettings.isMuted(project.id) },
                                set: { _ in model.toggleNotificationMute(for: project.id) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }
            }
        }
    }

    private func toggleRow(
        _ title: String,
        detail: String,
        value: KeyPath<NotificationSettings, Bool>,
        set: @escaping (inout NotificationSettings, Bool) -> Void
    ) -> some View {
        SettingsRow(title: title, detail: detail) {
            Toggle("", isOn: Binding(
                get: { model.notificationSettings[keyPath: value] },
                set: { newValue in
                    var settings = model.notificationSettings
                    set(&settings, newValue)
                    model.updateNotificationSettings(settings)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(value != \NotificationSettings.isEnabled && !model.notificationSettings.isEnabled)
        }
    }
}

// MARK: - About

struct AboutPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsScroll(title: relayLocalized("About")) {
            HStack(spacing: Theme.Spacing.medium) {
                RelayMark(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Relay")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(verbatim: AppInfo.version)
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
            }
            .padding(.bottom, Theme.Spacing.small)

            SettingsGroup(relayLocalized("Updates")) {
                SettingsRow(
                    title: relayLocalized("Check for updates"),
                    detail: updateDetail
                ) {
                    HStack(spacing: Theme.Spacing.small) {
                        if case let .available(release) = model.updates.state {
                            RelayButton(
                                String(format: relayLocalized("Install %@"), release.version.description),
                                kind: .primary
                            ) { model.updates.install() }
                        } else {
                            RelayButton(relayLocalized("Check now")) { model.updates.check() }
                        }
                    }
                }
                SettingsRow(
                    title: relayLocalized("Check automatically"),
                    detail: relayLocalized("Asks GitHub for the newest release; nothing about you is sent")
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.checksForUpdates },
                        set: { model.setChecksForUpdates($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

            SettingsGroup(relayLocalized("Relay")) {
                SettingsRow(title: relayLocalized("Version"), detail: AppInfo.version) { EmptyView() }
                SettingsRow(title: relayLocalized("Protocol"), detail: "v\(RelayProtocolVersion.current)") { EmptyView() }
                SettingsRow(
                    title: relayLocalized("Runtime"),
                    detail: relayLocalized("Sessions live in a background daemon and survive quitting the app")
                ) { EmptyView() }
            }
        }
    }
}

private extension AboutPane {
    var updateDetail: String {
        switch model.updates.state {
        case .idle: relayLocalized("Relay has not looked yet")
        case .checking: relayLocalized("Looking…")
        case let .available(release): String(format: relayLocalized("%@ is available"), release.version.description)
        case .downloading: relayLocalized("Downloading…")
        case .installing: relayLocalized("Installing…")
        case .upToDate: relayLocalized("This is the newest release")
        case let .failed(message): message
        }
    }
}

enum AppInfo {
    @MainActor
    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? relayLocalized("development build")
    }
}

// MARK: - Shared layout

struct SettingsScroll<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.xlarge)
                .padding(.top, Theme.Spacing.xlarge)
                .padding(.bottom, Theme.Spacing.medium)

            RelayDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    content
                }
                .padding(Theme.Spacing.xlarge)
            }
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(title.uppercased())
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)

            Panel {
                VStack(spacing: 0) {
                    content
                }
            }
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var detail: String?
    var detailTint: Color?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(detailTint ?? Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.medium)
            accessory
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small + 2)
    }
}
