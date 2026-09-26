import RelayTracker
import RelayUI
import SwiftUI

/// Time to record against an issue: what the timer measured, or what is typed
/// — or time already recorded, to correct.
///
/// The length is typed the way it would be said — `1h 30m`, `90`, `1:30` —
/// and read back underneath, so a typo is caught before it is on the invoice.
struct LogWorkView: View {
    @Environment(AppModel.self) private var model
    let key: String
    /// Opened by stopping the timer: its time is what is logged, and throwing
    /// it away is offered alongside.
    let fromTimer: Bool
    /// The entry being corrected, when this corrects one rather than adds one.
    var editing: TrackerWorkItem?

    @State private var duration = ""
    @State private var day = Date()
    @State private var text = ""
    @State private var typeID: String?
    @State private var isConfirmingDeletion = false

    private var tracker: TrackerController { model.tracker }
    private var minutes: Int? { WorkDuration.minutes(from: duration) }
    private var isLogging: Bool {
        tracker.writesInFlight.contains(editing.map { .changeWork($0.id) } ?? .work(key))
    }

    /// The panel as the modal stack knows it, to close only itself.
    private var modal: RelayModal {
        editing.map { .editWork(key: key, itemID: $0.id) } ?? .logWork(key: key, fromTimer: fromTimer)
    }

    private var project: TrackerProject? {
        tracker.issues[key]?.project ?? tracker.card(key)?.project ?? tracker.timer.flatMap { $0.key == key ? $0.project : nil }
    }

    private var types: [TrackerWorkType] {
        project.flatMap { tracker.workTypes[$0.id] } ?? []
    }

    private var summary: String {
        tracker.issues[key]?.summary ?? tracker.card(key)?.summary ?? tracker.timer.map(\.summary) ?? ""
    }

    var body: some View {
        ModalSurface(relayLocalized(editing == nil ? "Log Time" : "Edit Time"), onDismiss: dismiss) {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                Text(verbatim: "\(key)  \(summary)")
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)

                field(relayLocalized("How long")) {
                    VStack(alignment: .leading, spacing: 4) {
                        RelayTextField("1h 30m", text: $duration, autofocus: true, onSubmit: log)
                            .frame(width: 180)
                        Text(verbatim: durationReading)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(minutes == nil && !duration.isEmpty
                                ? Theme.Palette.statusError
                                : Theme.Palette.textTertiary)
                    }
                }

                HStack(alignment: .top, spacing: Theme.Spacing.xlarge) {
                    field(relayLocalized("Day")) {
                        RelayDateField(date: $day, latest: Date())
                            .frame(width: 180)
                    }
                    if !types.isEmpty {
                        field(relayLocalized("Kind of work")) {
                            RelayPickerField(
                                [.init(String?.none, title: relayLocalized("None"))]
                                    + types.map { .init(Optional($0.id), title: $0.name) },
                                selection: $typeID,
                                systemImage: "tag"
                            )
                            .frame(width: 220)
                        }
                    }
                }

                field(relayLocalized("What was done")) {
                    RelayTextEditor(relayLocalized("Optional"), text: $text, minHeight: 80)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
            .padding(.vertical, ModalSurface<EmptyView, EmptyView>.verticalInset)
        } footer: {
            HStack(spacing: Theme.Spacing.small) {
                if fromTimer {
                    RelayButton(relayLocalized("Discard Time"), kind: .destructive) {
                        tracker.discardTimer()
                        finish()
                    }
                }
                if editing != nil {
                    RelayButton(relayLocalized("Delete"), kind: .destructive) { isConfirmingDeletion = true }
                        .disabled(isLogging)
                }
                Spacer()
                RelayButton(relayLocalized("Cancel"), kind: .ghost, action: dismiss)
                RelayButton(primaryTitle, kind: .primary, action: log)
                    .disabled(minutes == nil || isLogging)
            }
        }
        .confirmationDialog(
            relayLocalized("Delete this time?"),
            isPresented: $isConfirmingDeletion,
            presenting: editing
        ) { item in
            Button(relayLocalized("Delete"), role: .destructive) { delete(item) }
            Button(relayLocalized("Cancel"), role: .cancel) {}
        } message: { item in
            Text(verbatim: String(
                format: relayLocalized("%@ logged on %@ is taken off %@."),
                TrackerText.duration(minutes: item.minutes),
                TrackerText.day(item.date),
                key
            ))
        }
        // However the panel closes — Escape included — a timer that was waiting
        // on this one is given up on unless `finish` has started it already.
        .onDisappear { if fromTimer { model.pendingTimerStart = nil } }
        .onAppear {
            if let project { tracker.loadWorkTypes(for: project) }
            if let editing {
                duration = TrackerText.duration(minutes: editing.minutes)
                day = editing.date
                text = editing.text
                typeID = editing.type?.id
            } else if fromTimer, let timer = tracker.timer, timer.key == key {
                duration = TrackerText.duration(minutes: WorkDuration.minutes(in: timer.elapsed(at: Date())))
            }
        }
    }

    private var primaryTitle: String {
        if editing != nil { return relayLocalized(isLogging ? "Saving…" : "Save") }
        return relayLocalized(isLogging ? "Logging…" : "Log")
    }

    /// Says what the typed length was read as, or that it was not.
    private var durationReading: String {
        if let minutes { return "= " + TrackerText.duration(minutes: minutes) }
        return duration.isEmpty
            ? relayLocalized("Hours and minutes: 1h 30m, 90m, 1:30")
            : relayLocalized("Not a length Relay can read. Try 1h 30m.")
    }

    private func log() {
        guard let minutes, !isLogging else { return }
        let entry = WorkEntry(minutes: minutes, date: day, text: text.trimmingCharacters(in: .whitespacesAndNewlines), typeID: typeID)
        Task {
            if let editing {
                guard await tracker.updateWork(editing, with: entry, on: key) else { return }
                model.dismissModal(modal)
                return
            }
            guard await tracker.logWork(entry, on: key) else { return }
            if fromTimer, tracker.timer?.key == key { tracker.discardTimer() }
            finish()
        }
    }

    private func delete(_ item: TrackerWorkItem) {
        Task {
            if await tracker.deleteWork(item, on: key) { model.dismissModal(modal) }
        }
    }

    /// Closing without logging leaves a stopped timer paused, time and all.
    private func dismiss() {
        model.dismissModal()
    }

    private func finish() {
        model.dismissModal(modal)
        model.startPendingTimer()
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
