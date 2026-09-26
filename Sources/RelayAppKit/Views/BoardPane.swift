import AppKit
import RelayProtocol
import RelayTracker
import RelayUI
import SwiftUI

/// The tracker's board for a project: its columns side by side, and cards that
/// are dragged between them.
///
/// Opened over the window rather than beside it, like the other things one
/// consults and closes: the point is to pick the next piece of work, hand it to
/// an agent and get back to the terminal, not to keep a second screen open.
struct BoardPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var filter = ""
    @State private var onlyMine = false

    private var tracker: TrackerController { model.tracker }
    private var boardID: String? { tracker.boardID(for: project.id) }
    private var snapshot: BoardSnapshot? { boardID.flatMap { tracker.snapshots[$0] } }

    /// How often an open board is read again. Often enough that a card moved
    /// by someone else turns up while the board is being looked at; the read is
    /// one request for the board and one for its cards.
    private static let refreshInterval: Duration = .seconds(45)

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.base)
        .task {
            if tracker.boards.isEmpty { tracker.refreshBoards() }
        }
        .task(id: boardID) {
            guard let boardID else { return }
            tracker.refreshBoard(boardID)
            // Ends with the panel: a board nobody is looking at costs nothing.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled else { break }
                tracker.refreshBoard(boardID)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(relayLocalized("Issue Board"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)

            if tracker.isConnected {
                boardMenu
                if let board = snapshot?.board ?? boardID.flatMap(tracker.board), board.usesSprints {
                    sprintMenu(board)
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            if snapshot != nil {
                RelayTextField(relayLocalized("Filter cards"), text: $filter, systemImage: "line.3.horizontal.decrease")
                    .frame(width: 220)
                Chip(isSelected: onlyMine, action: { onlyMine.toggle() }) {
                    Text(relayLocalized("Mine"))
                        .font(Theme.Typography.row)
                        .foregroundStyle(onlyMine ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .fixedSize()
                }
                .fixedSize()
                .relayTooltip(relayLocalized("Only the cards assigned to you"))
            }

            if let boardID {
                IconButton(
                    systemImage: "arrow.clockwise",
                    size: Theme.Metrics.action + 2,
                    isBusy: tracker.boardsBeingRead.contains(boardID)
                ) {
                    tracker.refreshBoard(boardID)
                }
                .relayTooltip(relayLocalized("Reload the board"))

                if snapshot != nil {
                    RelayButton(relayLocalized("New Issue"), systemImage: "plus", kind: .primary) {
                        model.beginNewIssue(on: boardID, in: nil, projectID: project.id)
                    }
                }
            }

            IconButton(systemImage: "xmark") { model.dismissModal() }
        }
        .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
        .padding(.vertical, ModalSurface<EmptyView, EmptyView>.barVerticalInset)
    }

    private var boardMenu: some View {
        Menu {
            ForEach(tracker.boards) { board in
                Button {
                    tracker.chooseBoard(board.id, for: project.id)
                } label: {
                    if board.id == boardID {
                        Label(board.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: board.name)
                    }
                }
            }
            if tracker.boards.isEmpty {
                Text(relayLocalized("No boards yet"))
            }
            Divider()
            Button(relayLocalized("Read the List Again")) { tracker.refreshBoards() }
        } label: {
            menuLabel(
                boardID.flatMap(tracker.board)?.name.nonEmpty ?? relayLocalized("Choose a board"),
                systemImage: "rectangle.split.3x1"
            )
        }
        // Drawn as given, plate and all; a borderless menu keeps only the text.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .clickable()
    }

    private func sprintMenu(_ board: TrackerBoard) -> some View {
        let chosen = tracker.chosenSprints[board.id]
        let shown = snapshot?.sprint
        return Menu {
            Button {
                tracker.chooseSprint(nil, on: board.id)
            } label: {
                if chosen == nil {
                    Label(relayLocalized("Current sprint"), systemImage: "checkmark")
                } else {
                    Text(relayLocalized("Current sprint"))
                }
            }
            Divider()
            ForEach(board.openSprints(including: shown?.id).reversed()) { sprint in
                Button {
                    tracker.chooseSprint(sprint.id, on: board.id)
                } label: {
                    if sprint.id == chosen {
                        Label(sprint.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: sprint.name)
                    }
                }
            }
        } label: {
            menuLabel(shown?.name ?? relayLocalized("Current sprint"), systemImage: "flag")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .clickable()
    }

    private func menuLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(verbatim: title)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .frame(height: 26)
        .background(Theme.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tracker.connection {
        case .off, .needsToken, .failed:
            VStack(spacing: Theme.Spacing.medium) {
                EmptyStateView(
                    systemImage: "key",
                    title: relayLocalized("Not connected"),
                    message: notConnectedMessage
                )
                .frame(height: 160)
                RelayButton(relayLocalized("Open Settings"), kind: .primary) { model.openSettings(on: .issues) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .checking:
            ProgressView().controlSize(.small)
        case .connected:
            if let boardID {
                if let snapshot {
                    BoardColumns(project: project, boardID: boardID, snapshot: snapshot, filter: filter, onlyMine: onlyMine)
                } else if let failure = tracker.boardFailures[boardID] {
                    failureView(failure) { tracker.refreshBoard(boardID) }
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                BoardChooser(project: project)
            }
        }
    }

    private var notConnectedMessage: String {
        if case let .failed(error) = tracker.connection { return TrackerText.describe(error) }
        return relayLocalized("Connect the tracker in Settings to see its boards here.")
    }

    private func failureView(_ failure: TrackerError, retry: @escaping () -> Void) -> some View {
        VStack(spacing: Theme.Spacing.medium) {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: relayLocalized("Could not read the board"),
                message: TrackerText.describe(failure)
            )
            .frame(height: 160)
            RelayButton(relayLocalized("Try Again"), action: retry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The boards to choose from, the first time a project's board is opened.
private struct BoardChooser: View {
    @Environment(AppModel.self) private var model
    let project: Project

    private var tracker: TrackerController { model.tracker }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                Text(String(format: relayLocalized("Which board is %@'s?"), project.name))
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(relayLocalized("Relay remembers the choice for this project. It can be changed from the menu above."))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            if tracker.boards.isEmpty {
                if tracker.isReadingBoards {
                    ProgressView().controlSize(.small)
                } else if let failure = tracker.boardsFailure {
                    Text(verbatim: TrackerText.describe(failure))
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.statusError)
                    RelayButton(relayLocalized("Try Again")) { tracker.refreshBoards() }
                } else {
                    Text(relayLocalized("This account can see no boards."))
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.small)],
                        alignment: .leading,
                        spacing: Theme.Spacing.small
                    ) {
                        ForEach(tracker.boards) { board in
                            Chip(action: { tracker.chooseBoard(board.id, for: project.id) }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: board.name)
                                        .font(Theme.Typography.row)
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                        .lineLimit(1)
                                    Text(verbatim: board.projects.map(\.key).joined(separator: ", "))
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Palette.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.xlarge)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The columns of a board, left to right.
private struct BoardColumns: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let boardID: String
    let snapshot: BoardSnapshot
    let filter: String
    let onlyMine: Bool

    private static let columnWidth: CGFloat = 288

    var body: some View {
        if snapshot.columns.isEmpty {
            EmptyStateView(
                systemImage: "rectangle.split.3x1",
                title: relayLocalized("The board has no columns"),
                message: relayLocalized("Columns are set up on the board in the tracker.")
            )
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                    ForEach(snapshot.columns) { column in
                        BoardColumnView(
                            project: project,
                            boardID: boardID,
                            column: column,
                            cards: visibleCards(in: column),
                            total: snapshot.cards(in: column).count,
                            snapshot: snapshot
                        )
                        .frame(width: Self.columnWidth)
                    }
                }
                .padding(Theme.Spacing.large)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func visibleCards(in column: BoardColumn) -> [TrackerCard] {
        let search = RelaySearchQuery(filter)
        let me = model.tracker.user?.login
        return snapshot.cards(in: column).filter { card in
            (!onlyMine || card.assignee?.login == me)
                && search.matches([card.key, card.summary] + card.tags.map(\.name))
        }
    }
}

private struct BoardColumnView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let boardID: String
    let column: BoardColumn
    let cards: [TrackerCard]
    let total: Int
    let snapshot: BoardSnapshot

    @State private var isTargeted = false

    private var isOverLimit: Bool {
        column.limit.map { total > $0 } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: Theme.Spacing.small) {
                    ForEach(cards) { card in
                        IssueCardView(project: project, boardID: boardID, card: card, snapshot: snapshot)
                    }
                }
                .padding(.bottom, Theme.Spacing.large)
            }
        }
        .padding(Theme.Spacing.small)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(isTargeted ? Theme.Palette.accentMuted.opacity(0.6) : Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(isTargeted ? Theme.Palette.accent.opacity(0.7) : Theme.Palette.border, lineWidth: 1)
        )
        // The key is what is dragged, so a card dropped into a terminal types
        // the key — which is what a person dragging it there would want.
        .dropDestination(for: String.self) { keys, _ in
            guard let key = keys.first, let card = snapshot.cards.first(where: { $0.key == key }) else { return false }
            model.tracker.move(card, to: column, on: boardID)
            return true
        } isTargeted: { isTargeted = $0 }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            Text(verbatim: column.title)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Text(verbatim: countText)
                .font(Theme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(isOverLimit ? Theme.Palette.statusError : Theme.Palette.textTertiary)
            Spacer(minLength: 0)
            IconButton(systemImage: "plus", size: Theme.Metrics.action) {
                model.beginNewIssue(on: boardID, in: column.id, projectID: project.id)
            }
            .relayTooltip(String(format: relayLocalized("New issue in %@"), column.title))
        }
        .padding(.horizontal, Theme.Spacing.xsmall)
        .padding(.top, 2)
    }

    /// `4`, or `4 / 3` against a limit, which is when it is worth reading.
    private var countText: String {
        let shown = cards.count == total ? "\(total)" : "\(cards.count) · \(total)"
        guard let limit = column.limit else { return shown }
        return "\(shown) / \(limit)"
    }
}

extension String {
    /// Nil for a string with nothing in it, for falling back with `??`.
    var nonEmpty: String? { isEmpty ? nil : self }
}
