import RelayProtocol
import RelayUI
import SwiftUI

/// Every TCP port the machine is listening on.
///
/// Deliberately not scoped to the selected project: the question this answers is
/// "what is on 3000", and the answer is just as often a server started in
/// another terminal, a container, or an app that is not Relay's business at all.
/// Ports Relay owns are marked and can be acted on; the rest are reported and
/// left alone.
struct PortsPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var focus = ListFocus()

    /// The rows as the keyboard sees them: one list, in the order drawn.
    private var orderedPorts: [ListeningPort] {
        let groups = model.groupedPorts(for: model.selectedProjectID, matching: query)
        return groups.project + groups.other
    }

    private var focusedPort: ListeningPort? {
        orderedPorts.indices.contains(focus.row) ? orderedPorts[focus.row] : nil
    }

    /// What a row offers, in the order left and right walk them. The first is
    /// the one Return runs on a row you have only just arrived at.
    private func actions(for port: ListeningPort) -> [RowAction] {
        var actions: [RowAction] = []
        if port.url != nil {
            actions.append(RowAction(
                id: "open",
                systemImage: "arrow.up.forward.app",
                label: relayLocalized("Open in browser")
            ) { model.openPort(port) })
            actions.append(RowAction(
                id: "copy",
                systemImage: "doc.on.doc",
                label: relayLocalized("Copy URL")
            ) { model.copyPortURL(port) })
        }
        // Relay's own processes stop on the spot; anything else gets asked about
        // first, because killing a stranger's process on one keystroke is not a
        // thing an app should do.
        actions.append(RowAction(
            id: "stop",
            systemImage: "stop.circle",
            label: relayLocalized("Stop process"),
            tint: Theme.Palette.statusError
        ) {
            if port.isManagedByRelay {
                model.terminatePort(port)
            } else {
                model.portPendingTermination = port
            }
        })
        return actions
    }

    var body: some View {
        let focusedActions = focusedPort.map(actions) ?? []

        return VStack(spacing: 0) {
            header
            RelayDivider()
            content
        }
        .keyboardNavigableList(
            rowCount: orderedPorts.count,
            actionCount: focusedActions.count,
            focus: $focus
        ) {
            guard focusedActions.indices.contains(focus.action) else { return }
            focusedActions[focus.action].run()
        }
        .onAppear { model.refreshPorts() }
        .confirmationDialog(
            relayLocalized("Stop this process?"),
            isPresented: Binding(
                get: { model.portPendingTermination != nil },
                set: { if !$0 { model.portPendingTermination = nil } }
            ),
            presenting: model.portPendingTermination
        ) { port in
            Button(relayLocalized("Stop process"), role: .destructive) {
                model.terminatePort(port)
                model.portPendingTermination = nil
            }
            Button(relayLocalized("Force quit"), role: .destructive) {
                model.terminatePort(port, force: true)
                model.portPendingTermination = nil
            }
            Button(relayLocalized("Cancel"), role: .cancel) { model.portPendingTermination = nil }
        } message: { port in
            Text(verbatim: "\(port.processName) · pid \(String(port.pid)) · \(relayLocalized("Relay did not start this process"))")
        }
        // The window is usually opened to check something that just started, so
        // it refreshes itself while visible rather than waiting to be told.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                model.refreshPorts()
            }
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(verbatim: "\(model.ports.count) \(relayLocalized("listening"))")
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer(minLength: Theme.Spacing.small)
                IconButton(
                    systemImage: model.showsAllPorts ? "line.3.horizontal.decrease.circle.fill"
                                                     : "line.3.horizontal.decrease.circle",
                    help: "",
                    isSelected: !model.showsAllPorts
                ) {
                    model.showsAllPorts.toggle()
                }
                .relayTooltip(
                    model.showsAllPorts
                        ? relayLocalized("Showing every port")
                        : relayLocalized("Showing development ports only")
                )

                IconButton(systemImage: "arrow.clockwise", help: "") { model.refreshPorts() }
                    .relayTooltip(relayLocalized("Rescan now"))
            }
            RelayTextField(relayLocalized("Filter by port, process or session"), text: $query, systemImage: "magnifyingglass")
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.bottom, Theme.Spacing.medium)
    }

    @ViewBuilder
    private var content: some View {
        let groups = model.groupedPorts(for: model.selectedProjectID, matching: query)

        if groups.project.isEmpty, groups.other.isEmpty {
            EmptyStateView(
                systemImage: "point.3.filled.connected.trianglepath.dotted",
                title: relayLocalized(query.isEmpty ? "Nothing is listening" : "No match"),
                message: query.isEmpty
                    ? relayLocalized("No process on this Mac is accepting TCP connections right now.")
                    : String(format: relayLocalized("No port matches “%@”."), query)
            )
        } else {
            KeyboardScrollingList(
                focusedRow: focus.row,
                identifyingRow: { orderedPorts.indices.contains($0) ? orderedPorts[$0].id : nil }
            ) {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    if !groups.project.isEmpty {
                        Section {
                            ForEach(Array(groups.project.enumerated()), id: \.element.id) { index, port in
                                row(port, at: index)
                            }
                        } header: {
                            sectionHeader(model.selectedProject?.name ?? relayLocalized("This project"))
                        }
                    }
                    if !groups.other.isEmpty {
                        Section {
                            ForEach(Array(groups.other.enumerated()), id: \.element.id) { index, port in
                                row(port, at: groups.project.count + index)
                            }
                        } header: {
                            sectionHeader(relayLocalized("Elsewhere on this Mac"))
                        }
                    }
                }
                .padding(Theme.Spacing.small)
            }
        }
    }

    private func row(_ port: ListeningPort, at index: Int) -> some View {
        PortRow(
            port: port,
            actions: actions(for: port),
            focusedAction: index == focus.row ? focus.action : nil
        )
        .id(port.id)
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
}

struct PortRow: View {
    @Environment(AppModel.self) private var model
    let port: ListeningPort
    let actions: [RowAction]
    /// Which action the keyboard is on, or nil when it is on another row.
    let focusedAction: Int?

    @State private var isHovering = false

    private var isHighlighted: Bool { focusedAction != nil }

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(String(port.port))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(port.isManagedByRelay ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    Text(model.ownerLabel(for: port))
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    if port.isManagedByRelay {
                        Badge("Relay", tint: Theme.Palette.statusWorking)
                    }
                }
                Text(verbatim: model.detailLabel(for: port))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Spacing.small)

            HoverReveal(isVisible: isHovering || isHighlighted) {
                RowActionBar(actions: actions, focusedAction: focusedAction)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 6)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(isHighlighted ? Theme.Palette.borderStrong : .clear, lineWidth: 1)
        )
        .contextMenu {
            if port.url != nil {
                Button(relayLocalized("Open in Browser")) { model.openPort(port) }
                Button(relayLocalized("Copy URL")) { model.copyPortURL(port) }
            }
            if port.ownerSessionID != nil {
                Divider()
                Button(relayLocalized("Reveal Owner Session")) { model.revealPortOwner(port) }
            }
            Divider()
            Button(relayLocalized("Stop process")) {
                if port.isManagedByRelay {
                    model.terminatePort(port)
                } else {
                    model.portPendingTermination = port
                }
            }
            Button(relayLocalized("Force quit")) { model.portPendingTermination = port }
        }
    }
}

private extension PortRow {
    var rowBackground: Color {
        if isHighlighted { return Theme.Palette.surfaceActive }
        return isHovering ? Theme.Palette.surfaceHover : .clear
    }
}
