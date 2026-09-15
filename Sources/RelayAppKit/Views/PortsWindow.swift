import RelayProtocol
import RelayUI
import SwiftUI

enum PortsWindow {
    static let id = "relay.ports"
}

/// Standalone window listing every TCP port the machine is listening on.
///
/// It is deliberately not scoped to the selected project: the question this
/// answers is "what is on 3000", and the answer is just as often a server
/// started in another terminal, a container, or an app that is not Relay's
/// business at all. Ports Relay owns are marked and can be acted on; the rest
/// are reported and left alone.
struct PortsWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()
            content
        }
        .frame(minWidth: 460, minHeight: 320)
        .background(Theme.Palette.base)
        .preferredColorScheme(.dark)
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
                Text(relayLocalized("Ports"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(verbatim: "\(model.ports.count) \(relayLocalized("listening"))")
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                WindowDragArea()
                    .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
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
        .padding(.top, Theme.Spacing.large + Theme.Spacing.small)
        .padding(.bottom, Theme.Spacing.medium)
        .background(Theme.Palette.base)
    }

    @ViewBuilder
    private var content: some View {
        let groups = model.groupedPorts(for: model.selectedProjectID, matching: query)

        if groups.project.isEmpty, groups.other.isEmpty {
            EmptyStateView(
                systemImage: "point.3.filled.connected.trianglepath.dotted",
                title: query.isEmpty ? "Nothing is listening" : "No match",
                message: query.isEmpty
                    ? "No process on this Mac is accepting TCP connections right now."
                    : "No port matches “\(query)”."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    if !groups.project.isEmpty {
                        Section {
                            ForEach(groups.project) { PortRow(port: $0) }
                        } header: {
                            sectionHeader(model.selectedProject?.name ?? "This project")
                        }
                    }
                    if !groups.other.isEmpty {
                        Section {
                            ForEach(groups.other) { PortRow(port: $0) }
                        } header: {
                            sectionHeader("Elsewhere on this Mac")
                        }
                    }
                }
                .padding(Theme.Spacing.small)
            }
        }
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

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(String(port.port))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(port.isManagedByRelay ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    Text(model.ownerLabel(for: port) ?? port.processName)
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    if port.isManagedByRelay {
                        Badge("Relay", tint: Theme.Palette.statusWorking)
                    }
                }
                Text("\(port.processName) · pid \(port.pid) · \(port.address)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.small)

            if port.url != nil {
                IconButton(systemImage: "arrow.up.forward.app", help: "") { model.openPort(port) }
                    .relayTooltip(relayLocalized("Open in browser"))
                IconButton(systemImage: "doc.on.doc", help: "") { model.copyPortURL(port) }
                    .relayTooltip(relayLocalized("Copy URL"))
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 6)
        .background(isHovering ? Theme.Palette.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
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
