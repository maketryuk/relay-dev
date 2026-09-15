import RelayProtocol
import RelayUI
import SwiftUI

/// Creates or edits a session preset.
struct PresetEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let preset: SessionPreset?

    @State private var name = ""
    @State private var kind: SessionKind = .claude
    @State private var argumentText = ""
    @State private var customCommand = ""
    @State private var usesCustomCommand = false

    private var isEditing: Bool { preset != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RelayDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    if !isEditing {
                        templates
                    }
                    fields
                }
                .padding(Theme.Spacing.large)
            }

            RelayDivider()
            footer
        }
        .frame(width: 520, height: 520)
        .background(Theme.Palette.surface)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack {
            Text(isEditing ? relayLocalized("Edit Preset") : relayLocalized("New Preset"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            IconButton(systemImage: "xmark", help: relayLocalized("Close")) { dismiss() }
        }
        .padding(Theme.Spacing.large)
    }

    /// Starting points, so the common presets need no typing and nobody has to
    /// remember which flag each CLI uses for automatic approvals.
    private var templates: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(relayLocalized("Start from"))
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.small)],
                      spacing: Theme.Spacing.small) {
                ForEach(SessionPresets.templates) { template in
                    Button {
                        apply(template)
                    } label: {
                        HStack(spacing: Theme.Spacing.small) {
                            SessionGlyph(
                                kind: template.kind,
                                size: 12,
                                tint: Color(hex: template.kind.accentHex)
                            )
                            .frame(width: 16)
                            Text(template.name)
                                .font(Theme.Typography.rowSecondary)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, 6)
                        .background(Theme.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            field(relayLocalized("Name")) {
                RelayTextField(relayLocalized("Claude"), text: $name)
            }

            field(relayLocalized("Agent")) {
                Picker("", selection: $kind) {
                    ForEach(SessionKind.allCases.filter { $0 != .ssh }, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200)
            }

            Toggle(isOn: $usesCustomCommand) {
                Text(relayLocalized("Run my own command"))
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .toggleStyle(.switch)

            if usesCustomCommand {
                field(relayLocalized("Command")) {
                    VStack(alignment: .leading, spacing: 4) {
                        RelayTextField("pnpm storybook", text: $customCommand)
                        Text(relayLocalized("Runs through your shell in the project root."))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            } else {
                field(relayLocalized("Arguments")) {
                    VStack(alignment: .leading, spacing: 4) {
                        RelayTextField("--permission-mode auto", text: $argumentText)
                        Text(preview)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var preview: String {
        var draft = SessionPreset(name: name, kind: kind)
        draft.argumentText = argumentText
        return draft.subtitle
    }

    private var footer: some View {
        HStack {
            Spacer()
            RelayButton(relayLocalized("Cancel"), kind: .ghost) { dismiss() }
            RelayButton(isEditing ? relayLocalized("Save") : relayLocalized("Add"), kind: .primary, action: save)
        }
        .padding(Theme.Spacing.large)
    }

    private func load() {
        guard let preset else {
            apply(SessionPresets.templates[0])
            return
        }
        name = preset.name
        kind = preset.kind
        argumentText = preset.argumentText
        customCommand = preset.customCommand ?? ""
        usesCustomCommand = preset.customCommand?.isEmpty == false || preset.kind == .custom
    }

    private func apply(_ template: SessionPreset) {
        name = template.name
        kind = template.kind
        argumentText = template.argumentText
        customCommand = template.customCommand ?? ""
        usesCustomCommand = template.customCommand != nil
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        var updated = preset ?? SessionPreset(name: trimmedName, kind: kind)
        updated.name = trimmedName
        updated.kind = kind
        if usesCustomCommand {
            let command = customCommand.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return }
            updated.customCommand = command
            updated.arguments = []
        } else {
            updated.customCommand = nil
            updated.argumentText = argumentText
        }

        if isEditing {
            model.updatePreset(updated)
        } else {
            model.addPreset(updated)
        }
        dismiss()
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(label.uppercased())
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)
            content()
        }
    }
}
