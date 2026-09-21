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
            HStack(spacing: 0) {
                Button {
                    model.isUsagePopoverOpen.toggle()
                } label: {
                    HStack(spacing: Theme.Spacing.large) {
                        ForEach(model.usage.agents) { usage in
                            AgentUsageChip(usage: usage, detail: model.usageBarDetail)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()

                // Beside the figures it refreshes, not at the other end of the
                // window from them.
                IconButton(
                    systemImage: "arrow.clockwise",
                    help: "",
                    size: 20,
                    isBusy: model.usage.isRefreshing
                ) {
                    Task { await model.usage.refresh(force: true) }
                }
                .relayTooltip(relayLocalized("Refresh usage"), edge: .top)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.small)
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
    let detail: UsageDetail

    /// Compact keeps only the window nearest to running out. The tooltip still
    /// lists every one, so the short form loses nothing but width.
    private var shown: [UsageWindow] {
        guard detail == .compact else { return usage.windows }
        return usage.mostUsedWindow.map { [$0] } ?? usage.windows
    }

    var body: some View {
        // Redrawn on a slow timer so the countdown moves without anything
        // needing to tell it to.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: Theme.Spacing.small) {
                SessionGlyph(kind: usage.kind, size: 11, tint: Color(hex: usage.kind.accentHex))

                ForEach(shown) { window in
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

            UsageMeter(window: window)

            Text(verbatim: "\(window.percent)%")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .monospacedDigit()
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
