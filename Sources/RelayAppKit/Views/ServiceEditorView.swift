import RelayUI
import SwiftUI

struct ServiceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let service: ServiceDefinition?

    @State private var name = ""
    @State private var command = ""
    @State private var urlOverride = ""
    @State private var isDefault = false

    private var isEditing: Bool { service != nil }

    var body: some View {
        ModalSurface(
            relayLocalized(isEditing ? "Edit Service" : "New Service"),
            onDismiss: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                field("Name") {
                    RelayTextField("Dev", text: $name)
                }
                field("Command") {
                    VStack(alignment: .leading, spacing: 4) {
                        RelayTextField("pnpm run dev", text: $command)
                        Text("Runs in \(project.displayPath) through your shell.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                field("URL override") {
                    VStack(alignment: .leading, spacing: 4) {
                        RelayTextField("http://localhost:3000", text: $urlOverride)
                        Text(relayLocalized("Leave empty to detect the port automatically."))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                Toggle(isOn: $isDefault) {
                    Text(relayLocalized("Default dev service"))
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .toggleStyle(.switch)
            }
            .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
            .padding(.vertical, ModalSurface<EmptyView, EmptyView>.verticalInset)
        } footer: {
            HStack {
                Spacer()
                RelayButton(relayLocalized("Cancel"), kind: .ghost) { dismiss() }
                RelayButton(relayLocalized(isEditing ? "Save" : "Add"), kind: .primary) { save() }
            }
        }
        .frame(width: 480, height: 500)
        .modalPlate()
        .onAppear {
            name = service?.name ?? "Dev"
            command = service?.command ?? (project.defaultServiceCommand ?? "")
            urlOverride = service?.urlOverride ?? ""
            isDefault = service?.isDefault ?? project.services.isEmpty
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedCommand.isEmpty else { return }

        var updated = service ?? ServiceDefinition(name: trimmedName, command: trimmedCommand)
        updated.name = trimmedName
        updated.command = trimmedCommand
        updated.urlOverride = urlOverride.isEmpty ? nil : urlOverride
        updated.isDefault = isDefault

        if isEditing {
            model.updateService(updated, in: project.id)
        } else {
            model.addService(updated, to: project.id)
        }

        // Only one service can be the default.
        if isDefault, var owner = model.project(project.id) {
            for index in owner.services.indices where owner.services[index].id != updated.id {
                owner.services[index].isDefault = false
            }
            model.updateProject(owner)
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
