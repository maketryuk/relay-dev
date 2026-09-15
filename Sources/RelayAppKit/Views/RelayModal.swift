import RelayProtocol
import RelayUI
import SwiftUI

/// The panels that open over the window rather than beside it.
///
/// They were separate windows, each with its own traffic lights to chase around
/// the screen and dismiss. Nothing here is a document or a place to leave open
/// while working — they are things you consult and close — so they behave like
/// the command palette: one Escape, one click outside, gone.
enum RelayModal: Identifiable, Hashable {
    case ports
    case sshHosts
    case settings
    case addProject
    case projectSettings(ProjectID)
    /// A nil service is a new one.
    case serviceEditor(projectID: ProjectID, serviceID: String?)
    /// A nil preset is a new one.
    case presetEditor(presetID: String?)

    /// Identified by what it is, not by what it holds: the panel looks the
    /// current object up from the model every time it draws, so it cannot end
    /// up showing a copy that has since moved on.
    var id: String {
        switch self {
        case .ports: "ports"
        case .sshHosts: "ssh"
        case .settings: "settings"
        case .addProject: "add-project"
        case let .projectSettings(projectID): "project-settings:\(projectID.rawValue)"
        case let .serviceEditor(projectID, serviceID): "service:\(projectID.rawValue):\(serviceID ?? "new")"
        case let .presetEditor(presetID): "preset:\(presetID ?? "new")"
        }
    }

    @MainActor
    var title: String {
        switch self {
        case .ports: relayLocalized("Ports")
        case .sshHosts: relayLocalized("SSH Hosts")
        case .settings: relayLocalized("Settings")
        case .addProject: relayLocalized("Add Project")
        case .projectSettings: relayLocalized("Project Settings")
        case let .serviceEditor(_, serviceID):
            relayLocalized(serviceID == nil ? "New Service" : "Edit Service")
        case let .presetEditor(presetID):
            relayLocalized(presetID == nil ? "New Preset" : "Edit Preset")
        }
    }

    var size: CGSize {
        switch self {
        case .ports: CGSize(width: 640, height: 560)
        case .sshHosts: CGSize(width: 560, height: 540)
        case .settings: CGSize(width: 760, height: 580)
        case .addProject: CGSize(width: 480, height: 460)
        case .projectSettings: CGSize(width: 520, height: 600)
        case .serviceEditor: CGSize(width: 480, height: 500)
        case .presetEditor: CGSize(width: 540, height: 580)
        }
    }
}

struct ModalHost: View {
    @Environment(AppModel.self) private var model
    let modal: RelayModal

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.dismissModal() }

            panel
                .frame(width: modal.size.width, height: modal.size.height)
                .modalPlate()
                // A text field inside swallows Escape before SwiftUI sees it,
                // so the key is caught at the window instead.
                .background { KeyCaptureView(onEscape: { model.dismissModal() }) }
        }
    }

    @ViewBuilder
    private var panel: some View {
        if hasOwnSurface {
            content
        } else {
            ModalSurface(modal.title, onDismiss: { model.dismissModal() }) {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch modal {
        case .ports: PortsPane()
        case .sshHosts: SSHPane()
        case .settings: SettingsView()
        case .addProject: AddProjectSheet()
        case let .projectSettings(projectID):
            if let project = model.project(projectID) {
                ProjectSettingsView(project: project)
            }
        case let .serviceEditor(projectID, serviceID):
            if let project = model.project(projectID) {
                ServiceEditorView(
                    project: project,
                    service: serviceID.flatMap { identifier in
                        project.services.first { $0.id == identifier }
                    }
                )
            }
        case let .presetEditor(presetID):
            PresetEditorView(preset: presetID.flatMap { identifier in
                model.presets.first { $0.id == identifier }
            })
        }
    }

    /// Panels that are a form carry their own footer, so they build the whole
    /// surface; the rest are just a body.
    private var hasOwnSurface: Bool {
        switch modal {
        case .ports, .sshHosts, .settings: false
        case .addProject, .projectSettings, .serviceEditor, .presetEditor: true
        }
    }
}
