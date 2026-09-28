import RelayProtocol
import RelayTracker
import RelayUI
import SwiftUI

/// A new card, laid out as the tracker's own form lays one out: what it says
/// on the left, and on the right the project, the column it starts in and the
/// project's fields, each showing what the project starts it with.
///
/// A field left as it is shown is left to the project, so the write names only
/// the fields changed here — and the project's default, which is what was
/// shown, is what the tracker puts in the rest.
struct NewIssueView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let boardID: String
    let columnID: String?

    @State private var summary = ""
    @State private var description = ""
    @State private var trackerProjectID: String?
    @State private var chosenColumnID: String?
    /// What each field was given here, by name. It belongs to the project it
    /// was given in: another project's field of the same name has values of
    /// its own, which a value from this one need not be among.
    @State private var changes: [String: FieldChange] = [:]

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

    private var chosenColumn: BoardColumn? {
        snapshot.flatMap { snapshot in snapshot.columns.first { $0.id == chosenColumnID } ?? snapshot.columns.first }
    }

    /// Every field the project's issues have, the board's own among them.
    private var projectFields: [TrackerField] {
        chosenProject.flatMap { tracker.newIssueFields[$0.id] } ?? []
    }

    private var fields: [TrackerField] {
        Self.settable(projectFields, columnField: snapshot?.columnField)
    }

    var body: some View {
        ModalSurface(relayLocalized("New Issue"), onDismiss: { model.dismissModal() }) {
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                        field(relayLocalized("Summary")) {
                            RelayTextField(relayLocalized("What needs doing"), text: $summary, autofocus: true, onSubmit: create)
                        }

                        field(relayLocalized("Description")) {
                            RichMarkdownEditor(
                                placeholder: relayLocalized("Write a description, or paste one here"),
                                markdown: $description,
                                minHeight: 180
                            )
                        }
                    }
                    .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
                    .padding(.vertical, ModalSurface<EmptyView, EmptyView>.verticalInset)
                }
                RelayDivider(axis: .vertical)
                ScrollView(.vertical, showsIndicators: false) {
                    fieldsSection
                        .padding(Theme.Spacing.large)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(Theme.Palette.sidebar)
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
        .onChange(of: chosenProject?.id, initial: true) {
            changes = [:]
            if let chosenProject { tracker.loadNewIssueFields(for: chosenProject) }
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let chosenProject {
                let choice = projectChoice(chosenProject)
                TrackerFieldRow(title: choice.title) {
                    if projects.count > 1 {
                        FieldValueButton(field: choice, isEnabled: !isCreating) {
                            TrackerFieldValue(field: choice, isEditable: true)
                        } onChoose: { chosen in
                            trackerProjectID = chosen.first?.id
                        }
                    } else {
                        TrackerFieldValue(field: choice, isEditable: false)
                    }
                }
            }

            if let snapshot, let chosenColumn {
                let choice = columnChoice(on: snapshot, chosen: chosenColumn)
                TrackerFieldRow(title: choice.title) {
                    FieldValueButton(field: choice, isEnabled: !isCreating) {
                        TrackerFieldValue(field: choice, isEditable: true)
                    } onChoose: { chosen in
                        chosenColumnID = chosen.first?.id
                    }
                }
            }

            ForEach(fields) { field in
                TrackerFieldRow(title: field.title) {
                    TrackerFieldEditor(field: shown(field), isEnabled: !isCreating) { change in
                        changes[field.name] = change
                    }
                }
            }

            if fields.isEmpty, let chosenProject, tracker.newIssueFieldsBeingRead.contains(chosenProject.id) {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Fields

    /// The fields offered: every one a value can be given here, except the
    /// board's own, which is the column's to set — it is set by moving the new
    /// card there, as any card is moved.
    nonisolated static func settable(_ fields: [TrackerField], columnField: String?) -> [TrackerField] {
        fields.filter { field in
            field.name != columnField && (field.isEditable || field.kind == .date || field.kind == .period)
        }
    }

    /// The field with what it was given here in place of what the project
    /// starts it with.
    private func shown(_ field: TrackerField) -> TrackerField {
        guard let change = changes[field.name] else { return field }
        var shown = field
        shown.values = change.values
        shown.date = change.day.flatMap { Calendar.current.date(from: $0) }
        shown.text = change.minutes.map { TrackerText.duration(minutes: $0) }
        return shown
    }

    /// The project and the column are chosen from the same list as a field's
    /// value: to whoever is making the issue they are two more of its fields,
    /// and the tracker's own form shows them as such. Neither is ever written
    /// as a field, so neither has a kind to repeat back.
    private func projectChoice(_ chosen: TrackerProject) -> TrackerField {
        func option(_ project: TrackerProject) -> FieldOption {
            FieldOption(id: project.id, name: project.id, title: project.name)
        }
        return TrackerField(
            name: "project",
            title: relayLocalized("Project"),
            kind: .option,
            values: [option(chosen)],
            options: projects.map(option),
            canBeEmpty: false,
            wireType: ""
        )
    }

    /// Named as the board's field is named, and each column in the colour its
    /// value has, so choosing a column reads as what it is: choosing a state.
    private func columnChoice(on snapshot: BoardSnapshot, chosen: BoardColumn) -> TrackerField {
        let boardField = projectFields.first { $0.name == snapshot.columnField }
        func option(_ column: BoardColumn) -> FieldOption {
            let value = column.values.first.flatMap { name in boardField?.options.first { $0.name == name } }
            return FieldOption(id: column.id, name: column.id, title: column.title, color: value?.color)
        }
        return TrackerField(
            name: snapshot.columnField ?? "column",
            title: boardField?.title ?? relayLocalized("Column"),
            kind: .option,
            values: [option(chosen)],
            options: snapshot.columns.map(option),
            canBeEmpty: false,
            wireType: ""
        )
    }

    // MARK: - Creating

    private func create() {
        guard canCreate, let trackerProject = chosenProject else { return }
        let draft = IssueDraft(
            project: trackerProject,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description,
            fields: fields.compactMap { changes[$0.name] }
        )
        Task {
            if await tracker.create(draft, in: chosenColumn, on: boardID) != nil {
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
