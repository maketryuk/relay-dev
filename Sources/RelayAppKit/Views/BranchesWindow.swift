import RelayProtocol
import RelayUI
import SwiftUI

/// Every branch of the selected project, and the way to another one.
///
/// A window rather than a menu hanging off the branch name: switching branches
/// is something you also want to reach by typing, and the command palette can
/// only open a window.
struct BranchesPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var query = ""
    @State private var focus = ListFocus()

    private var all: [GitBranch] { model.branches(in: project.id) }

    private var local: [GitBranch] { matching.filter { !$0.isRemote } }
    private var remote: [GitBranch] { matching.filter(\.isRemote) }
    private var ordered: [GitBranch] { local + remote }

    private var matching: [GitBranch] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// A name nobody is using is a branch waiting to be started.
    private var newBranchName: String? {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !all.contains(where: { $0.switchName == name || $0.name == name })
        else { return nil }
        return name
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()
            content
        }
        .keyboardNavigableList(rowCount: ordered.count, actionCount: 1, focus: $focus) {
            guard ordered.indices.contains(focus.row) else { return }
            switchTo(ordered[focus.row])
        }
        .refreshingWhileVisible(id: project.id, every: .seconds(10)) {
            model.refreshBranches(for: project.id)
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(verbatim: model.gitStatuses[project.id]?.branch ?? project.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(String(format: relayLocalized("%d branches"), all.count))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .monospacedDigit()
                Spacer()
                IconButton(
                    systemImage: "arrow.clockwise",
                    help: "",
                    size: 24,
                    isBusy: model.isLoadingBranches(project.id)
                ) {
                    model.refreshBranches(for: project.id)
                }
                .relayTooltip(relayLocalized("Re-read branches"))
            }
            RelayTextField(
                relayLocalized("Search branches"),
                text: $query,
                systemImage: "magnifyingglass"
            ) {
                if let name = newBranchName {
                    model.switchBranch(to: name, creating: true, in: project.id)
                    model.dismissModal()
                } else if let first = ordered.first {
                    switchTo(first)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.bottom, Theme.Spacing.medium)
    }

    @ViewBuilder
    private var content: some View {
        if all.isEmpty, model.isLoadingBranches(project.id) {
            EmptyStateView(
                systemImage: "arrow.triangle.branch",
                title: relayLocalized("Reading…"),
                message: ""
            )
        } else if ordered.isEmpty, newBranchName == nil {
            EmptyStateView(
                systemImage: "arrow.triangle.branch",
                title: relayLocalized("No match"),
                message: String(format: relayLocalized("No branch matches “%@”."), query)
            )
        } else {
            KeyboardScrollingList(
                focusedRow: focus.row,
                identifyingRow: { ordered.indices.contains($0) ? ordered[$0].id : nil }
            ) {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    if let name = newBranchName {
                        row(
                            title: String(format: relayLocalized("Create branch “%@”"), name),
                            symbol: "plus",
                            subtitle: relayLocalized("Starts from where you are now"),
                            isCurrent: false,
                            isFocused: false
                        ) {
                            model.switchBranch(to: name, creating: true, in: project.id)
                            model.dismissModal()
                        }
                    }

                    section(relayLocalized("Local"), local, offset: 0)
                    section(relayLocalized("Remote"), remote, offset: local.count)
                }
                .padding(Theme.Spacing.small)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [GitBranch], offset: Int) -> some View {
        if !list.isEmpty {
            Section {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, branch in
                    row(
                        title: branch.name,
                        symbol: branch.isRemote ? "cloud" : "arrow.triangle.branch",
                        subtitle: branch.isRemote
                            ? relayLocalized("Checks out a local branch that follows it")
                            : (branch.upstream ?? relayLocalized("No upstream")),
                        isCurrent: branch.isCurrent,
                        isFocused: focus.row == offset + index
                    ) {
                        switchTo(branch)
                    }
                }
            } header: {
                SectionHeader(title)
                    .padding(.horizontal, Theme.Spacing.small)
                    .background(Theme.Palette.base)
            }
        }
    }

    private func row(
        title: String,
        symbol: String,
        subtitle: String,
        isCurrent: Bool,
        isFocused: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SidebarRow(
            title: title,
            subtitle: subtitle,
            systemImage: symbol,
            isSelected: isCurrent || isFocused,
            action: action,
            accessoryVisibility: .always
        ) {
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
    }

    private func switchTo(_ branch: GitBranch) {
        guard !branch.isCurrent else { return model.dismissModal() }
        model.switchBranch(to: branch.switchName, in: project.id)
        model.dismissModal()
    }
}
