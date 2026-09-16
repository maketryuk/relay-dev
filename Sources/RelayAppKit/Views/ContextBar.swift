import RelayProtocol
import RelayUI
import SwiftUI

/// The line under a terminal saying how full the agent's context window is.
///
/// Under every agent terminal, and under no shell: a shell has no context to
/// fill, and a bar that sits at zero forever teaches people to stop reading it.
/// An agent that has not been spoken to yet keeps the row and shows a dash —
/// it has written no transcript, so there is nothing to read, and a row that
/// only appears with the first reply reads as one pane behaving differently
/// from the one beside it.
struct ContextBar: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot

    private var context: SessionContext? { model.context.context(for: session.id) }

    var body: some View {
        if session.kind.isAgent {
            // The strip runs the width of the pane; the control does not. A
            // button stretched across the empty half of a bar answers clicks
            // where nothing is drawn, and hangs its tooltip over the middle of
            // the terminal — away from the numbers it is explaining.
            HStack(spacing: 0) {
                Button {
                    guard context != nil else { return }
                    model.sessionShowingContextDetail =
                        model.sessionShowingContextDetail == session.id ? nil : session.id
                } label: {
                    reading
                }
                .buttonStyle(.plain)
                .clickable()
                // Silent while the panel it opens is up: the tooltip asks the
                // question the panel is already answering, and after a click
                // the pointer is still sitting there to be asked.
                .relayTooltip(
                    tooltip,
                    edge: .top,
                    isEnabled: model.sessionShowingContextDetail != session.id
                )

                Spacer(minLength: 0)
            }
            .frame(height: Theme.Metrics.contextBarHeight)
            .background(Theme.Palette.sidebar)
            .overlay(alignment: .top) { RelayDivider() }
        }
    }

    private var reading: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(relayLocalized("Context"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)

            ContextMeter(fraction: context?.fraction, width: 52)

            if let context {
                if let percent = context.percent {
                    Text(verbatim: "\(percent)%")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .monospacedDigit()
                }

                Text(verbatim: TokenFormatting.short(context.tokens))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .monospacedDigit()
            } else {
                // A dash rather than a zero: nothing has been measured. The CLI
                // writes its transcript as it answers, so before the first
                // reply the figure does not exist anywhere to be read from.
                Text(verbatim: "—")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .frame(height: Theme.Metrics.contextBarHeight)
        .contentShape(Rectangle())
    }

    private var tooltip: String {
        context == nil
            ? relayLocalized("Filled in once the agent has answered")
            : relayLocalized("What is in the context window")
    }
}

/// The meter, drawn empty when there is nothing to show yet.
struct ContextMeter: View {
    let fraction: Double?
    var width: CGFloat = 52

    var body: some View {
        Capsule()
            .fill(Theme.Palette.surfaceRaised)
            .frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .frame(width: width * (fraction ?? 0))
            }
    }

    /// A context window is not a rate limit: filling it is ordinary, and only
    /// the last stretch — where a conversation is about to be compacted — is
    /// worth a colour.
    private var tint: Color {
        switch fraction ?? 0 {
        case 0.9...: Theme.Palette.statusError
        case 0.75...: Theme.Palette.statusWaiting
        default: Theme.Palette.accent
        }
    }
}

/// What is actually in the window, for the session in front of the user.
struct ContextDetail: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot
    let context: SessionContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RelayDivider()

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(context.slices) { slice in
                    row(slice)
                }

                RelayDivider()
                    .padding(.vertical, 2)

                summary
            }
            .padding(Theme.Spacing.medium)
        }
        .frame(width: 300)
        .background(Theme.Palette.base)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            SessionGlyph(kind: session.kind, size: 12, tint: Color(hex: session.kind.accentHex))
            Text(relayLocalized("Context"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: Theme.Spacing.small)
            IconButton(systemImage: "xmark", help: "", size: 20) {
                model.sessionShowingContextDetail = nil
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small + 2)
    }

    private func row(_ slice: ContextSlice) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(slice.name)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: Theme.Spacing.small)
            Text(verbatim: TokenFormatting.short(slice.tokens))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textPrimary)
                .monospacedDigit()
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            detail(relayLocalized("In the window"), TokenFormatting.short(context.tokens))
            if let window = context.window {
                // Said plainly, because for Claude it is worked out rather than
                // read: the CLI records neither the window nor the suffix that
                // tells the long-context variant apart.
                detail(
                    context.isWindowDeclared
                        ? relayLocalized("Window")
                        : relayLocalized("Window (inferred)"),
                    TokenFormatting.short(window)
                )
            }
            if let model = context.model {
                detail(relayLocalized("Model"), model)
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer(minLength: Theme.Spacing.small)
            Text(verbatim: value)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
