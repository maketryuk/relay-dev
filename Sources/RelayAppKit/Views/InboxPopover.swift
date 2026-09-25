import RelayProtocol
import RelayUI
import SwiftUI

/// What happened while you were not looking.
struct InboxPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RelayDivider()

            if model.inbox.isEmpty {
                Text(relayLocalized("Nothing yet. Agents waiting on you, failures and finished work land here."))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(Theme.Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.inbox) { item in
                            row(item)
                        }
                    }
                    .padding(Theme.Spacing.xsmall)
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 340)
        .background(Theme.Palette.surface)
    }

    private var header: some View {
        HStack {
            Text(relayLocalized("NOTIFICATIONS"))
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer()
            if model.unreadNotificationCount > 0 {
                Button(relayLocalized("Mark all read")) { model.markAllNotificationsRead() }
                    .buttonStyle(.plain)
                    .clickable()
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
            }
            if !model.inbox.isEmpty {
                IconButton(systemImage: "trash", help: "", size: 24) { model.clearNotifications() }
                    .relayTooltip(relayLocalized("Clear all"))
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }

    private func row(_ item: InboxItem) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Circle()
                .fill(tint(item.event.kind))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
                .opacity(item.isRead ? 0.35 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.event.title)
                    .font(Theme.Typography.row)
                    .foregroundStyle(item.isRead ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(item.event.body)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: relayRelativeTime(item.occurredAt, relativeTo: Date()))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 6)
        .background(item.isRead ? Color.clear : Theme.Palette.surfaceRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .clickable()
        .onTapGesture {
            model.openNotification(item)
            model.isInboxOpen = false
        }
    }

    private func tint(_ kind: NotificationKind) -> Color {
        switch kind {
        case .waitingForInput: Theme.Palette.statusWaiting
        case .failed: Theme.Palette.statusError
        case .finished: Theme.Palette.statusFinished
        }
    }
}
