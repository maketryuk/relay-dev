import AppKit
import RelayProtocol
import RelayUI
import SwiftUI

struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model

    let project: Project

    @State private var name = ""
    @State private var defaultAgent: SessionKind = .claude
    @State private var devCommand = ""
    @State private var editor = ""
    @State private var notificationsEnabled = true
    @State private var projectMuted = false
    @State private var iconPath: String?
    @State private var isDropTargeted = false

    var body: some View {
        ModalSurface(relayLocalized("Project Settings"), onDismiss: { model.dismissModal() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                field("Icon") { iconField }

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
                            Text(relayLocalized(kind.displayName)).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .clickable()
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
                        .clickable()
                        Toggle(isOn: $projectMuted) {
                            Text(relayLocalized("Mute this project"))
                                .font(Theme.Typography.row)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .clickable(notificationsEnabled)
                        .disabled(!notificationsEnabled)
                    }
                    .toggleStyle(.switch)
                }
                }
                .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
                .padding(.vertical, ModalSurface<EmptyView, EmptyView>.verticalInset)
            }
        } footer: {
            HStack(spacing: Theme.Spacing.small) {
                RelayButton(relayLocalized("Remove Project"), kind: .destructive) {
                    model.removeProject(project.id)
                    model.dismissModal()
                }
                Spacer()
                RelayButton(relayLocalized("Cancel"), kind: .ghost) { model.dismissModal() }
                RelayButton(relayLocalized("Save"), kind: .primary) {
                    var updated = project
                    updated.name = name.trimmingCharacters(in: .whitespaces).isEmpty
                        ? project.name
                        : name.trimmingCharacters(in: .whitespaces)
                    updated.defaultAgent = defaultAgent
                    updated.defaultServiceCommand = devCommand.isEmpty ? nil : devCommand
                    updated.preferredEditor = editor.isEmpty ? nil : editor
                    updated.iconPath = iconPath
                    model.updateProject(updated)

                    var settings = model.notificationSettings
                    settings.isEnabled = notificationsEnabled
                    if settings.isMuted(project.id) != projectMuted {
                        settings.toggleMute(project.id)
                    }
                    model.updateNotificationSettings(settings)
                    model.dismissModal()
                }
            }
        }
        .onAppear {
            name = project.name
            defaultAgent = project.defaultAgent
            devCommand = project.defaultServiceCommand ?? ""
            editor = project.preferredEditor ?? ""
            iconPath = project.iconPath
            notificationsEnabled = model.notificationSettings.isEnabled
            projectMuted = model.notificationSettings.isMuted(project.id)
        }
    }

    /// Almost no project needs this: the tile already shows whatever favicon or
    /// app icon the repository carries. It exists for the ones that carry
    /// nothing, or carry the wrong thing.
    private var iconField: some View {
        HStack(spacing: Theme.Spacing.medium) {
            ProjectIcon(
                initials: ProjectAppearance.initials(for: name.isEmpty ? project.name : name),
                tint: ProjectAppearance.tint(for: project.rootPath),
                status: .offline,
                isSelected: true,
                size: 48,
                image: previewImage
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isDropTargeted ? Theme.Palette.accent : .clear, lineWidth: 2)
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
                    RelayButton(relayLocalized("Choose…"), systemImage: "photo") { chooseIcon() }
                    if iconPath != nil {
                        RelayButton(relayLocalized("Reset"), kind: .ghost) { iconPath = nil }
                    }
                }
                Text(iconHint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ProjectIconLocator.isReadable(url.path) else { return }
                    Task { @MainActor in iconPath = url.path }
                }
            }
            return true
        }
    }

    private var previewImage: NSImage? {
        guard let path = iconPath else { return model.projectIcons[project.id] }
        return ProjectIconLoader.read(path).flatMap(NSImage.init(data:))
    }

    private var iconHint: String {
        if let iconPath { return (iconPath as NSString).abbreviatingWithTildeInPath }
        var candidate = project
        candidate.iconPath = nil
        if let discovered = ProjectIconLoader.path(for: candidate) {
            return relayLocalized("From the project") + " · " + (discovered as NSString).lastPathComponent
        }
        return relayLocalized("Drop an image here, or choose one")
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        iconPath = url.path
    }

    /// Localises here rather than at every call site: a field label is always
    /// a phrase shown to the user, and spelling that out fifteen times invites
    /// the one that gets forgotten.
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(relayLocalized(label).uppercased())
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)
            content()
        }
    }
}
