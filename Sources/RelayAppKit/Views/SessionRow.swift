import RelayProtocol
import RelayUI
import SwiftUI

/// A session in the sidebar.
///
/// The glyph carries the status rather than a separate dot at the far end: the
/// question "what is this and does it need me" should be answerable without the
/// eye travelling across the row. The working directory is deliberately absent —
/// it is already in the project header — while the branch is present, because
/// once worktrees land it stops being the same for every session.
struct SessionRow: View {
    @Environment(AppModel.self) private var model

    let session: SessionSnapshot
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            glyph

            VStack(alignment: .leading, spacing: 2) {
                titleLine
                if let activity {
                    Text(activity)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                footerLine
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 7)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(isSelected ? Theme.Palette.borderStrong : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onRename)
        .onTapGesture(count: 1, perform: onSelect)
    }

    // MARK: - Pieces

    private var glyph: some View {
        ZStack(alignment: .bottomTrailing) {
            SessionGlyph(
                kind: session.kind,
                size: 15,
                tint: Color(hex: session.kind.accentHex)
            )
            .frame(width: 22, height: 22)

            // The status rides on the glyph so one glance answers both
            // "which agent" and "does it want me".
            if showsStatusBadge {
                StatusDot(status: session.status, size: 7, showsRing: true)
                    .offset(x: 3, y: 2)
            }
        }
        .frame(width: 24, height: 24)
    }

    private var titleLine: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            Text(session.displayName)
                .font(Theme.Typography.row)
                .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.xsmall)

            HoverReveal(isVisible: isHovering) {
                IconButton(systemImage: "xmark", help: "", size: 16) {
                    model.closeSession(session.id)
                }
                .relayTooltip(relayLocalized("Close session"), shortcut: model.binding(for: .closeSession))
            }
        }
    }

    @ViewBuilder
    private var footerLine: some View {
        if let git = model.gitStatuses[session.projectID] {
            HStack(spacing: Theme.Spacing.xsmall) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(git.branch)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)

                Spacer(minLength: Theme.Spacing.xsmall)

                if git.hasDiff {
                    DiffBadge(insertions: git.insertions, deletions: git.deletions)
                }
            }
        }
    }

    /// The state line: what the session is doing, or how it ended.
    private var activity: String? {
        if let exitCode = session.exitCode {
            return exitCode == 0 ? relayLocalized("Exited") : relayLocalized("Exited with an error")
        }
        switch session.status {
        case .waiting: return relayLocalized("Waiting for you")
        case .working: return relayLocalized("Working")
        case .starting: return relayLocalized("Starting")
        case .finished: return relayLocalized("Finished")
        case .error: return relayLocalized("Error")
        case .idle, .offline: return nil
        }
    }

    /// An idle shell does not need a coloured dot; an agent always does.
    private var showsStatusBadge: Bool {
        if session.exitCode != nil { return true }
        switch session.status {
        case .idle, .offline: return session.kind != .shell
        default: return true
        }
    }

    private var background: Color {
        if isSelected { return Theme.Palette.surfaceActive }
        return isHovering ? Theme.Palette.surfaceHover : .clear
    }
}

/// `+44 −19`, coloured the way a diff is.
struct DiffBadge: View {
    let insertions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            if insertions > 0 {
                Text("+\(insertions)")
                    .foregroundStyle(Theme.Palette.statusFinished)
            }
            if deletions > 0 {
                Text("−\(deletions)")
                    .foregroundStyle(Theme.Palette.statusError)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Theme.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
