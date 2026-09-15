import RelayProtocol
import RelayUI
import SwiftUI

/// The window's own bar, spanning its full width.
///
/// Relay draws its own chrome, which means the title bar has to be built rather
/// than inherited — and a title bar is not just decoration: it is the region
/// that drags and zooms the window. Scattering that behaviour across three
/// panel headers is what made double-clicking unreliable, because each header
/// also holds buttons. Here the draggable parts are explicit and empty by
/// construction.
struct TitleBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var isSearchHovering = false

    /// Room for the traffic lights, which float over whatever is beneath them.
    private let trafficLightInset: CGFloat = 76

    var body: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            Color.clear.frame(width: trafficLightInset, height: 1)

            sidebarToggles

            WindowDragArea()
                .frame(minWidth: Theme.Spacing.small, maxWidth: .infinity, maxHeight: .infinity)

            searchField

            WindowDragArea()
                .frame(minWidth: Theme.Spacing.small, maxWidth: .infinity, maxHeight: .infinity)

            trailingControls
        }
        .padding(.horizontal, Theme.Spacing.small)
        .frame(height: Theme.Metrics.titleBarHeight)
        .background(Theme.Palette.rail)
        .overlay(alignment: .bottom) { RelayDivider() }
    }

    private var sidebarToggles: some View {
        HStack(spacing: 2) {
            IconButton(systemImage: "sidebar.leading", help: "", size: 24) {
                model.toggleLeftSidebar()
            }
            .relayTooltip(relayLocalized("Sessions sidebar"), shortcut: model.binding(for: .toggleLeftSidebar))

            IconButton(systemImage: "sidebar.trailing", help: "", size: 24) {
                model.toggleRightSidebar()
            }
            .relayTooltip(relayLocalized("Project panel"), shortcut: model.binding(for: .toggleRightSidebar))
        }
    }

    private var searchField: some View {
        Button {
            model.isCommandPaletteOpen = true
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(placeholder)
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.small)
                if let shortcut = model.binding(for: .commandPalette)?.displayString {
                    Text(shortcut)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .padding(.horizontal, Theme.Spacing.small + 2)
            .frame(height: 24)
            .frame(maxWidth: 460)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(
                        isSearchHovering ? Theme.Palette.borderStrong : Theme.Palette.border,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isSearchHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isSearchHovering)
    }

    private var placeholder: String {
        model.selectedProject.map { "Search \($0.name) — sessions, services, hosts…" }
            ?? "Search sessions, services, hosts…"
    }

    private var trailingControls: some View {
        HStack(spacing: 2) {
            if let projectID = model.selectedProjectID,
               let git = model.gitStatuses[projectID],
               git.hasDiff {
                DiffBadge(insertions: git.insertions, deletions: git.deletions)
                    .padding(.trailing, Theme.Spacing.xsmall)
            }

            IconButton(systemImage: "gearshape", help: "", size: 24) {
                openSettings()
            }
            .relayTooltip(relayLocalized("Settings"), shortcut: model.binding(for: .openSettings))

            notificationsButton
        }
    }

    private var notificationsButton: some View {
        @Bindable var model = model
        let unread = model.unreadNotificationCount

        return IconButton(
            systemImage: unread > 0 ? "bell.badge.fill" : "bell",
            size: 24,
            tint: unread > 0 ? Theme.Palette.statusWaiting : nil
        ) {
            model.isInboxOpen.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if unread > 0 {
                Text(unread > 9 ? "9+" : "\(unread)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Palette.base)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Theme.Palette.statusWaiting)
                    .clipShape(Capsule())
                    .offset(x: 4, y: -2)
                    .allowsHitTesting(false)
            }
        }
        .relayTooltip(unread > 0 ? "\(unread) unread" : "Notifications")
        .popover(isPresented: $model.isInboxOpen, arrowEdge: .bottom) {
            InboxPopover()
        }
    }
}
