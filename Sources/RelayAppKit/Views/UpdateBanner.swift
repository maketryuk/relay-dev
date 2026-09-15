import RelayUI
import SwiftUI

/// The pill in the title bar that says a new version is waiting.
///
/// Persistent rather than a toast: an update is not an event that has happened,
/// it is a thing available until it is taken. It only appears when there is
/// something to say — a check that found nothing leaves no trace at all.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.updates.state {
        case let .available(release):
            pill(
                systemImage: "arrow.down.circle.fill",
                text: String(format: relayLocalized("%@ available"), release.version.description),
                tint: Theme.Palette.accent
            ) { model.updates.install() }
                .relayTooltip(relayLocalized("Download and restart into the new version"))

        case let .downloading(_, fraction):
            progressPill(fraction: fraction, text: relayLocalized("Downloading…"))

        case .installing:
            progressPill(fraction: nil, text: relayLocalized("Installing…"))

        case let .failed(message):
            pill(
                systemImage: "exclamationmark.triangle.fill",
                text: relayLocalized("Update failed"),
                tint: Theme.Palette.statusError
            ) { model.updates.openReleasePage() }
                .relayTooltip(message)

        case .idle, .checking, .upToDate:
            EmptyView()
        }
    }

    private func pill(
        systemImage: String,
        text: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xsmall) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                Text(text).font(Theme.Typography.caption)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func progressPill(fraction: Double?, text: String) -> some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            ProgressView().controlSize(.small).scaleEffect(0.6)
            Text(fraction.map { String(format: "%@ %d%%", text, Int($0 * 100)) } ?? text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 3)
        .background(Theme.Palette.surfaceRaised)
        .clipShape(Capsule())
    }
}
