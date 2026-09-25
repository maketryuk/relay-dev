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
    @State private var focus = ListFocus()

    /// The rows as the keyboard sees them: one list, in the order drawn.
    private var orderedHosts: [SSHHost] {
        let groups = model.sshHosts(for: model.selectedProjectID)
        return groups.pinned.filter(matches) + groups.others.filter(matches)
    }

    private var focusedHost: SSHHost? {
        orderedHosts.indices.contains(focus.row) ? orderedHosts[focus.row] : nil
    }

    /// What a row offers, in the order left and right walk them.
    private func actions(for host: SSHHost, isPinned: Bool) -> [RowAction] {
        var actions = [
            RowAction(
                id: "connect",
                systemImage: "arrow.right.circle",
                label: relayLocalized("Connect")
            ) { connect(host) },
        ]
        if model.selectedProjectID != nil {
            actions.append(RowAction(
                id: "pin",
                systemImage: isPinned ? "pin.slash" : "pin",
                label: isPinned ? relayLocalized("Unpin from Project") : relayLocalized("Pin to Project")
            ) {
                guard let projectID = model.selectedProjectID else { return }
                model.togglePin(host, in: projectID)
            })
        }
        actions.append(RowAction(
            id: "edit",
            systemImage: "pencil",
            label: relayLocalized("Edit Host")
        ) { model.presentModal(.sshHostEditor(alias: host.alias)) })
        actions.append(RowAction(
            id: "delete",
            systemImage: "trash",
            label: relayLocalized("Delete Host"),
            tint: Theme.Palette.statusError
        ) { model.sshHostPendingDeletion = host })
        return actions
    }

    private func isPinned(_ host: SSHHost) -> Bool {
        model.sshHosts(for: model.selectedProjectID).pinned.contains(host)
    }

    var body: some View {
        let focusedActions = focusedHost.map { actions(for: $0, isPinned: isPinned($0)) } ?? []

        return VStack(spacing: 0) {
            header
            RelayDivider()
            content
        }
        .keyboardNavigableList(
            rowCount: orderedHosts.count,
            actionCount: focusedActions.count,
            focus: $focus
        ) {
            guard focusedActions.indices.contains(focus.action) else { return }
            focusedActions[focus.action].run()
        }
        .onAppear { model.loadSSHHosts() }
        .confirmationDialog(
            relayLocalized("Delete this host?"),
            isPresented: Binding(
                get: { model.sshHostPendingDeletion != nil },
                set: { if !$0 { model.sshHostPendingDeletion = nil } }
            ),
            presenting: model.sshHostPendingDeletion
        ) { host in
            Button(relayLocalized("Delete Host"), role: .destructive) {
                model.deleteSSHHost(host)
                model.sshHostPendingDeletion = nil
            }
            Button(relayLocalized("Cancel"), role: .cancel) { model.sshHostPendingDeletion = nil }
        } message: { host in
            Text(verbatim: String(
                format: relayLocalized("The block naming %@ is removed from %@."),
                host.alias,
                host.definitions.first.map { HomeRelativePath.abbreviating($0.file) } ?? "~/.ssh/config"
            ))
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(verbatim: "\(model.sshHosts.count) \(relayLocalized("in ~/.ssh/config"))")
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                IconButton(systemImage: "doc.text", help: "", size: 24) { model.openSSHConfig() }
                    .relayTooltip(relayLocalized("Edit the config file"))
                IconButton(systemImage: "plus", help: "", size: 24) {
                    model.presentModal(.sshHostEditor(alias: nil))
                }
                .relayTooltip(relayLocalized("New Host"))
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
            VStack(spacing: Theme.Spacing.medium) {
                EmptyStateView(
                    systemImage: "network",
                    title: model.sshHosts.isEmpty ? relayLocalized("No hosts configured") : relayLocalized("No match"),
                    message: model.sshHosts.isEmpty
                        ? relayLocalized("Relay reads ~/.ssh/config, including Include directives. Nothing there yet.")
                        : String(format: relayLocalized("No host matches “%@”."), query)
                )
                .fixedSize(horizontal: false, vertical: true)
                if model.sshHosts.isEmpty {
                    HStack(spacing: Theme.Spacing.small) {
                        RelayButton(relayLocalized("New Host"), systemImage: "plus", kind: .primary) {
                            model.presentModal(.sshHostEditor(alias: nil))
                        }
                        RelayButton(relayLocalized("Edit the config file"), kind: .secondary) {
                            model.openSSHConfig()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            KeyboardScrollingList(
                focusedRow: focus.row,
                identifyingRow: { orderedHosts.indices.contains($0) ? orderedHosts[$0].id : nil }
            ) {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    if !pinned.isEmpty {
                        Section {
                            ForEach(Array(pinned.enumerated()), id: \.element.id) { index, host in
                                row(host, isPinned: true, at: index)
                            }
                        } header: {
                            sectionHeader(model.selectedProject.map { String(format: relayLocalized("Pinned to %@"), $0.name) }
                                ?? relayLocalized("Pinned to this project"))
                        }
                    }
                    if !others.isEmpty {
                        Section {
                            ForEach(Array(others.enumerated()), id: \.element.id) { index, host in
                                row(host, isPinned: false, at: pinned.count + index)
                            }
                        } header: {
                            sectionHeader(pinned.isEmpty ? relayLocalized("All hosts") : relayLocalized("Other hosts"))
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

    private func row(_ host: SSHHost, isPinned: Bool, at index: Int) -> some View {
        SidebarRow(
            title: host.alias,
            subtitle: host.identityFile.map { "\(host.displayTarget) · \($0)" } ?? host.displayTarget,
            systemImage: isPinned ? "pin.fill" : "network",
            iconTint: isPinned ? Theme.Palette.statusWaiting : nil,
            isSelected: index == focus.row,
            action: { connect(host) },
            accessoryVisibility: .always
        ) {
            RowActionBar(
                actions: actions(for: host, isPinned: isPinned),
                focusedAction: index == focus.row ? focus.action : nil
            )
        }
        .id(host.id)
        .contextMenu {
            Button(relayLocalized("Connect")) { connect(host) }
            if model.selectedProjectID != nil {
                Button(isPinned ? relayLocalized("Unpin from Project") : relayLocalized("Pin to Project")) {
                    guard let projectID = model.selectedProjectID else { return }
                    model.togglePin(host, in: projectID)
                }
            }
            Divider()
            Button(relayLocalized("Edit Host")) { model.presentModal(.sshHostEditor(alias: host.alias)) }
            if let definition = host.definitions.first {
                Button(relayLocalized("Open in the config file")) {
                    model.openSSHConfig(atLine: definition.lines.lowerBound + 1)
                }
            }
            Button(relayLocalized("Delete Host"), role: .destructive) {
                model.sshHostPendingDeletion = host
            }
        }
    }

    private func connect(_ host: SSHHost) {
        guard let projectID = model.selectedProjectID else { return }
        model.connectSSH(host, in: projectID)
        // Connecting is what the list is for, not a step in using it: the
        // session it opens is behind the panel that opened it.
        model.dismissModal()
    }
}
