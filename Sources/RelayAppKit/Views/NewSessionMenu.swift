import RelayProtocol
import RelayUI
import SwiftUI

/// The list behind the sessions "+" button.
///
/// A plain `Menu` was not enough: presets differ mainly by the arguments they
/// pass, so the row has to show the command as well as the name, and each agent
/// needs its own mark to be picked out at a glance.
struct NewSessionMenu: View {
    @Environment(AppModel.self) private var model
    let projectID: ProjectID
    let onDismiss: () -> Void

    @State private var isAddingCustom = false
    @State private var customName = ""
    @State private var customCommand = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isAddingCustom {
                customEditor
            } else {
                presetList
            }
        }
        .frame(width: 300)
        .background(Theme.Palette.surface)
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(relayLocalized("NEW SESSION"))
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.top, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.small)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.sessionPresets) { preset in
                        row(preset)
                    }
                    BrowserEntryRow(shortcut: model.binding(for: .newBrowserTab)?.displayString) {
                        model.newBrowserTab(in: projectID)
                        onDismiss()
                    }
                }
                .padding(.horizontal, Theme.Spacing.xsmall)
            }
            .frame(maxHeight: 320)

            RelayDivider()

            Button {
                customName = ""
                customCommand = ""
                isAddingCustom = true
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .frame(width: 18)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(relayLocalized("Custom command…"))
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()

            // Beside the sessions rather than in a menu of its own: starting a
            // piece of work on a branch of its own is starting a session, one
            // step earlier.
            if model.gitRepositories.contains(projectID) {
                Button {
                    onDismiss()
                    model.beginNewWorktree(in: projectID)
                } label: {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 12))
                            .frame(width: 18)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(relayLocalized("New worktree…"))
                            .font(Theme.Typography.row)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.small)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
            }
        }
    }

    private func row(_ preset: SessionPreset) -> some View {
        PresetRow(preset: preset) {
            model.createSession(from: preset, in: projectID)
            onDismiss()
        } onDelete: {
            model.removePreset(preset)
        }
    }

    private var customEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(relayLocalized("CUSTOM COMMAND"))
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)

            RelayTextField(relayLocalized("Name"), text: $customName)
            RelayTextField("npm run something", text: $customCommand)

            Text(relayLocalized("Saved as a preset and run through your shell in the project root."))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                RelayButton(relayLocalized("Back"), kind: .ghost) { isAddingCustom = false }
                Spacer()
                RelayButton(relayLocalized("Run"), kind: .primary) { saveAndRun() }
            }
        }
        .padding(Theme.Spacing.medium)
    }

    private func saveAndRun() {
        let command = customCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        let name = customName.trimmingCharacters(in: .whitespaces)

        let preset = SessionPreset(
            name: name.isEmpty ? command : name,
            kind: .custom,
            customCommand: command
        )
        model.addPreset(preset)
        model.createSession(from: preset, in: projectID)
        onDismiss()
    }
}

/// A browser tab, offered where sessions are started: it is opened for the
/// same reason one is, to watch the work, and it sits in the same list.
private struct BrowserEntryRow: View {
    let shortcut: String?
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(relayLocalized("Browser"))
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(relayLocalized("A Chromium tab, with design mode"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.xsmall)

            if let shortcut {
                Text(verbatim: shortcut)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 6)
        .background(isHovering ? Theme.Palette.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .clickable()
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onOpen)
    }
}

private struct PresetRow: View {
    let preset: SessionPreset
    let onRun: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            SessionGlyph(
                kind: preset.kind,
                size: 12,
                tint: Color(hex: preset.kind.accentHex)
            )
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(preset.localizedName)
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(preset.subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Theme.Spacing.xsmall)

            HoverReveal(isVisible: isHovering && !preset.isProtected) {
                IconButton(systemImage: "trash", help: relayLocalized("Remove preset"), size: 16, action: onDelete)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 6)
        .background(isHovering ? Theme.Palette.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .clickable()
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onRun)
    }
}
