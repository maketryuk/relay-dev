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

            if model.showsStatusBar {
                StatusBar()
            }
        }
        // Relay draws its own title bar, so the safe area the window reserves
        // for the system one is dead space above it.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1_040, minHeight: 560)
        .animation(.easeOut(duration: 0.16), value: model.isRightSidebarVisible)
        .animation(.easeOut(duration: 0.16), value: model.isLeftSidebarVisible)
        .background(Theme.Palette.base)
        .overlay { usageOverlay }
        .overlay { modalOverlay }
        .overlay { commandPaletteOverlay }
        .overlay {
            ToastStack(toasts: model.toasts) { model.dismissToast($0) }
        }
        .tooltipRoot(tooltips)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func mainContent(for project: Project) -> some View {
        if let layout = model.paneLayout(for: project.id) {
            PaneTreeView(node: layout, projectID: project.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProjectOverviewPane(project: project)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var welcomePane: some View {
        VStack(spacing: Theme.Spacing.xlarge) {
            RelayMark(size: 72, tint: Theme.Palette.textSecondary)
            VStack(spacing: Theme.Spacing.xsmall) {
                Text(relayLocalized("No projects yet"))
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(relayLocalized("Add a local directory to start running agents, shells and dev servers in one place."))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            RelayButton(relayLocalized("Add Project"), systemImage: "plus", kind: .primary) {
                model.toggleModal(.addProject)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.base)
    }

    /// Sits above the status bar, anchored to the same corner it was opened
    /// from.
    ///
    /// Drawn here rather than as a `popover` because AppKit gives those a tail,
    /// and a tail pointing into a strip of numbers is decoration arguing with
    /// the thing it points at. Closing on a click anywhere else is what the
    /// invisible layer beneath it is for.
    @ViewBuilder
    private var usageOverlay: some View {
        @Bindable var model = model

        if model.isUsagePopoverOpen {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.isUsagePopoverOpen = false }

                UsagePopover()
                    .modalPlate()
                    .padding(.leading, Theme.Spacing.small)
                    .padding(.bottom, Theme.Metrics.statusBarHeight + Theme.Spacing.xsmall)
            }
            .background { KeyCaptureView(onEscape: { model.isUsagePopoverOpen = false }) }
            .transition(.opacity)
        }
    }

    /// The whole stack, not just the top: a panel opened from inside another
    /// stays visible behind it, so closing returns to where it came from.
    private var modalOverlay: some View {
        ForEach(model.modalStack) { modal in
            ModalHost(modal: modal)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var commandPaletteOverlay: some View {
        if model.isCommandPaletteOpen {
            CommandPaletteView()
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Drag handle between the session sidebar and the content.
struct SidebarResizeHandle: View {
    @Environment(AppModel.self) private var model
    @State private var startWidth: Double = 0

    var body: some View {
        ResizeHandle(orientation: .vertical) {
            startWidth = model.sidebarWidth
        } onDrag: { translation in
            model.sidebarWidth = ResizeMath.length(
                from: startWidth,
                translation: translation,
                limits: Theme.Metrics.sidebarMinWidth ... Theme.Metrics.sidebarMaxWidth
            )
        } onEnd: {
            model.persist()
        }
    }
}

/// Drag handle on the inner edge of the right-hand panel.
///
/// Dragging left widens it, which is why the translation is subtracted: the
/// handle is on the panel's leading edge, not its trailing one.
struct RightSidebarResizeHandle: View {
    @Environment(AppModel.self) private var model
    @State private var startWidth: Double = 0

    var body: some View {
        ResizeHandle(orientation: .vertical) {
            startWidth = model.rightSidebarWidth
        } onDrag: { translation in
            model.rightSidebarWidth = ResizeMath.length(
                from: startWidth,
                translation: -translation,
                limits: Theme.Metrics.rightSidebarMinWidth ... Theme.Metrics.rightSidebarMaxWidth
            )
        } onEnd: {
            model.persist()
        }
    }
}

/// Shown when a project is selected but no session is open.
struct ProjectOverviewPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    /// Whatever the user keeps in their presets, in their order, wrapped so a
    /// long list stays readable instead of running off the pane.
    private var presetRows: [[SessionPreset]] {
        stride(from: 0, to: model.presets.count, by: Self.presetsPerRow).map { start in
            Array(model.presets[start ..< min(start + Self.presetsPerRow, model.presets.count)])
        }
    }

    private static let presetsPerRow = 4

    /// Exactly one preset is the prominent one; a wall of accent-filled buttons
    /// would make none of them the obvious start.
    ///
    /// Which one is the project's own answer: the first preset for its default
    /// agent, falling back to the first preset of all when the project has none
    /// for that agent. That setting had been written down and never read, which
    /// is a control that pretends.
    private var prominentPreset: SessionPreset? {
        model.presets.first { $0.kind == project.defaultAgent } ?? model.presets.first
    }

    private func isLeading(_ preset: SessionPreset) -> Bool {
        preset.id == prominentPreset?.id
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xlarge) {
            VStack(spacing: Theme.Spacing.small) {
                ProjectIcon(
                    initials: ProjectAppearance.initials(for: project.name),
                    tint: ProjectAppearance.tint(for: project.rootPath),
                    status: model.aggregatedStatus(for: project.id),
                    isSelected: true,
                    size: 56,
                    artwork: model.projectIcons[project.id]
                )
                Text(project.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(project.displayPath)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            // The same presets the sidebar's + offers, because there is no
            // second answer to "how do I start something here".
            VStack(spacing: Theme.Spacing.small) {
                ForEach(Array(presetRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Theme.Spacing.small) {
                        ForEach(row) { preset in
                            let isPrimary = isLeading(preset)
                            RelayButton(preset.name, kind: isPrimary ? .primary : .secondary) {
                                SessionGlyph(
                                    kind: preset.kind,
                                    size: 12,
                                    // On the filled button the mark sits on the
                                    // accent, where its own colour disappears.
                                    tint: isPrimary ? .white : Color(hex: preset.kind.accentHex)
                                )
                            } action: {
                                model.createSession(from: preset, in: project.id)
                            }
                            .relayTooltip(preset.subtitle)
                        }
                    }
                }
            }

            if let git = model.gitStatuses[project.id] {
                HStack(spacing: Theme.Spacing.small) {
                    Badge(git.branch, systemImage: "arrow.triangle.branch", tint: Theme.Palette.textSecondary)
                    if git.isDirty {
                        Badge(
                            String(format: relayLocalized("%d changed"), git.changedFiles),
                            tint: Theme.Palette.statusWaiting
                        )
                    }
                    if git.ahead > 0 { Badge("↑\(git.ahead)", tint: Theme.Palette.statusFinished) }
                    if git.behind > 0 { Badge("↓\(git.behind)", tint: Theme.Palette.statusWorking) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.base)
    }
}
