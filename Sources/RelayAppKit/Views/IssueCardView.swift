import AppKit
import RelayProtocol
import RelayTracker
import RelayUI
import SwiftUI

/// One card on the board: the key, the summary, and the few fields a board is
/// read by — the priority and the kind as the tracker colours them, and who
/// has it.
struct IssueCardView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let boardID: String
    let card: TrackerCard
    let snapshot: BoardSnapshot

    @State private var isHovering = false

    private var tracker: TrackerController { model.tracker }
    private var isMoving: Bool { tracker.cardsMoving.contains(card.id) }
    private var isTimed: Bool { tracker.timer?.key == card.key }

    /// The choice fields worth a chip: everything that is one value out of a
    /// list, except the one the columns already say — the one the board
    /// colours its cards by first, since that is the one it was set up to be
    /// read by, and the priority after it.
    private var chips: [FieldOption] {
        let colorField = snapshot.board.colorField
        func rank(_ field: TrackerField) -> Int {
            if field.name == colorField { return 0 }
            if field.name.caseInsensitiveCompare("Priority") == .orderedSame { return 1 }
            if field.name.caseInsensitiveCompare("Type") == .orderedSame { return 2 }
            return 3
        }
        return card.fields
            .filter { $0.kind == .option && !$0.allowsSeveral && $0.name != snapshot.columnField }
            .enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .compactMap(\.element.values.first)
            .prefix(3)
            .map { $0 }
    }

    /// The colour the board gives this card, from the field it is set up to
    /// colour by — the edge YouTrack draws down the side of the card.
    private var cardColor: Color? {
        guard let field = snapshot.board.colorField,
              let color = card.field(named: field)?.values.first?.color
        else { return nil }
        return Color(tracker: color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small - 2) {
            HStack(spacing: Theme.Spacing.xsmall) {
                Text(verbatim: card.key)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .strikethrough(card.isResolved, color: Theme.Palette.textTertiary)
                Spacer(minLength: 0)
                if isTimed {
                    Image(systemName: tracker.timer?.isRunning == true ? "timer" : "pause.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.statusWorking)
                }
                if isMoving {
                    ProgressView().controlSize(.mini)
                }
            }

            Text(verbatim: card.summary)
                .font(Theme.Typography.row)
                .foregroundStyle(card.isResolved ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !chips.isEmpty || card.assignee != nil || !card.tags.isEmpty {
                HStack(spacing: Theme.Spacing.xsmall) {
                    ForEach(chips, id: \.id) { option in
                        TrackerChip(text: option.title, color: option.color)
                            .lineLimit(1)
                    }
                    ForEach(card.tags.prefix(2), id: \.name) { tag in
                        TrackerChip(text: tag.name, systemImage: "tag", color: tag.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let assignee = card.assignee {
                        TrackerAvatar(name: assignee.title, avatar: assignee.avatar)
                            .relayTooltip(assignee.title)
                    }
                }
            }
        }
        .padding(Theme.Spacing.small + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surfaceRaised)
        .overlay(alignment: .leading) {
            if let cardColor {
                Rectangle()
                    .fill(cardColor)
                    .frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(isTimed ? Theme.Palette.statusWorking.opacity(0.6) : Theme.Palette.border, lineWidth: 1)
        )
        .opacity(isMoving ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.openIssue(card.key, in: project.id) }
        .clickable()
        .draggable(card.key) {
            Text(verbatim: "\(card.key)  \(card.summary)")
                .font(Theme.Typography.row)
                .lineLimit(1)
                .padding(Theme.Spacing.small)
                .frame(maxWidth: 280, alignment: .leading)
                .background(Theme.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .contextMenu {
            IssueMenuItems(project: project, key: card.key, summary: card.summary, trackerProject: card.project)
            Divider()
            // Every column the board has, hidden and merged ones each on
            // their own: this is how a card goes where the board does not show.
            Menu(relayLocalized("Move To")) {
                ForEach(tracker.layout(of: boardID).arranged(snapshot.columns)) { column in
                    Button(column.title) { tracker.move(card, to: column, on: boardID) }
                        .disabled(snapshot.column(of: card)?.id == column.id)
                }
            }
        }
    }
}

/// What can be done with an issue from wherever it is shown: a card's menu,
/// and the issue pane's.
struct IssueMenuItems: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let key: String
    let summary: String
    let trackerProject: TrackerProject?
    /// Off inside the issue itself, where it would open what is already open.
    var offersOpening = true

    private var tracker: TrackerController { model.tracker }

    var body: some View {
        if offersOpening {
            Button(relayLocalized("Open")) { model.openIssue(key, in: project.id) }
        }
        SendIssueMenuItems(project: project, key: key)
        Divider()
        if tracker.timer?.key == key, tracker.timer?.isRunning == true {
            Button(relayLocalized("Stop Timer…")) { model.stopTimer() }
        } else {
            Button(relayLocalized("Start Timer")) {
                model.startTimer(for: key, summary: summary, project: trackerProject)
            }
        }
        Button(relayLocalized("Log Time…")) { model.beginLoggingWork(on: key) }
        Divider()
        Button(relayLocalized("Copy ID")) { model.copyToClipboard(key) }
        if let url = tracker.webURL(for: key) {
            Button(relayLocalized("Copy Link")) { model.copyToClipboard(url.absoluteString) }
            Button(relayLocalized("Open in Browser")) { NSWorkspace.shared.open(url) }
        }
    }
}

/// Where an issue can be handed, as a submenu of a card's menu.
struct SendIssueMenuItems: View {
    let project: Project
    let key: String

    var body: some View {
        Menu(relayLocalized("Send to Agent")) {
            IssueHandoverTargets(project: project, key: key)
        }
    }
}

/// Where an issue can be handed, project by project: the likeliest project's
/// agents, a new agent and a worktree of its own right here, and every other
/// project's one level down. Listed directly in the issue pane's Send menu,
/// and inside a submenu on a card.
struct IssueHandoverTargets: View {
    @Environment(AppModel.self) private var model
    /// The project whose board the issue was found on.
    let project: Project
    let key: String

    var body: some View {
        let destinations = model.handoverProjects(for: key, from: project.id)
        if let likeliest = destinations.first {
            Section(likeliest.name) {
                ProjectHandover(project: likeliest, key: key)
            }
            let others = Array(destinations.dropFirst())
            if !others.isEmpty {
                Menu(relayLocalized("Another Project")) {
                    ForEach(others) { other in
                        Menu(other.name) { ProjectHandover(project: other, key: key) }
                    }
                }
            }
        }
    }
}

/// The places in one project an issue can go: an agent already running
/// there, a new one, or a worktree of its own.
private struct ProjectHandover: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let key: String

    var body: some View {
        ForEach(model.agentsForReview(in: project.id)) { session in
            Button(model.label(for: session)) { model.sendIssue(key, to: session.id) }
        }
        Menu(relayLocalized("New agent")) {
            ForEach(model.sessionPresets.filter(\.kind.isAgent)) { preset in
                Button(preset.localizedName) {
                    model.sendIssue(key, toNewSessionFrom: preset, in: project.id)
                }
            }
        }
        if model.gitRepositories.contains(project.id) {
            Button(relayLocalized("Start Work in a New Worktree…")) { model.startWork(on: key, in: project.id) }
        }
    }
}

/// Initials in a circle, for a person with no picture Relay has fetched.
struct PersonMark: View {
    let name: String
    var size: CGFloat = 20

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    var body: some View {
        Text(verbatim: initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.Palette.textPrimary)
            .frame(width: size, height: size)
            .background(ProjectAppearance.tint(for: name).opacity(0.55))
            .clipShape(Circle())
    }
}

extension Color {
    /// A tracker's colour, from the hex it writes it in — `#e30000` or the
    /// short `#444`. Grey when it writes something else.
    init(tracker color: TrackerColor) {
        self = Color.fromTrackerHex(color.background) ?? Theme.Palette.textSecondary
    }

    static func fromTrackerHex(_ text: String) -> Color? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(hex: value)
    }
}
