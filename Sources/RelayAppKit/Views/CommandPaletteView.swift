import AppKit
import RelayProtocol
import RelayUI
import SwiftUI

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let run: () -> Void
}

/// Keyboard-first entry point to everything. Deliberately free of any AI or
/// network dependency: it is a command index, not a search box.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var highlightedIndex = 0
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            Panel {
                VStack(spacing: 0) {
                    field
                    RelayDivider()
                    results
                }
            }
            .frame(width: 560)
            .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
            .padding(.top, 96)
        }
        .onAppear {
            isFieldFocused = true
            highlightedIndex = 0
        }
    }

    private var field: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField("Run a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($isFieldFocused)
                .onSubmit(runHighlighted)
                .onChange(of: query) { _, _ in highlightedIndex = 0 }
            Text("esc")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private var results: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                    row(command, isHighlighted: index == highlightedIndex)
                        .onTapGesture {
                            command.run()
                            close()
                        }
                }
                if filteredCommands.isEmpty {
                    Text(relayLocalized("No matching commands"))
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(Theme.Spacing.large)
                }
            }
            .padding(Theme.Spacing.xsmall)
        }
        .frame(maxHeight: 340)
        .background(
            // Arrow-key navigation without stealing focus from the text field.
            KeyCaptureView(
                onMoveDown: { highlightedIndex = min(highlightedIndex + 1, max(filteredCommands.count - 1, 0)) },
                onMoveUp: { highlightedIndex = max(highlightedIndex - 1, 0) },
                onEscape: close
            )
        )
    }

    private func row(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: command.systemImage)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(isHighlighted ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if !command.subtitle.isEmpty {
                    Text(command.subtitle)
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, 7)
        .background(isHighlighted ? Theme.Palette.surfaceActive : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: - Commands

    private var filteredCommands: [PaletteCommand] {
        let all = allCommands
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(trimmed) || $0.subtitle.lowercased().contains(trimmed)
        }
    }

    private var allCommands: [PaletteCommand] {
        var commands: [PaletteCommand] = []

        if let project = model.selectedProject {
            for preset in model.sessionPresets {
                commands.append(PaletteCommand(
                    id: "new-\(preset.id)",
                    title: "New \(preset.name) Session",
                    subtitle: preset.subtitle,
                    systemImage: preset.kind.symbolName
                ) {
                    model.createSession(from: preset, in: project.id)
                })
            }
            commands.append(PaletteCommand(
                id: "reveal",
                title: relayLocalized("Open Project in Finder"),
                subtitle: project.displayPath,
                systemImage: "folder"
            ) { model.revealInFinder(project) })
            commands.append(PaletteCommand(
                id: "editor",
                title: relayLocalized("Open Project in Editor"),
                subtitle: project.displayPath,
                systemImage: "chevron.left.forwardslash.chevron.right"
            ) { model.openInEditor(project) })
            commands.append(PaletteCommand(
                id: "settings",
                title: relayLocalized("Project Settings"),
                subtitle: project.name,
                systemImage: "gearshape"
            ) { model.isProjectSettingsOpen = true })
            commands.append(PaletteCommand(
                id: "ports-window",
                title: relayLocalized("Ports"),
                subtitle: relayLocalized("Everything listening on this Mac"),
                systemImage: "point.3.filled.connected.trianglepath.dotted"
            ) { model.activeModal = .ports })
            commands.append(PaletteCommand(
                id: "app-settings",
                title: relayLocalized("Settings"),
                subtitle: relayLocalized("Shortcuts, notifications and more"),
                systemImage: "slider.horizontal.3"
            ) { model.activeModal = .settings })

            for service in project.services {
                let state = model.state(of: service, in: project.id)
                if state.isActive {
                    commands.append(PaletteCommand(
                        id: "stop-\(service.id)",
                        title: "Stop \(service.name)",
                        subtitle: service.command,
                        systemImage: "stop.fill"
                    ) { model.stopService(service, in: project.id) })
                    commands.append(PaletteCommand(
                        id: "restart-\(service.id)",
                        title: "Restart \(service.name)",
                        subtitle: service.command,
                        systemImage: "arrow.clockwise"
                    ) { model.restartService(service, in: project.id) })
                } else {
                    commands.append(PaletteCommand(
                        id: "start-\(service.id)",
                        title: "Start \(service.name)",
                        subtitle: service.command,
                        systemImage: "play.fill"
                    ) { model.startService(service, in: project.id) })
                }
                if model.url(of: service, in: project.id) != nil {
                    commands.append(PaletteCommand(
                        id: "open-\(service.id)",
                        title: "Open \(service.name) URL",
                        subtitle: model.url(of: service, in: project.id)?.absoluteString ?? "",
                        systemImage: "arrow.up.forward.app"
                    ) { model.openService(service, in: project.id) })
                }
            }

            for port in model.ports where port.url != nil {
                commands.append(PaletteCommand(
                    id: "port-\(port.id)",
                    title: "Open port \(port.port)",
                    subtitle: port.ownerName ?? port.processName,
                    systemImage: "point.3.filled.connected.trianglepath.dotted"
                ) { model.openPort(port) })
            }
        }

        if let project = model.selectedProject {
            let hosts = model.sshHosts(for: project.id)
            for host in hosts.pinned + hosts.others {
                commands.append(PaletteCommand(
                    id: "ssh-\(host.alias)",
                    title: "Connect SSH: \(host.alias)",
                    subtitle: host.displayTarget,
                    systemImage: "network"
                ) { model.connectSSH(host, in: project.id) })
            }
        }

        for project in model.projects {
            commands.append(PaletteCommand(
                id: "switch-\(project.id.rawValue)",
                title: "Switch to \(project.name)",
                subtitle: project.displayPath,
                systemImage: "square.stack.3d.up"
            ) { model.selectProject(project.id) })
        }

        if let projectID = model.selectedProjectID {
            for session in model.sessions(in: projectID) {
                commands.append(PaletteCommand(
                    id: "focus-\(session.id.rawValue)",
                    title: "Focus \(session.displayName)",
                    subtitle: session.status.displayName,
                    systemImage: session.kind.symbolName
                ) { model.selectSession(session.id) })
            }
        }

        return commands
    }

    private func runHighlighted() {
        guard filteredCommands.indices.contains(highlightedIndex) else { return }
        filteredCommands[highlightedIndex].run()
        close()
    }

    private func close() {
        model.isCommandPaletteOpen = false
        query = ""
    }
}

/// Minimal AppKit bridge for arrow/escape handling, which SwiftUI does not
/// expose while a `TextField` holds focus.
struct KeyCaptureView: NSViewRepresentable {
    /// Optional, because a panel that only needs Escape must leave the arrow
    /// keys to whatever list is inside it.
    var onMoveDown: (() -> Void)?
    var onMoveUp: (() -> Void)?
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onMoveDown = onMoveDown
        view.onMoveUp = onMoveUp
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.onMoveDown = onMoveDown
        view.onMoveUp = onMoveUp
        view.onEscape = onEscape
    }

    final class MonitorView: NSView {
        var onMoveDown: (() -> Void)?
        var onMoveUp: (() -> Void)?
        var onEscape: (() -> Void)?
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 125:
                    guard let handler = self.onMoveDown else { return event }
                    handler()
                    return nil
                case 126:
                    guard let handler = self.onMoveUp else { return event }
                    handler()
                    return nil
                case 53:
                    self.onEscape?()
                    return nil
                default:
                    return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
