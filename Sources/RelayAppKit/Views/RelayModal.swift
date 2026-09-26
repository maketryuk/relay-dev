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
    /// Somewhere to switch branches from, reachable by typing as well as by
    /// clicking the branch name.
    case branches(ProjectID)
    /// A new checkout of the project on a branch of its own.
    case newWorktree(ProjectID)
    /// The project's worktrees, what stands in the way of removing each, and
    /// removing the chosen ones.
    case worktreeCleanup(ProjectID)
    /// Where a pull or a push is going, before it goes there.
    case gitTransfer(projectID: ProjectID, direction: GitTransfer.Direction)
    /// The two versions of everything a merge could not settle.
    case conflicts(ProjectID)
    /// One file's two revisions, and the one being written.
    case merge(projectID: ProjectID, path: String)
    /// Which of several declarations of one name was meant.
    case definitions(projectID: ProjectID, name: String)
    /// Everywhere a word appears in the project's files.
    case search(ProjectID)
    case addProject
    case projectSettings(ProjectID)
    /// A nil service is a new one.
    case serviceEditor(projectID: ProjectID, serviceID: String?)
    /// A nil preset is a new one.
    case presetEditor(presetID: String?)
    /// A nil alias is a host that does not exist yet.
    case sshHostEditor(alias: String?)
    /// Asks once for the passphrase of the key at this path.
    case sshKeyUnlock(keyPath: String)
    /// The tracker's board for the project: its columns and its cards.
    case board(ProjectID)
    /// One issue, opened from the board: to read, edit, comment on and time.
    case issue(projectID: ProjectID, key: String)
    /// A new card, in a column when one was named.
    case newIssue(projectID: ProjectID, boardID: String, columnID: String?)
    /// Time to record against an issue — measured by the timer, or typed.
    case logWork(key: String, fromTimer: Bool)
    /// Time already recorded, to correct or take off.
    case editWork(key: String, itemID: String)

    /// Identified by what it is, not by what it holds: the panel looks the
    /// current object up from the model every time it draws, so it cannot end
    /// up showing a copy that has since moved on.
    var id: String {
        switch self {
        case .ports: "ports"
        case .sshHosts: "ssh"
        case let .branches(projectID): "branches:\(projectID.rawValue)"
        case let .newWorktree(projectID): "new-worktree:\(projectID.rawValue)"
        case let .worktreeCleanup(projectID): "worktree-cleanup:\(projectID.rawValue)"
        case let .gitTransfer(projectID, direction): "git-\(direction.rawValue):\(projectID.rawValue)"
        case let .conflicts(projectID): "conflicts:\(projectID.rawValue)"
        case let .merge(projectID, path): "merge:\(projectID.rawValue):\(path)"
        case let .definitions(projectID, name): "definitions:\(projectID.rawValue):\(name)"
        case let .search(projectID): "search:\(projectID.rawValue)"
        case .settings: "settings"
        case .addProject: "add-project"
        case let .projectSettings(projectID): "project-settings:\(projectID.rawValue)"
        case let .serviceEditor(projectID, serviceID): "service:\(projectID.rawValue):\(serviceID ?? "new")"
        case let .presetEditor(presetID): "preset:\(presetID ?? "new")"
        case let .sshHostEditor(alias): "ssh-host:\(alias ?? "new")"
        case let .sshKeyUnlock(keyPath): "ssh-key:\(keyPath)"
        case let .board(projectID): "board:\(projectID.rawValue)"
        case let .issue(projectID, key): "issue:\(projectID.rawValue):\(key)"
        case let .newIssue(projectID, boardID, columnID): "new-issue:\(projectID.rawValue):\(boardID):\(columnID ?? "")"
        case let .logWork(key, _): "log-work:\(key)"
        case let .editWork(key, itemID): "edit-work:\(key):\(itemID)"
        }
    }

    @MainActor
    var title: String {
        switch self {
        case .ports: relayLocalized("Ports")
        case .sshHosts: relayLocalized("SSH Hosts")
        case .branches: relayLocalized("Branches")
        case .newWorktree: relayLocalized("New Worktree")
        case .worktreeCleanup: relayLocalized("Clean Up Worktrees")
        case let .gitTransfer(_, direction):
            relayLocalized(direction == .pull ? "Pull" : "Push")
        case .conflicts: relayLocalized("Resolve conflicts")
        case .merge: relayLocalized("Merge")
        case let .definitions(_, name): String(format: relayLocalized("Definitions of %@"), name)
        case .search: relayLocalized("Find in Files")
        case .settings: relayLocalized("Settings")
        case .addProject: relayLocalized("Add Project")
        case .projectSettings: relayLocalized("Project Settings")
        case let .serviceEditor(_, serviceID):
            relayLocalized(serviceID == nil ? "New Service" : "Edit Service")
        case let .presetEditor(presetID):
            relayLocalized(presetID == nil ? "New Preset" : "Edit Preset")
        case let .sshHostEditor(alias):
            relayLocalized(alias == nil ? "New Host" : "Edit Host")
        case .sshKeyUnlock: relayLocalized("Unlock Key")
        case .board: relayLocalized("Issue Board")
        case let .issue(_, key): key
        case .newIssue: relayLocalized("New Issue")
        case .logWork: relayLocalized("Log Time")
        case .editWork: relayLocalized("Edit Time")
        }
    }

    var size: CGSize {
        switch self {
        case .ports: CGSize(width: 640, height: 560)
        case .sshHosts: CGSize(width: 560, height: 540)
        case .branches: CGSize(width: 520, height: 520)
        case .newWorktree: CGSize(width: 520, height: 560)
        case .worktreeCleanup: CGSize(width: 660, height: 620)
        case let .gitTransfer(_, direction):
            CGSize(width: 580, height: direction == .pull ? 430 : 580)
        case .conflicts: CGSize(width: 820, height: 480)
        // Three revisions side by side need the width, and a file needs the
        // height: this is the one panel that wants the whole window.
        case .merge: CGSize(width: 1_400, height: 900)
        case .definitions: CGSize(width: 620, height: 420)
        case .search: CGSize(width: 980, height: 720)
        case .settings: CGSize(width: 760, height: 580)
        case .addProject: CGSize(width: 480, height: 460)
        case .projectSettings: CGSize(width: 520, height: 600)
        case .serviceEditor: CGSize(width: 480, height: 500)
        case .presetEditor: CGSize(width: 540, height: 580)
        case .sshHostEditor: CGSize(width: 540, height: 620)
        case .sshKeyUnlock: CGSize(width: 440, height: 340)
        // A board is columns side by side, and it wants all the width there is.
        case .board: CGSize(width: 1_600, height: 1_000)
        case .issue: CGSize(width: 1_040, height: 780)
        case .newIssue: CGSize(width: 560, height: 580)
        case .logWork, .editWork: CGSize(width: 480, height: 500)
        }
    }
}

struct ModalHost: View {
    @Environment(AppModel.self) private var model
    let modal: RelayModal

    /// How much window is left showing around a panel at its largest. A dialog
    /// flush against the top and bottom of the window reads as a second window
    /// rather than as something opened over this one — and a panel asking for
    /// more height than the window has would simply be cut off.
    private static let margin: CGFloat = Theme.Spacing.xlarge

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.dismissModal() }

            GeometryReader { proxy in
                panel
                    .frame(
                        width: min(modal.size.width, max(proxy.size.width - Self.margin * 2, 320)),
                        height: min(modal.size.height, max(proxy.size.height - Self.margin * 2, 240))
                    )
                    .modalPlate()
                    // A text field inside swallows Escape before SwiftUI sees
                    // it, so the key is caught at the window instead.
                    .background { KeyCaptureView(onEscape: { model.dismissModal() }) }
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
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
        case let .branches(projectID):
            if let project = model.project(projectID) {
                BranchesPane(project: project)
            }
        case let .newWorktree(projectID):
            if let project = model.project(projectID) {
                NewWorktreeView(project: project)
            }
        case let .worktreeCleanup(projectID):
            if let project = model.project(projectID) {
                WorktreeCleanupView(project: project)
            }
        case let .gitTransfer(projectID, direction):
            if let project = model.project(projectID) {
                GitTransferPane(project: project, direction: direction)
            }
        case let .conflicts(projectID):
            if let project = model.project(projectID) {
                GitConflictPane(project: project)
            }
        case let .merge(projectID, path):
            if let project = model.project(projectID) {
                GitMergePane(project: project, path: path)
            }
        case let .definitions(projectID, _):
            if let project = model.project(projectID) {
                DefinitionsPane(project: project)
            }
        case let .search(projectID):
            if let project = model.project(projectID) {
                SearchPane(project: project)
            }
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
        case let .sshHostEditor(alias):
            SSHHostEditorView(host: alias.flatMap { identifier in
                model.sshHosts.first { $0.alias == identifier }
            })
        case let .sshKeyUnlock(keyPath):
            SSHKeyUnlockView(keyPath: keyPath)
        case let .board(projectID):
            if let project = model.project(projectID) {
                BoardPane(project: project)
            }
        case let .issue(projectID, key):
            if let project = model.project(projectID) {
                IssuePane(project: project, key: key)
            }
        case let .newIssue(projectID, boardID, columnID):
            if let project = model.project(projectID) {
                NewIssueView(project: project, boardID: boardID, columnID: columnID)
            }
        case let .logWork(key, fromTimer):
            LogWorkView(key: key, fromTimer: fromTimer)
        case let .editWork(key, itemID):
            if let item = model.tracker.workItems[key]?.first(where: { $0.id == itemID }) {
                LogWorkView(key: key, fromTimer: false, editing: item)
            }
        }
    }

    /// Panels that are a form carry their own footer, so they build the whole
    /// surface; the rest are just a body.
    private var hasOwnSurface: Bool {
        switch modal {
        case .ports, .sshHosts, .settings, .branches, .definitions, .search: false
        case .addProject, .projectSettings, .serviceEditor, .presetEditor, .sshHostEditor, .sshKeyUnlock,
             .gitTransfer, .conflicts, .merge, .newWorktree, .worktreeCleanup,
             .board, .issue, .newIssue, .logWork, .editWork:
            true
        }
    }
}
