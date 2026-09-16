import RelayProtocol
import RelayUI
import SwiftUI

/// What the project has left itself to do, in the panel beside the terminal.
///
/// A note written in a comment is written to be found later, and later never
/// arrives: nobody greps their own codebase for the word. Listing them where
/// the agents are is what turns one into work — ticked, described, and handed
/// over without leaving the window.
struct TodoPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    /// Which marker the list is narrowed to, or all of them.
    @State private var filter: String?
    @State private var isEditingMarkers = false

    private var scan: TodoScan { model.todos(in: project.id) }
    private var markers: [String] { TodoScanner.markers(from: project.todoMarkers) }
    private var picked: [TodoItem] { model.pickedTodos(in: project.id) }
    private var instruction: String { model.todoInstruction(in: project.id) }

    private var visible: [TodoItem] {
        guard let filter else { return scan.items }
        let matching = scan.items.filter { $0.marker == filter }
        // A filter for a marker the project no longer has would be a dead end:
        // the chip it could be cleared from is only drawn for markers that
        // found something, so it would leave an empty panel and no way out.
        return matching.isEmpty ? scan.items : matching
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()

            if scan.isEmpty {
                EmptyStateView(
                    systemImage: "checklist",
                    title: model.isScanningTodos(project.id)
                        ? relayLocalized("Looking…")
                        : relayLocalized("Nothing left to do"),
                    message: String(
                        format: relayLocalized("No %@ comments in this project."),
                        markers.joined(separator: ", ")
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                list
            }

            if !picked.isEmpty {
                RelayDivider()
                handover
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Agents write these as they work, and cross them off the same way.
        // Longer than the git panel's interval, because a sweep is a search of
        // every file the project owns rather than a question about the index.
        .refreshingWhileVisible(id: project.id, every: .seconds(30)) {
            model.refreshTodos(for: project.id)
        }
        // Another project's markers are not this one's.
        .onChange(of: project.id) { filter = nil }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)

                Text(relayLocalized("TODO"))
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Text(verbatim: scan.isTruncated ? "\(scan.items.count)+" : "\(scan.items.count)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .monospacedDigit()

                Spacer(minLength: 0)

                IconButton(systemImage: "gearshape", help: "", size: Theme.Metrics.action) {
                    isEditingMarkers.toggle()
                }
                .relayTooltip(relayLocalized("Which words to look for"))
                .popover(isPresented: $isEditingMarkers, arrowEdge: .bottom) {
                    TodoMarkersPopover(project: project)
                }

                IconButton(
                    systemImage: "arrow.clockwise",
                    help: "",
                    size: Theme.Metrics.action,
                    isBusy: model.isScanningTodos(project.id)
                ) {
                    model.refreshTodos(for: project.id)
                }
                .relayTooltip(relayLocalized("Look again"))
            }

            let counts = scan.counts(for: markers)
            // One kind of marker is not a choice, and a row of one chip reads
            // as a filter that has already been applied.
            if counts.count > 1 {
                filters(counts)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.small)
    }

    private func filters(_ counts: [TodoCount]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xsmall) {
                filter(nil, title: relayLocalized("All"), count: scan.items.count)
                ForEach(counts) { entry in
                    filter(entry.marker, title: entry.marker, count: entry.count)
                }
            }
        }
    }

    private func filter(_ marker: String?, title: String, count: Int) -> some View {
        let isSelected = filter == marker

        return Button {
            filter = isSelected ? nil : marker
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Text(verbatim: "\(count)")
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .monospacedDigit()
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isSelected ? Theme.Palette.accentMuted : Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(visible) { todo in
                    TodoRow(project: project, todo: todo)
                }

                if scan.isTruncated {
                    Text(String(
                        format: relayLocalized("The first %d are shown. There are more."),
                        TodoScanner.limit
                    ))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.xsmall)
                }
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.small)
        }
    }

    // MARK: - Handover

    /// What the ticked notes are for: a sentence saying what to do with them,
    /// and an agent to say it to. Only on screen once something is ticked —
    /// an empty box asking for an instruction about nothing is furniture.
    private var handover: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            HStack(spacing: Theme.Spacing.small) {
                Text(String(format: relayLocalized("%d picked"), picked.count))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .monospacedDigit()

                Spacer(minLength: 0)

                IconButton(systemImage: "doc.on.doc", help: "", size: Theme.Metrics.action) {
                    model.copyToClipboard(
                        TodoTranscript.compose(picked, instruction: instruction)
                    )
                }
                .relayTooltip(relayLocalized("Copy"))

                IconButton(systemImage: "xmark", help: "", size: Theme.Metrics.action) {
                    model.clearPickedTodos(in: project.id)
                }
                .relayTooltip(relayLocalized("Clear"))
            }

            HStack(spacing: Theme.Spacing.small) {
                RelayTextField(
                    relayLocalized("What should be done about these?"),
                    text: Binding(
                        get: { instruction },
                        set: { model.setTodoInstruction($0, in: project.id) }
                    )
                )
                SendTodosMenu(project: project, todos: picked, instruction: instruction)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.small)
    }
}

/// One note: the marker it was written with, what it says, and where it is.
///
/// The whole row is the tick, because picking notes out of a list is what the
/// panel is for and a hit target the size of a checkbox is not.
private struct TodoRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let todo: TodoItem

    @State private var isHovering = false

    private var isPicked: Bool { model.isPicked(todo, in: project.id) }

    var body: some View {
        Button {
            model.togglePick(todo, in: project.id)
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isPicked ? Theme.Palette.accent : Theme.Palette.textTertiary)

                // Both lines single: a row that is sometimes one line tall and
                // sometimes two leaves the lazy stack guessing at the height of
                // everything it has not drawn yet, and the guess changing
                // mid-gesture is what the overscroll was yanking on. The note
                // in full is a hover away.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Theme.Spacing.xsmall) {
                        Badge(todo.marker, tint: Self.tint(of: todo.marker))
                        Text(todo.text)
                            .font(Theme.Typography.rowSecondary)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                    }
                    Text(verbatim: "\(todo.path):\(todo.line)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 0)

                HoverReveal(isVisible: isHovering) {
                    HStack(spacing: Theme.Spacing.xxsmall) {
                        // The system's own tooltip rather than Relay's: Relay's
                        // measures the control it is attached to, and a hundred
                        // of those reporting their position on every frame of a
                        // scroll is the scroll.
                        if let agent = model.agentForReview(in: project.id) {
                            IconButton(
                                systemImage: "paperplane",
                                help: relayLocalized("Send to an agent"),
                                size: Theme.Metrics.action,
                                tint: Theme.Palette.accent
                            ) {
                                model.send([todo], instruction: "", to: agent.id, in: project.id)
                            }
                        }
                        IconButton(
                            systemImage: "arrow.up.forward.square",
                            help: relayLocalized("Open in editor"),
                            size: Theme.Metrics.action
                        ) {
                            model.openFileInEditor(todo.path, line: todo.line, in: project)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 5)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { isHovering = $0 }
        .help(todo.text)
        .contextMenu {
            Button(relayLocalized("Open in editor")) {
                model.openFileInEditor(todo.path, line: todo.line, in: project)
            }
            Button(relayLocalized("Copy")) {
                model.copyToClipboard(TodoTranscript.compose([todo], instruction: ""))
            }
        }
    }

    private var background: Color {
        if isPicked { return Theme.Palette.accentMuted }
        return isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surface
    }

    /// How loudly each word asks. The ones nobody agrees on are left in the
    /// neutral colour rather than given a severity they were not written with.
    private static func tint(of marker: String) -> Color {
        switch marker {
        case "FIXME", "BUG": Theme.Palette.statusError
        case "HACK", "XXX": Theme.Palette.statusWaiting
        case "TODO": Theme.Palette.accent
        default: Theme.Palette.textSecondary
        }
    }
}

/// Where the picked notes go: a session already running, or one started for
/// them. Its own menu rather than the review's, because these are handed over
/// with an instruction of their own and the two queues would otherwise empty
/// into each other.
private struct SendTodosMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let todos: [TodoItem]
    var instruction: String
    var size: CGFloat = Theme.Metrics.action

    var body: some View {
        Menu {
            let agents = model.agentsForReview(in: project.id)
            if !agents.isEmpty {
                Section(relayLocalized("Send to")) {
                    ForEach(agents) { session in
                        Button(model.label(for: session)) {
                            model.send(
                                todos,
                                instruction: instruction,
                                to: session.id,
                                in: project.id
                            )
                        }
                    }
                }
            }
            Section(relayLocalized("New agent")) {
                ForEach(model.sessionPresets.filter(\.kind.isAgent)) { preset in
                    Button(preset.name) {
                        model.send(
                            todos,
                            instruction: instruction,
                            toNewSessionFrom: preset,
                            in: project.id
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "paperplane")
                // The ratio `IconButton` uses. Anything else and the two
                // sitting side by side look like different sizes, because they
                // are.
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: size)
        .clickable()
        .relayTooltip(relayLocalized("Send to an agent"))
    }
}

/// The words this project marks unfinished work with, where the list of them
/// is.
///
/// The same setting as the one in Project Settings, not a copy of it: both
/// write the project through `setTodoMarkers`, so neither can go stale while
/// the other is used. Here because a list you are looking at is where you
/// notice it is looking for the wrong things.
private struct TodoMarkersPopover: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var draft = ""

    private var chosen: [String] { TodoScanner.markers(from: project.todoMarkers) }

    /// The ones on offer, plus whatever this project has added to them.
    private var offered: [String] {
        TodoScanner.suggestedMarkers + chosen.filter { !TodoScanner.suggestedMarkers.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(relayLocalized("TODO markers"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.top, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.small)

            RelayDivider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(offered, id: \.self) { marker in
                        row(marker)
                    }
                }
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.small)
            }
            .frame(maxHeight: 260)

            RelayDivider()

            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                RelayTextField(relayLocalized("Add a marker…"), text: $draft) { add() }
                Text(relayLocalized("Case sensitive; letters only."))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(Theme.Spacing.medium)
        }
        .frame(width: 260)
        .background(Theme.Palette.base)
    }

    private func row(_ marker: String) -> some View {
        let isOn = chosen.contains(marker)
        // The last one cannot be turned off. A search for no words is not a
        // narrower search, it is a panel that has stopped working, and the
        // empty list it would leave says nothing about why.
        let isLast = isOn && chosen.count == 1

        return Button {
            guard !isLast else { return }
            model.setTodoMarkers(
                isOn ? chosen.filter { $0 != marker } : chosen + [marker],
                in: project.id
            )
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textTertiary)
                Text(marker)
                    .font(Theme.Typography.row)
                    .foregroundStyle(isOn ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable(!isLast)
        // Enabled rather than conditional: the modifier keeps the row's hover
        // state only if its identity does not change under the pointer.
        .relayTooltip(relayLocalized("At least one marker is needed"), isEnabled: isLast)
    }

    private func add() {
        let added = TodoScanner.normalise([draft])
        guard !added.isEmpty else { return }
        model.setTodoMarkers(chosen + added, in: project.id)
        draft = ""
    }
}
