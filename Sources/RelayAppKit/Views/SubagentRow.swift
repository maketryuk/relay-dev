import RelayProtocol
import RelayUI
import SwiftUI

/// A subagent in the sidebar: that it exists, what it was asked to do, and
/// whether it is still at it.
///
/// A line rather than a row, because it is not a terminal: there is nothing
/// to type to it, rename or close, and a click goes to the session that
/// started it. The mark is the one a session wears, so the same glance
/// answers for both.
struct SubagentRow: View {
    @Environment(AppModel.self) private var model

    let subagent: SubagentSnapshot
    let session: SessionSnapshot
    /// Listed under another worktree than its session's, where the line has
    /// to say whose it is.
    let isVisiting: Bool

    @State private var isHovering = false

    /// Where a session row's title starts — past its padding, its glyph and
    /// the gap after it — so a subagent under it reads as its child.
    static let nestedInset: CGFloat = Theme.Spacing.small + 24 + Theme.Spacing.small

    var body: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            mark

            Text(verbatim: title)
                .font(Theme.Typography.caption)
                .foregroundStyle(subagent.status == .finished ? Theme.Palette.textTertiary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: Theme.Spacing.xsmall)

            if let aside {
                Text(verbatim: aside)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The task is what the line is for; whose it is or what
                    // kind gives way first.
                    .layoutPriority(-1)
            }
        }
        .padding(.leading, isVisiting ? Theme.Spacing.small : Self.nestedInset)
        .padding(.trailing, Theme.Spacing.small)
        .padding(.vertical, 3)
        .background(isHovering ? Theme.Palette.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .clickable()
        .onHover { isHovering = $0 }
        .onTapGesture { model.selectSession(session.id) }
        .relayTooltip(tooltip, edge: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip)
        .accessibilityAddTraits(.isButton)
    }

    /// Under another worktree the mark sits where a session's glyph would, so
    /// the task lines up with the titles of the sessions around it.
    @ViewBuilder
    private var mark: some View {
        let dot = StatusDot(status: subagent.status, size: 6)
        if isVisiting {
            dot.frame(width: 24)
                .padding(.trailing, Theme.Spacing.small - Theme.Spacing.xsmall)
        } else {
            dot
        }
    }

    private var title: String {
        subagent.description ?? subagent.agentType ?? relayLocalized("Subagent")
    }

    private var aside: String? {
        if isVisiting { return model.label(for: session) }
        return subagent.description == nil ? nil : subagent.agentType
    }

    private var tooltip: String {
        var lines = [title]
        lines.append([subagent.agentType, activity].compactMap { $0 }.joined(separator: " · "))
        if subagent.runsInBackground, subagent.status != .finished {
            lines.append(relayLocalized("Runs in the background"))
        }
        if isVisiting {
            lines.append(String(format: relayLocalized("Started by %@"), model.label(for: session)))
        }
        return lines.joined(separator: "\n")
    }

    private var activity: String {
        switch subagent.status {
        case .waiting: relayLocalized("Waiting for you")
        case .working, .starting: relayLocalized("Working")
        case .finished: relayLocalized("Finished")
        case .error: relayLocalized("Error")
        case .idle, .offline: subagent.status.localizedName
        }
    }
}
