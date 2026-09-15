import RelayProtocol
import RelayUI
import SwiftUI

/// The strip along the bottom of the window, mirroring the title bar.
///
/// It carries what the agents have left rather than what Relay is doing: their
/// own CLIs know their limits and say so on disk, and having to open a terminal
/// to find out how much of a weekly window is gone is exactly the kind of thing
/// this app exists to stop.
///
/// Absent entirely when there is nothing to report. An empty strip along the
/// bottom of every window is worse than no strip at all.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.usage.agents.isEmpty {
            HStack(spacing: Theme.Spacing.large) {
                ForEach(model.usage.agents) { usage in
                    AgentUsageChip(usage: usage)
                }

                Spacer(minLength: Theme.Spacing.small)

                IconButton(
                    systemImage: "arrow.clockwise",
                    help: "",
                    size: 20,
                    isBusy: model.usage.isRefreshing
                ) {
                    Task { await model.usage.refresh() }
                }
                .relayTooltip(relayLocalized("Refresh usage"), edge: .top)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(height: Theme.Metrics.statusBarHeight)
            .background(Theme.Palette.rail)
            .overlay(alignment: .top) { RelayDivider() }
        }
    }
}

/// One agent's windows: its mark, a meter per window, and how long until the
/// nearest one rolls over.
private struct AgentUsageChip: View {
    let usage: AgentUsage

    var body: some View {
        // Redrawn on a slow timer so the countdown moves without anything
        // needing to tell it to.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: Theme.Spacing.small) {
                SessionGlyph(kind: usage.kind, size: 11, tint: Color(hex: usage.kind.accentHex))

                ForEach(usage.windows) { window in
                    meter(window)
                }

                if let reset = usage.nextReset,
                   let countdown = UsageFormatting.countdown(to: reset, from: context.date) {
                    Text(countdown)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .monospacedDigit()
                }
            }
            .relayTooltip(tooltip(now: context.date), edge: .top)
        }
    }

    private func meter(_ window: UsageWindow) -> some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            Text(window.label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)

            Capsule()
                .fill(Theme.Palette.surfaceRaised)
                .frame(width: 26, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint(for: window))
                        .frame(width: 26 * min(max(window.fraction, 0), 1))
                }

            Text(verbatim: "\(window.percent)%")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .monospacedDigit()
        }
    }

    /// Quiet until it matters. A bar that is red at 40% teaches people to ignore
    /// it by the time it means something.
    private func tint(for window: UsageWindow) -> Color {
        switch window.fraction {
        case 0.9...: Theme.Palette.statusError
        case 0.75...: Theme.Palette.statusWaiting
        default: Theme.Palette.accent
        }
    }

    private func tooltip(now: Date) -> String {
        var lines = usage.windows.map { window -> String in
            let reset = window.resetsAt
                .flatMap { UsageFormatting.countdown(to: $0, from: now) }
                .map { " · " + String(format: relayLocalized("resets in %@"), $0) } ?? ""
            // Spelled out here, where there is room: `wk` is fine in the bar and
            // means nothing on its own.
            return "\(window.name) \(window.percent)%\(reset)"
        }
        if let fetched = usage.fetchedAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            lines.append(String(format: relayLocalized("as of %@"), formatter.string(from: fetched)))
        }
        return lines.joined(separator: "\n")
    }
}
