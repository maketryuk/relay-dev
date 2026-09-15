import RelayProtocol
import RelayUI
import SwiftUI

/// Every host from the user's OpenSSH configuration.
///
/// Hosts are global, not per-project — `~/.ssh/config` describes the machine,
/// not the repository in front of you. Pinning still exists, and pinned hosts
/// float to the top for whichever project is selected, but the list itself no
/// longer clutters a project sidebar it does not belong to.
struct SSHPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()
            content
        }
        .onAppear { model.loadSSHHosts() }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(verbatim: "\(model.sshHosts.count) \(relayLocalized("in ~/.ssh/config"))")
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                IconButton(systemImage: "arrow.clockwise", help: "", size: 24) { model.loadSSHHosts() }
                    .relayTooltip(relayLocalized("Reload config"))
            }
            RelayTextField(relayLocalized("Filter by alias or host"), text: $query, systemImage: "magnifyingglass")
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.bottom, Theme.Spacing.medium)
    }

    @ViewBuilder
    private var content: some View {
        let groups = model.sshHosts(for: model.selectedProjectID)
        let pinned = groups.pinned.filter { matches($0) }
        let others = groups.others.filter { matches($0) }

        if pinned.isEmpty, others.isEmpty {
            EmptyStateView(
                systemImage: "network",
                title: model.sshHosts.isEmpty ? "No hosts configured" : "No match",
                message: model.sshHosts.isEmpty
                    ? "Relay reads ~/.ssh/config, including Include directives. Nothing there yet."
                    : "No host matches “\(query)”."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    if !pinned.isEmpty {
                        Section {
                            ForEach(pinned) { row($0, isPinned: true) }
                        } header: {
                            sectionHeader("Pinned to \(model.selectedProject?.name ?? "this project")")
                        }
                    }
                    if !others.isEmpty {
                        Section {
                            ForEach(others) { row($0, isPinned: false) }
                        } header: {
                            sectionHeader(pinned.isEmpty ? "All hosts" : "Other hosts")
                        }
                    }
                }
                .padding(Theme.Spacing.small)
            }
        }
    }

    private func matches(_ host: SSHHost) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return true }
        return host.alias.lowercased().contains(trimmed)
            || host.displayTarget.lowercased().contains(trimmed)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.Typography.sectionHeader)
            .tracking(0.7)
            .foregroundStyle(Theme.Palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 6)
            .background(Theme.Palette.base)
    }

    private func row(_ host: SSHHost, isPinned: Bool) -> some View {
        SidebarRow(
            title: host.alias,
            subtitle: host.identityFile.map { "\(host.displayTarget) · \($0)" } ?? host.displayTarget,
            systemImage: isPinned ? "pin.fill" : "network",
            iconTint: isPinned ? Theme.Palette.statusWaiting : nil,
            isSelected: false,
            action: { connect(host) },
            accessoryVisibility: .always
        ) {
            HStack(spacing: 0) {
                IconButton(systemImage: isPinned ? "pin.slash" : "pin", help: "", size: 24) {
                    guard let projectID = model.selectedProjectID else { return }
                    model.togglePin(host, in: projectID)
                }
                .relayTooltip(isPinned ? "Unpin from project" : "Pin to current project")

                IconButton(systemImage: "arrow.right.circle", help: "", size: 24) { connect(host) }
                    .relayTooltip(relayLocalized("Connect"))
            }
        }
        .contextMenu {
            Button(relayLocalized("Connect")) { connect(host) }
            if model.selectedProjectID != nil {
                Button(isPinned ? "Unpin from Project" : "Pin to Project") {
                    guard let projectID = model.selectedProjectID else { return }
                    model.togglePin(host, in: projectID)
                }
            }
        }
    }

    private func connect(_ host: SSHHost) {
        guard let projectID = model.selectedProjectID else { return }
        model.connectSSH(host, in: projectID)
    }
}
