import AppKit
import RelayProtocol
import RelayUI
import SwiftUI

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    /// What the query is matched against, most significant first: the title as
    /// every shipped language words it, then the subtitle. A command is looked
    /// for by name, and which language that name is in is the searcher's
    /// business, not the interface's.
    let searchTerms: [String]
    let run: () -> Void

    /// A plain entry, whose title is not a phrase of the interface: a file
    /// name is a file name in every language, and looking one up in the
    /// string tables would be looking for a translation of `GitPanel.swift`.
    init(
        id: String,
        title: String,
        subtitle: String,
        systemImage: String,
        searchTerms: [String],
        run: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.searchTerms = searchTerms
        self.run = run
    }

    /// - Parameters:
    ///   - titleKey: the untranslated title, which is also the key it is
    ///     looked up under.
    ///   - titleArguments: what fills the placeholders, in every language at
    ///     once — a session called "Dev" has to be findable whichever side of
    ///     the verb its language puts it on.
    @MainActor
    init(
        id: String,
        titleKey: String,
        titleArguments: [CVarArg] = [],
        subtitle: String,
        systemImage: String,
        run: @escaping () -> Void
    ) {
        let wordings = relaySearchTerms(titleKey).map { wording in
            titleArguments.isEmpty ? wording : String(format: wording, arguments: titleArguments)
        }
        self.id = id
        title = wordings.first ?? titleKey
        self.subtitle = subtitle
        self.systemImage = systemImage
        searchTerms = subtitle.isEmpty ? wordings : wordings + [subtitle]
        self.run = run
    }
}

/// Keyboard-first entry point to everything. Deliberately free of any AI or
/// network dependency: it is a command index, not a search box.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var isFieldFocused: Bool

    /// How many files a query is allowed to fill the list with. The commands
    /// are a closed set and the files are not: without a limit a two-letter
    /// query answers with a thousand rows and the command that was meant is
    /// somewhere in them.
    private static let fileLimit = 30

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            Panel {
                VStack(spacing: 0) {
                    field
                    RelayDivider()
                    results
                }
            }
            .frame(width: 560)
            .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
            .padding(.top, 96)
        }
        .onAppear {
            isFieldFocused = true
            highlightedIndex = 0
        }
        // The walk that makes files findable, started when the palette opens
        // rather than at launch: it is the first moment anybody could want it.
        .task {
            guard let root = model.selectedProjectID.flatMap(model.workingRoot) else { return }
            await model.files.prepare(root: root)
        }
    }

    private var field: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField(relayLocalized("Run a command…"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($isFieldFocused)
                .onSubmit(runHighlighted)
                .onChange(of: query) { _, _ in highlightedIndex = 0 }
            Text("esc")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.medium)
        .relayPointer(.text)
    }

    private var results: some View {
        // Held once per redraw: scoring every command against every reading of
        // the query is not something to do twice for the same list.
        let commands = filteredCommands

        return KeyboardScrollingList(
            focusedRow: highlightedIndex,
            identifyingRow: { commands.indices.contains($0) ? commands[$0].id : nil }
        ) {
            VStack(spacing: 1) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    row(command, isHighlighted: index == highlightedIndex)
                        .clickable()
                        .onTapGesture {
                            command.run()
                            close()
                        }
                }
                if commands.isEmpty {
                    Text(relayLocalized("No matching commands"))
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(Theme.Spacing.large)
                }
            }
            .padding(Theme.Spacing.xsmall)
        }
        .frame(maxHeight: 340)
        .background(
            // Arrow-key navigation without stealing focus from the text field.
            KeyCaptureView(
                onMoveDown: { highlightedIndex = min(highlightedIndex + 1, max(commands.count - 1, 0)) },
                onMoveUp: { highlightedIndex = max(highlightedIndex - 1, 0) },
                onEscape: close
            )
        )
    }

    private func row(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: command.systemImage)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if !command.subtitle.isEmpty {
                    Text(command.subtitle)
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 7)
        .background(isHighlighted ? Theme.Palette.surfaceActive : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: - Commands

    /// Ranked, not merely filtered: with a query that reaches a command through
    /// a translation or a keyboard layout, the order the commands were built in
    /// says nothing about which one was meant.
    private var filteredCommands: [PaletteCommand] {
        let all = allCommands
        let search = RelaySearchQuery(query)
        guard !search.isEmpty else { return all }

        var ranked: [RankedCommand] = []
        for (position, command) in all.enumerated() {
            guard let score = search.score(command.searchTerms) else { continue }
            ranked.append(RankedCommand(position: position, score: score, command: command))
        }
        // Files are ranked by the same reading of the query and sorted in
        // among the commands, so typing a file name answers with the file
        // and typing a verb answers with the command — without the palette
        // having to decide in advance which of the two was meant. They are
        // listed after commands of the same score, which is what the position
        // does: every file starts after every command.
        for (position, file) in matchingFiles().enumerated() {
            ranked.append(RankedCommand(position: all.count + position, score: file.score, command: file.command))
        }
        // Position breaks ties, so equally good matches keep the order the
        // palette lists them in rather than an arbitrary one.
        ranked.sort { $0.score == $1.score ? $0.position < $1.position : $0.score > $1.score }
        return ranked.map(\.command)
    }

    private struct RankedCommand {
        let position: Int
        let score: Int
        let command: PaletteCommand
    }

    /// The project's files that answer to the query, best first.
    private func matchingFiles() -> [(score: Int, command: PaletteCommand)] {
        guard let project = model.selectedProject, let root = model.workingRoot(of: project.id) else { return [] }

        return FileMatching
            .matches(query, in: model.files.files(in: root), under: root, limit: Self.fileLimit)
            .map { match in
                let relative = FileMatching.relative(match.path, to: root)
                return (
                    match.score,
                    PaletteCommand(
                        id: "file:\(match.path)",
                        title: (match.path as NSString).lastPathComponent,
                        subtitle: relative,
                        systemImage: "doc",
                        searchTerms: [(match.path as NSString).lastPathComponent, relative],
                        run: { model.openFile(at: match.path, in: project.id) }
                    )
                )
            }
    }

    private var allCommands: [PaletteCommand] {
        var commands: [PaletteCommand] = []

        if let project = model.selectedProject {
            for preset in model.sessionPresets {
                commands.append(PaletteCommand(
                    id: "new-\(preset.id)",
                    titleKey: "New %@ Session",
                    titleArguments: [preset.localizedName],
                    subtitle: preset.subtitle,
                    systemImage: preset.kind.symbolName
                ) {
                    model.createSession(from: preset, in: project.id)
                })
            }
            commands.append(PaletteCommand(
                id: "reveal",
                titleKey: "Open Project in Finder",
                subtitle: project.displayPath,
                systemImage: "folder"
            ) { model.revealInFinder(project) })
            commands.append(PaletteCommand(
                id: "editor",
                titleKey: "Open Project in Editor",
                subtitle: project.displayPath,
                systemImage: "chevron.left.forwardslash.chevron.right"
            ) { model.openInEditor(project) })
            commands.append(PaletteCommand(
                id: "settings",
                titleKey: "Project Settings",
                subtitle: project.name,
                systemImage: "gearshape"
            ) { model.openProjectSettings() })
            commands.append(PaletteCommand(
                id: "branches",
                titleKey: "Switch Branch",
                subtitle: model.gitStatuses[project.id]?.branch ?? relayLocalized("Git"),
                systemImage: "arrow.triangle.branch"
            ) { model.pickBranch(in: project.id) })
            if model.gitRepositories.contains(project.id) {
                commands.append(PaletteCommand(
                    id: "new-worktree",
                    titleKey: "New Worktree",
                    subtitle: project.name,
                    systemImage: "square.stack.3d.up"
                ) { model.beginNewWorktree(in: project.id) })
            }
            if model.offersWorktreeCleanup(in: project.id) {
                commands.append(PaletteCommand(
                    id: "clean-up-worktrees",
                    titleKey: "Clean Up Worktrees",
                    subtitle: project.name,
                    systemImage: "square.stack.3d.up.slash"
                ) { model.beginWorktreeCleanup(in: project.id) })
            }
            commands.append(PaletteCommand(
                id: "review-changes",
                titleKey: "Review Changes",
                subtitle: project.displayPath,
                systemImage: "doc.text.magnifyingglass"
            ) { model.reviewChanges(in: project.id) })
            commands.append(PaletteCommand(
                id: "new-browser-tab",
                titleKey: "New Browser Tab",
                subtitle: project.name,
                systemImage: "globe"
            ) { model.newBrowserTab(in: project.id) })
            commands.append(PaletteCommand(
                id: "design-mode",
                titleKey: "Toggle Design Mode",
                subtitle: relayLocalized("Point at an element and hand it to an agent"),
                systemImage: "cursorarrow.rays"
            ) { model.toggleDesignMode() })
            commands.append(PaletteCommand(
                id: "ports-window",
                titleKey: "Ports",
                subtitle: relayLocalized("Everything listening on this Mac"),
                systemImage: "point.3.filled.connected.trianglepath.dotted"
            ) { model.toggleModal(.ports) })
            commands.append(PaletteCommand(
                id: "app-settings",
                titleKey: "Settings",
                subtitle: relayLocalized("Shortcuts, notifications and more"),
                systemImage: "slider.horizontal.3"
            ) { model.toggleModal(.settings) })

            for service in project.services {
                let state = model.state(of: service, in: project.id)
                if state.isActive {
                    commands.append(PaletteCommand(
                        id: "stop-\(service.id)",
                        titleKey: "Stop %@",
                        titleArguments: [service.name],
                        subtitle: service.command,
                        systemImage: "stop.fill"
                    ) { model.stopService(service, in: project.id) })
                    commands.append(PaletteCommand(
                        id: "restart-\(service.id)",
                        titleKey: "Restart %@",
                        titleArguments: [service.name],
                        subtitle: service.command,
                        systemImage: "arrow.clockwise"
                    ) { model.restartService(service, in: project.id) })
                } else {
                    commands.append(PaletteCommand(
                        id: "start-\(service.id)",
                        titleKey: "Start %@",
                        titleArguments: [service.name],
                        subtitle: service.command,
                        systemImage: "play.fill"
                    ) { model.startService(service, in: project.id) })
                }
                if model.url(of: service, in: project.id) != nil {
                    commands.append(PaletteCommand(
                        id: "open-\(service.id)",
                        titleKey: "Open %@ URL",
                        titleArguments: [service.name],
                        subtitle: model.url(of: service, in: project.id)?.absoluteString ?? "",
                        systemImage: "arrow.up.forward.app"
                    ) { model.openService(service, in: project.id) })
                    commands.append(PaletteCommand(
                        id: "browse-\(service.id)",
                        titleKey: "Open %@ in Browser Pane",
                        titleArguments: [service.name],
                        subtitle: model.url(of: service, in: project.id)?.absoluteString ?? "",
                        systemImage: "rectangle.split.2x1"
                    ) { model.openServiceInBrowser(service, in: project.id) })
                }
            }

            for port in model.ports where port.url != nil {
                commands.append(PaletteCommand(
                    id: "port-\(port.id)",
                    titleKey: "Open port %d",
                    titleArguments: [port.port],
                    subtitle: port.ownerName ?? port.processName,
                    systemImage: "point.3.filled.connected.trianglepath.dotted"
                ) { model.openPort(port) })
            }
        }

        if let project = model.selectedProject {
            let hosts = model.sshHosts(for: project.id)
            for host in hosts.pinned + hosts.others {
                commands.append(PaletteCommand(
                    id: "ssh-\(host.alias)",
                    titleKey: "Connect SSH: %@",
                    titleArguments: [host.alias],
                    subtitle: host.displayTarget,
                    systemImage: "network"
                ) { model.connectSSH(host, in: project.id) })
            }
        }

        for project in model.railProjects {
            commands.append(PaletteCommand(
                id: "switch-\(project.id.rawValue)",
                titleKey: "Switch to %@",
                titleArguments: [project.name],
                subtitle: project.displayPath,
                systemImage: "square.stack.3d.up"
            ) { model.selectProject(project.id) })
        }

        if let projectID = model.selectedProjectID {
            for session in model.sessions(in: projectID) {
                commands.append(PaletteCommand(
                    id: "focus-\(session.id.rawValue)",
                    titleKey: "Focus %@",
                    titleArguments: [model.label(for: session)],
                    subtitle: session.status.localizedName,
                    systemImage: session.kind.symbolName
                ) { model.selectSession(session.id) })
            }
        }

        return commands
    }

    private func runHighlighted() {
        guard filteredCommands.indices.contains(highlightedIndex) else { return }
        filteredCommands[highlightedIndex].run()
        close()
    }

    private func close() {
        model.isCommandPaletteOpen = false
        query = ""
    }
}

/// Minimal AppKit bridge for arrow/escape handling, which SwiftUI does not
/// expose while a `TextField` holds focus.
struct KeyCaptureView: NSViewRepresentable {
    /// All optional: a panel that only needs Escape must leave the arrow keys to
    /// whatever list is inside it, and a list must leave Escape to the panel.
    /// A key with no handler is passed on untouched.
    var onMoveDown: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveRight: (() -> Void)?
    var onMoveLeft: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        apply(to: view)
    }

    private func apply(to view: MonitorView) {
        view.onMoveDown = onMoveDown
        view.onMoveUp = onMoveUp
        view.onMoveRight = onMoveRight
        view.onMoveLeft = onMoveLeft
        view.onReturn = onReturn
        view.onEscape = onEscape
    }

    final class MonitorView: NSView {
        var onMoveDown: (() -> Void)?
        var onMoveUp: (() -> Void)?
        var onMoveRight: (() -> Void)?
        var onMoveLeft: (() -> Void)?
        var onReturn: (() -> Void)?
        var onEscape: (() -> Void)?
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let handler: (() -> Void)?
                switch event.keyCode {
                case 125: handler = self.onMoveDown
                case 126: handler = self.onMoveUp
                case 124: handler = self.onMoveRight
                case 123: handler = self.onMoveLeft
                // Return and the keypad's enter, which are different keys.
                case 36, 76: handler = self.onReturn
                case 53: handler = self.onEscape
                default: handler = nil
                }
                guard let handler else { return event }
                handler()
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
