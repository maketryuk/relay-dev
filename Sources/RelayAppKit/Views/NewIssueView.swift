import RelayProtocol
import RelayTracker
import RelayUI
import SwiftUI

/// A new card: which project it belongs to, which column it starts in, and
/// what it says. Everything else is set on the issue once it exists, where the
/// fields and what each can be are known.
struct NewIssueView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let boardID: String
    let columnID: String?

    @State private var summary = ""
    @State private var description = ""
    @State private var trackerProjectID: String?
    @State private var chosenColumnID: String?

    private var tracker: TrackerController { model.tracker }
    private var snapshot: BoardSnapshot? { tracker.snapshots[boardID] }
    private var projects: [TrackerProject] { snapshot?.board.projects ?? [] }
    private var isCreating: Bool { tracker.writesInFlight.contains(.create) }

    private var canCreate: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chosenProject != nil && !isCreating
    }

    private var chosenProject: TrackerProject? {
        projects.first { $0.id == trackerProjectID } ?? projects.first
    }

    var body: some View {
        ModalSurface(relayLocalized("New Issue"), onDismiss: { model.dismissModal() }) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    if projects.count > 1 {
                        field(relayLocalized("Project")) {
                            RelayPickerField(
                                projects.map { .init(Optional($0.id), title: "\($0.name) (\($0.key))") },
                                selection: Binding(
                                    get: { chosenProject?.id },
                                    set: { trackerProjectID = $0 }
                                ),
                                systemImage: "folder"
                            )
                            .frame(maxWidth: 280, alignment: .leading)
                        }
                    }

                    if let snapshot, !snapshot.columns.isEmpty {
                        field(relayLocalized("Column")) {
                            ChipPicker(
                                items: snapshot.columns.map(\.id),
                                selection: Binding(
                                    get: { chosenColumnID ?? snapshot.columns[0].id },
                                    set: { chosenColumnID = $0 }
                                )
                            ) { id, _ in
                                Text(verbatim: snapshot.columns.first { $0.id == id }?.title ?? id)
                                    .font(Theme.Typography.row)
                                    .lineLimit(1)
                            }
                        }
                    }

                    field(relayLocalized("Summary")) {
                        RelayTextField(relayLocalized("What needs doing"), text: $summary, autofocus: true, onSubmit: create)
                    }

                    field(relayLocalized("Description")) {
                        RelayTextEditor(relayLocalized("Markdown. Optional."), text: $description, minHeight: 160)
                    }
                }
                .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
                .padding(.vertical, ModalSurface<EmptyView, EmptyView>.verticalInset)
            }
        } footer: {
            HStack(spacing: Theme.Spacing.small) {
                Spacer()
                RelayButton(relayLocalized("Cancel"), kind: .ghost) { model.dismissModal() }
                RelayButton(relayLocalized(isCreating ? "Creating…" : "Create"), kind: .primary, action: create)
                    .disabled(!canCreate)
            }
        }
        .onAppear { chosenColumnID = columnID }
    }

    private func create() {
        guard canCreate, let trackerProject = chosenProject else { return }
        let column = snapshot?.columns.first { $0.id == chosenColumnID } ?? snapshot?.columns.first
        let draft = IssueDraft(
            project: trackerProject,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description
        )
        Task {
            if await tracker.create(draft, in: column, on: boardID) != nil {
                model.dismissModal(.newIssue(projectID: project.id, boardID: boardID, columnID: columnID))
            }
        }
    }

    /// Takes a phrase already looked up, for the reason New Worktree's does.
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
