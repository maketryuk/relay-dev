import RelayProtocol
import RelayUI
import SwiftUI

/// What the status bar opens when you click it.
///
/// A popover rather than a panel: this is something you glance at and let go
/// of, anchored to the thing that raised the question. The panels are for work
/// you do; this is a number you check.
struct UsagePopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RelayDivider()

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Picker("", selection: Binding(
                    get: { model.usageDetail },
                    set: { model.setUsageDetail($0) }
                )) {
                    ForEach(UsageDetail.allCases) { detail in
                        Text(detail.title).tag(detail)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ForEach(model.usage.agents) { usage in
                    AgentUsageRow(usage: usage, detail: model.usageDetail)
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .frame(width: 320)
        .background(Theme.Palette.base)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(relayLocalized("Usage"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: Theme.Spacing.small)
            IconButton(
                systemImage: "arrow.clockwise",
                help: "",
                size: 22,
                isBusy: model.usage.isRefreshing
            ) {
                Task { await model.usage.refresh() }
            }
            .relayTooltip(relayLocalized("Refresh usage"))
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small + 2)
    }
}

/// One agent in the popover.
///
/// Compact shows only the window closest to running out; hovering the row brings
/// the rest back, so the short form costs nothing to look past.
private struct AgentUsageRow: View {
    let usage: AgentUsage
    let detail: UsageDetail

    @State private var isHovering = false

    private var shown: [UsageWindow] {
        guard detail == .compact, !isHovering else { return usage.windows }
        return usage.mostUsedWindow.map { [$0] } ?? usage.windows
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
                    SessionGlyph(kind: usage.kind, size: 13, tint: Color(hex: usage.kind.accentHex))
                    Text(relayLocalized(usage.kind.displayName))
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    if let reset = usage.nextReset,
                       let countdown = UsageFormatting.countdown(to: reset, from: context.date) {
                        Text(String(format: relayLocalized("Resets in %@"), countdown))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }

                ForEach(shown) { window in
                    row(window)
                }
            }
            .padding(Theme.Spacing.small)
            .background(isHovering ? Theme.Palette.surfaceHover : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: shown.count)
        }
    }

    private func row(_ window: UsageWindow) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(window.name)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.small)

            UsageMeter(window: window, width: 56)

            Text(verbatim: "\(window.percent)%")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textPrimary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// The one meter drawn for a usage window, wherever it appears.
struct UsageMeter: View {
    let window: UsageWindow
    var width: CGFloat = 26

    var body: some View {
        Capsule()
            .fill(Theme.Palette.surfaceRaised)
            .frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .frame(width: width * min(max(window.fraction, 0), 1))
            }
    }

    /// Quiet until it matters. A bar that is red at 40% teaches people to ignore
    /// it by the time it means something.
    private var tint: Color {
        switch window.fraction {
        case 0.9...: Theme.Palette.statusError
        case 0.75...: Theme.Palette.statusWaiting
        default: Theme.Palette.accent
        }
    }
}
