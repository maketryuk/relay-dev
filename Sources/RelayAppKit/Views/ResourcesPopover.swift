import RelayProtocol
import RelayUI
import SwiftUI

/// What the CPU and memory figures in the status bar open: every session
/// under its project, what each is costing, and a way to end it.
struct ResourcesPopover: View {
    @Environment(AppModel.self) private var model

    @State private var order: ResourceOrder = .memory
    /// The rows as they were when the pointer came over the list, which they
    /// are held to until it leaves. See `ResourceGroup.arranged`.
    @State private var frozen: [ResourceGroup]?
    /// What a cross was pressed on, while the question is being asked.
    @State private var pending: ResourceClosing?
    @State private var listHeight: CGFloat = 0

    /// Beyond this the list scrolls. Short of it the list is as tall as its
    /// rows: a fixed height left two sessions floating in the middle of an
    /// empty panel.
    private static let maxListHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RelayDivider()
            if groups.isEmpty {
                Text(relayLocalized("No sessions"))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(Theme.Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                columnHeadings
                list
            }
            RelayDivider()
            relayRow
            RelayDivider()
            footer
        }
        .frame(width: 380)
        .background(Theme.Palette.base)
        .onAppear { model.resources.setWatched(true) }
        .onDisappear { model.resources.setWatched(false) }
        .confirmationDialog(
            pending.map { question($0) } ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { closing in
            Button(answer(to: closing), role: .destructive) {
                model.end(closing)
                pending = nil
            }
            Button(relayLocalized("Cancel"), role: .cancel) { pending = nil }
        } message: { closing in
            Text(consequences(of: closing))
        }
    }

    private var groups: [ResourceGroup] {
        let fresh = order.grouped(model.resourceSessions, usage: model.resources.sessions)
        guard let frozen else { return fresh }
        return ResourceGroup.arranged(fresh, like: frozen)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(relayLocalized("Resources"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: Theme.Spacing.small)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small + 2)
    }

    private var columnHeadings: some View {
        HStack(spacing: Theme.Spacing.small) {
            Spacer(minLength: 0)
            SortHeading(title: relayLocalized("CPU"), isActive: order == .cpu) { order = .cpu }
                .frame(width: ResourceColumns.cpu, alignment: .trailing)
            SortHeading(title: relayLocalized("MEMORY"), isActive: order == .memory) { order = .memory }
                .frame(width: ResourceColumns.memory, alignment: .trailing)
            Color.clear.frame(width: ResourceColumns.action, height: 1)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.small)
        .padding(.bottom, Theme.Spacing.xsmall)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(groups) { group in
                    let isCollapsed = model.collapsedResourceProjects.contains(group.projectID)
                    ResourceProjectRow(
                        group: group,
                        isCollapsed: isCollapsed,
                        onToggle: { model.toggleResourceProject(group.projectID) },
                        onClose: { pending = .project(group.projectID) }
                    )
                    if !isCollapsed {
                        ForEach(group.sessions) { session in
                            ResourceSessionRow(
                                session: session,
                                usage: model.resources.sessions[session.id],
                                onReveal: {
                                    model.isResourcesPopoverOpen = false
                                    model.revealSession(session.id)
                                },
                                onEnd: { pending = .session(session.id) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xsmall)
            .padding(.bottom, Theme.Spacing.xsmall)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ResourceListHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .frame(height: min(max(listHeight, 1), Self.maxListHeight))
        .onPreferenceChange(ResourceListHeightKey.self) { listHeight = $0 }
        .onHover { inside in
            frozen = inside ? groups : nil
        }
    }

    /// Lined up on the name rather than centred: the line under it wraps, and
    /// figures floating halfway down two lines of explanation read as
    /// belonging to neither.
    private var relayRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            RelayMark(size: 12, tint: Theme.Palette.textSecondary)
                .frame(width: ResourceColumns.chevron + Theme.Spacing.small + ResourceColumns.glyph)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Relay")
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(relayLocalized("The window, browser tabs, the session daemon and linters"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.small)
            ResourceFigures(usage: model.resources.relay)
            Color.clear.frame(width: ResourceColumns.action, height: 1)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            // Said here because a compose session reads a few megabytes while
            // its database uses two gigabytes somewhere else, and a figure
            // that leaves that out without saying so is a figure that lies.
            Text(relayLocalized("Docker containers are not counted: they run in Docker's own virtual machine."))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.small)
            let exited = model.exitedResourceSessions.count
            if exited > 0 {
                RelayButton(String(format: relayLocalized("Close Exited (%d)"), exited), kind: .ghost) {
                    pending = .exited
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
    }

    // MARK: - The question

    private func question(_ closing: ResourceClosing) -> String {
        switch closing {
        case let .session(id):
            guard let session = model.sessions[id] else { return "" }
            return session.role.isService
                ? String(format: relayLocalized("Stop %@?"), model.label(for: session))
                : String(format: relayLocalized("Close %@?"), model.label(for: session))
        case let .project(id):
            return String(format: relayLocalized("Close every session in %@?"), model.resourceProjectName(id))
        case .exited:
            return relayLocalized("Close finished sessions?")
        }
    }

    private func answer(to closing: ResourceClosing) -> String {
        switch closing {
        case let .session(id):
            model.sessions[id]?.role.isService == true ? relayLocalized("Stop") : relayLocalized("Close")
        case .project, .exited:
            relayLocalized("Close All")
        }
    }

    /// What will happen, counted, so that "close everything in this project"
    /// says whether a dev server goes with it.
    private func consequences(of closing: ResourceClosing) -> String {
        let plan = model.plan(for: closing)
        if case .session = closing {
            if !plan.stopping.isEmpty { return relayLocalized("It stays in Services, ready to start again.") }
            return plan.running > 0 ? relayLocalized("What is running in it will be stopped.") : ""
        }
        var lines: [String] = []
        if !plan.closing.isEmpty {
            lines.append(String(format: relayLocalized("Sessions to close: %d"), plan.closing.count))
        }
        if !plan.stopping.isEmpty {
            lines.append(String(format: relayLocalized("Services to stop: %d"), plan.stopping.count))
        }
        if plan.running > 0 {
            lines.append(relayLocalized("What is running in them will be stopped."))
        }
        return lines.joined(separator: "\n")
    }
}

private struct ResourceListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Widths shared by the headings and the rows beneath them, so the figures
/// line up in columns and a session's glyph sits under its project's name.
private enum ResourceColumns {
    static let chevron: CGFloat = 10
    static let glyph: CGFloat = 18
    static let cpu: CGFloat = 46
    static let memory: CGFloat = 62
    static let action: CGFloat = 20
}

/// A column heading that sorts the list by its column.
private struct SortHeading: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(isActive ? 1 : 0)
                Text(title)
                    .font(Theme.Typography.sectionHeader)
                    .tracking(0.7)
            }
            .foregroundStyle(isActive || isHovering ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { isHovering = $0 }
    }
}

/// A project: folds its sessions away on a click, and closes every one of
/// them from its cross.
private struct ResourceProjectRow: View {
    @Environment(AppModel.self) private var model

    let group: ResourceGroup
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: ResourceColumns.chevron)

            icon
                .frame(width: ResourceColumns.glyph)

            Text(model.resourceProjectName(group.projectID))
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            // Worth having folded: how much is behind the chevron.
            Text(verbatim: "\(group.sessions.count)")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .monospacedDigit()

            Spacer(minLength: Theme.Spacing.small)

            ResourceFigures(usage: group.usage)

            HoverReveal(isVisible: isHovering) {
                IconButton(systemImage: "xmark", help: "", size: 18, action: onClose)
                    .relayTooltip(relayLocalized("Close every session in this project"))
            }
            .frame(width: ResourceColumns.action)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 6)
        .background(isHovering ? Theme.Palette.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .clickable()
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onToggle)
    }

    @ViewBuilder
    private var icon: some View {
        if group.projectID == .chat {
            ProjectIcon(
                initials: "",
                tint: Theme.Palette.accent,
                status: .offline,
                isSelected: false,
                size: 16,
                symbolName: "bubble.left.and.text.bubble.right"
            )
        } else if let project = model.project(group.projectID) {
            ProjectIcon(
                initials: ProjectAppearance.initials(for: project.name),
                tint: ProjectAppearance.tint(for: project.rootPath),
                status: .offline,
                isSelected: false,
                size: 16,
                artwork: model.projectIcons[project.id]
            )
        }
    }
}

/// One session, under its project: what it is, what it costs, and the button
/// that ends it.
private struct ResourceSessionRow: View {
    @Environment(AppModel.self) private var model

    let session: SessionSnapshot
    let usage: ResourceUsage?
    let onReveal: () -> Void
    let onEnd: () -> Void

    @State private var isHovering = false

    private var hasExited: Bool { session.exitCode != nil }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            // Level with the project's name, so the list reads as a tree.
            Color.clear.frame(width: ResourceColumns.chevron, height: 1)

            SessionGlyph(kind: session.kind, size: 13, tint: Color(hex: session.kind.accentHex))
                .frame(width: ResourceColumns.glyph)
                .opacity(hasExited ? 0.5 : 1)

            Text(model.label(for: session))
                .font(Theme.Typography.row)
                .foregroundStyle(hasExited ? Theme.Palette.textTertiary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if let detail {
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Spacing.small)

            ResourceFigures(usage: usage)

            HoverReveal(isVisible: isHovering) {
                IconButton(systemImage: session.role.isService ? "stop.fill" : "xmark", help: "", size: 18, action: onEnd)
                    .relayTooltip(
                        session.role.isService
                            ? String(format: relayLocalized("Stop %@"), session.displayName)
                            : relayLocalized("Close session")
                    )
            }
            .frame(width: ResourceColumns.action)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 5)
        .background(isHovering ? Theme.Palette.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .clickable()
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onReveal)
    }

    /// The worktree when it is not the project's own, and how it ended when
    /// it has.
    private var detail: String? {
        var parts: [String] = []
        if let worktree = model.resourceWorktreeName(of: session) { parts.append(worktree) }
        if let code = session.exitCode {
            parts.append(code == 0
                ? relayLocalized("finished")
                : String(format: relayLocalized("exited with code %@"), "\(code)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The two figures, in their columns. Something busy on a whole core is
/// marked; below that the numbers speak for themselves.
private struct ResourceFigures: View {
    let usage: ResourceUsage?

    var body: some View {
        Text(verbatim: usage.map { ResourceFormatting.cpu($0.cpu) } ?? "")
            .font(Theme.Typography.rowSecondary.monospacedDigit())
            .foregroundStyle(isBusy ? Theme.Palette.statusWaiting : Theme.Palette.textSecondary)
            .frame(width: ResourceColumns.cpu, alignment: .trailing)
        Text(verbatim: usage.map { ResourceFormatting.memory($0.footprint) } ?? "")
            .font(Theme.Typography.rowSecondary.monospacedDigit())
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(width: ResourceColumns.memory, alignment: .trailing)
    }

    private var isBusy: Bool {
        (usage?.cpu ?? 0) >= 90
    }
}
