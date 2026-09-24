import RelayProtocol
import RelayUI
import SwiftUI

/// A session in the sidebar.
///
/// The glyph carries the status rather than a separate dot at the far end: the
/// question "what is this and does it need me" should be answerable without the
/// eye travelling across the row. The working directory is deliberately absent —
/// it is already in the project header — while the branch is present, because
/// it is the branch of the worktree the session is in, and that is not the same
/// for every session.
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
                // Always present, whatever the state. A line that appears only
                // when there is something to say makes the row change height as
                // an agent works, and leaves "what is this doing" answerable
                // only by the colour of a dot.
                Text(activity)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
        .clickable()
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
            Text(model.label(for: session))
                .font(Theme.Typography.row)
                .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                // The sidebar is narrow and an agent's name is a sentence, so
                // what is on the row is usually the first half of it.
                .relayTooltip(model.label(for: session), edge: .trailing)

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
        if session.kind == .ssh {
            // The branch and the diff belong to the Mac Relay runs on, and this
            // session is not on it: `master +589 −36` beside a connection to
            // somebody else's server is true about the wrong computer. Where
            // the connection goes is the thing worth the same line.
            if let destination {
                HStack(spacing: Theme.Spacing.xsmall) {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(destination)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.xsmall)
                }
            }
        } else if let git = model.gitStatus(of: session) {
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

    /// `user@host:port` as the configuration spells it, falling back to the
    /// alias when the host has since been renamed or removed.
    private var destination: String? {
        guard let alias = SSHDestination.alias(inCommand: session.command) else { return nil }
        return model.sshHosts.first { $0.alias == alias }?.displayTarget ?? alias
    }

    /// The state line: what the session is doing, or how it ended.
    private var activity: String {
        if let exitCode = session.exitCode {
            return exitCode == 0 ? relayLocalized("Exited") : relayLocalized("Exited with an error")
        }
        switch session.status {
        case .waiting: return relayLocalized("Waiting for you")
        case .working: return relayLocalized("Working")
        case .starting: return relayLocalized("Starting")
        case .finished: return relayLocalized("Finished")
        case .error: return relayLocalized("Error")
        case .idle, .offline: return session.status.localizedName
        }
    }

    private var showsStatusBadge: Bool {
        session.reportsStatus
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
                // `verbatim`, or SwiftUI reads the interpolation as a localised
                // number and writes 1 111 for a thousand and eleven lines.
                Text(verbatim: "+\(insertions)")
                    .foregroundStyle(Theme.Palette.statusFinished)
            }
            if deletions > 0 {
                Text(verbatim: "−\(deletions)")
                    .foregroundStyle(Theme.Palette.statusError)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        // Never narrower than its numbers: squeezed, a count wraps a digit
        // onto a second line, and the name beside it is what should give way.
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Theme.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
