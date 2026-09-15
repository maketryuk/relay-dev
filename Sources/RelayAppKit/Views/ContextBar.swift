import RelayProtocol
import RelayUI
import SwiftUI

/// The line under a terminal saying how full the agent's context window is.
///
/// Present only for the agents that report one. A shell has no context to fill,
/// and a bar that sits at zero forever teaches people to stop reading it.
struct ContextBar: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot

    var body: some View {
        if let context = model.context.context(for: session.id) {
            Button {
                model.sessionShowingContextDetail =
                    model.sessionShowingContextDetail == session.id ? nil : session.id
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Text(relayLocalized("Context"))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)

                    ContextMeter(context: context, width: 52)

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

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .frame(height: Theme.Metrics.contextBarHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.Palette.sidebar)
            .overlay(alignment: .top) { RelayDivider() }
            .relayTooltip(relayLocalized("What is in the context window"), edge: .top)
        }
    }
}

/// The meter, shared by the bar and the detail panel.
struct ContextMeter: View {
    let context: SessionContext
    var width: CGFloat = 52

    var body: some View {
        Capsule()
            .fill(Theme.Palette.surfaceRaised)
            .frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .frame(width: width * (context.fraction ?? 0))
            }
    }

    /// A context window is not a rate limit: filling it is ordinary, and only
    /// the last stretch — where a conversation is about to be compacted — is
    /// worth a colour.
    private var tint: Color {
        switch context.fraction ?? 0 {
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
