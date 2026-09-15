import RelayProtocol
import RelayUI
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// Tooltips are drawn by one layer at the window root so they can overlap
    /// the panes they belong to instead of being painted over by them.
    @State private var tooltips = TooltipPresenter()

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            TitleBar()

            HStack(spacing: 0) {
                ProjectRailView()

                if let project = model.selectedProject {
                    if model.isLeftSidebarVisible {
                        ProjectSidebarView(project: project)
                        SidebarResizeHandle()
                    }
                    mainContent(for: project)
                    if model.isRightSidebarVisible {
                        RightSidebarView(project: project)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                } else {
                    welcomePane
                }
            }
        }
        .frame(minWidth: 1_040, minHeight: 560)
        .animation(.easeOut(duration: 0.16), value: model.isRightSidebarVisible)
        .animation(.easeOut(duration: 0.16), value: model.isLeftSidebarVisible)
        .background(Theme.Palette.base)
        .overlay { commandPaletteOverlay }
        .overlay {
            ToastStack(toasts: model.toasts) { model.dismissToast($0) }
        }
        .sheet(isPresented: $model.isProjectSettingsOpen) {
            if let project = model.selectedProject {
                ProjectSettingsView(project: project)
            }
        }
        .tooltipRoot(tooltips)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func mainContent(for project: Project) -> some View {
        if let sessionID = model.selectedSessionID, let session = model.sessions[sessionID] {
            TerminalPane(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProjectOverviewPane(project: project)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var welcomePane: some View {
        VStack(spacing: Theme.Spacing.large) {
            EmptyStateView(
                systemImage: "square.stack.3d.up",
                title: "No projects yet",
                message: "Add a local directory to start running agents, shells and dev servers in one place."
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.base)
    }

    @ViewBuilder
    private var commandPaletteOverlay: some View {
        if model.isCommandPaletteOpen {
            CommandPaletteView()
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Drag handle between sidebar and content.
struct SidebarResizeHandle: View {
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Theme.Palette.accent.opacity(0.5) : Color.clear)
            .frame(width: 3)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let proposed = model.sidebarWidth + value.translation.width
                        model.sidebarWidth = min(
                            max(proposed, Theme.Metrics.sidebarMinWidth),
                            Theme.Metrics.sidebarMaxWidth
                        )
                    }
                    .onEnded { _ in model.persist() }
            )
    }
}

/// Shown when a project is selected but no session is open.
struct ProjectOverviewPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    private var startPresets: [SessionPreset] {
        [.claude, .codex, .shell].map {
            SessionPresets.preferred(for: $0, custom: model.customPresets)
        }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xlarge) {
            VStack(spacing: Theme.Spacing.small) {
                ProjectIcon(
                    initials: ProjectAppearance.initials(for: project.name),
                    tint: ProjectAppearance.tint(for: project.rootPath),
                    status: model.aggregatedStatus(for: project.id),
                    isSelected: true,
                    size: 56
                )
                Text(project.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(project.displayPath)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            // The empty-project view has room for the three starts people
            // actually reach for; everything else lives behind the sidebar's +.
            HStack(spacing: Theme.Spacing.small) {
                ForEach(startPresets) { preset in
                    RelayButton(
                        preset.name,
                        systemImage: preset.kind.symbolName,
                        kind: preset.kind == .claude ? .primary : .secondary
                    ) {
                        model.createSession(from: preset, in: project.id)
                    }
                }
            }

            if let git = model.gitStatuses[project.id] {
                HStack(spacing: Theme.Spacing.small) {
                    Badge(git.branch, tint: Theme.Palette.textSecondary)
                    if git.isDirty { Badge("\(git.changedFiles) changed", tint: Theme.Palette.statusWaiting) }
                    if git.ahead > 0 { Badge("↑\(git.ahead)", tint: Theme.Palette.statusFinished) }
                    if git.behind > 0 { Badge("↓\(git.behind)", tint: Theme.Palette.statusWorking) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.base)
    }
}
