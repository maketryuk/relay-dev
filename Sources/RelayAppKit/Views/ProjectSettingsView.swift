import RelayProtocol
import RelayUI
import SwiftUI

struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var name = ""
    @State private var defaultAgent: SessionKind = .claude
    @State private var devCommand = ""
    @State private var editor = ""
    @State private var notificationsEnabled = true
    @State private var projectMuted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(relayLocalized("Project Settings"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                IconButton(systemImage: "xmark", help: "Close") { dismiss() }
            }
            .padding(Theme.Spacing.large)

            RelayDivider()

            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                field("Display name") {
                    RelayTextField(relayLocalized("Project name"), text: $name)
                }

                field("Root path") {
                    Text(project.rootPath)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                field("Default agent") {
                    Picker("", selection: $defaultAgent) {
                        ForEach(SessionKind.allCases.filter { $0 != .ssh && $0 != .shell }, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                field("Dev command") {
                    RelayTextField("npm run dev", text: $devCommand)
                }

                field("Preferred editor command") {
                    RelayTextField("code, cursor, zed…", text: $editor)
                }

                field("Notifications") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Toggle(isOn: $notificationsEnabled) {
                            Text(relayLocalized("Notify me about agents and services"))
                                .font(Theme.Typography.row)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Toggle(isOn: $projectMuted) {
                            Text(relayLocalized("Mute this project"))
                                .font(Theme.Typography.row)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .disabled(!notificationsEnabled)
                    }
                    .toggleStyle(.switch)
                }
            }
            .padding(Theme.Spacing.large)

            Spacer(minLength: 0)
            RelayDivider()

            HStack(spacing: Theme.Spacing.small) {
                RelayButton(relayLocalized("Remove Project"), kind: .destructive) {
                    model.removeProject(project.id)
                    dismiss()
                }
                Spacer()
                RelayButton(relayLocalized("Cancel"), kind: .ghost) { dismiss() }
                RelayButton(relayLocalized("Save"), kind: .primary) {
                    var updated = project
                    updated.name = name.trimmingCharacters(in: .whitespaces).isEmpty
                        ? project.name
                        : name.trimmingCharacters(in: .whitespaces)
                    updated.defaultAgent = defaultAgent
                    updated.defaultServiceCommand = devCommand.isEmpty ? nil : devCommand
                    updated.preferredEditor = editor.isEmpty ? nil : editor
                    model.updateProject(updated)

                    var settings = model.notificationSettings
                    settings.isEnabled = notificationsEnabled
                    if settings.isMuted(project.id) != projectMuted {
                        settings.toggleMute(project.id)
                    }
                    model.updateNotificationSettings(settings)
                    dismiss()
                }
            }
            .padding(Theme.Spacing.large)
        }
        .frame(width: 480, height: 520)
        .background(Theme.Palette.surface)
        .onAppear {
            name = project.name
            defaultAgent = project.defaultAgent
            devCommand = project.defaultServiceCommand ?? ""
            editor = project.preferredEditor ?? ""
            notificationsEnabled = model.notificationSettings.isEnabled
            projectMuted = model.notificationSettings.isMuted(project.id)
        }
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
