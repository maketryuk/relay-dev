import RelayTracker
import RelayUI
import SwiftUI

/// A field's name beside its value, as an issue's sidebar lists them: in the
/// issue, and in a new one before it exists.
struct TrackerFieldRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            // Two lines rather than cut short: a field made in
            // Russian is called "Затраченное время", not "Затр…".
            Text(verbatim: title)
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 104, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A field's value, drawn the way the tracker draws it.
struct TrackerFieldValue: View {
    let field: TrackerField
    let isEditable: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            if field.kind == .user, !field.allowsSeveral, let person = field.values.first {
                TrackerAvatar(name: person.title, avatar: person.avatar, size: 16)
            }
            // Drawn as the tracker draws it when it gives the values colours,
            // so a priority is recognised here by the colour it has there.
            if field.kind == .option, field.values.contains(where: { $0.color != nil }) {
                ForEach(field.values) { option in
                    TrackerChip(text: option.title, color: option.color)
                        .lineLimit(1)
                }
            } else {
                Text(verbatim: shown)
                    .font(Theme.Typography.row)
                    .foregroundStyle(field.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                    .lineLimit(2)
            }
            if isEditable {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private var shown: String {
        switch field.kind {
        case .option, .user:
            let titles = field.values.map(\.title)
            return titles.isEmpty ? (field.emptyText ?? "—") : titles.joined(separator: ", ")
        case .date:
            return field.date.map(TrackerText.day) ?? field.emptyText ?? "—"
        case .period:
            return field.text ?? field.emptyText ?? "—"
        case .text, .other:
            return field.text ?? "—"
        }
    }
}

/// A field's value that can be given a new one, with whatever a value of its
/// kind is chosen with: a list for a choice, a calendar for a day, and for a
/// length of time the length typed as it would be said.
struct TrackerFieldEditor: View {
    /// The field as it is to be shown, with the value it has now.
    let field: TrackerField
    let isEnabled: Bool
    let onChange: (FieldChange) -> Void

    var body: some View {
        switch field.kind {
        case .option, .user:
            FieldValueButton(field: field, isEnabled: isEnabled) {
                TrackerFieldValue(field: field, isEditable: true)
            } onChoose: { values in
                onChange(FieldChange(field: field, values: values))
            }
        case .date:
            FieldDayButton(field: field, isEnabled: isEnabled) {
                TrackerFieldValue(field: field, isEditable: true)
            } onChoose: { date in
                let day = date.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) }
                onChange(FieldChange(field: field, day: day))
            }
        case .period:
            FieldLengthButton(field: field, isEnabled: isEnabled) {
                TrackerFieldValue(field: field, isEditable: true)
            } onChoose: { minutes in
                onChange(FieldChange(field: field, minutes: minutes))
            }
        case .text, .other:
            TrackerFieldValue(field: field, isEditable: false)
        }
    }
}

/// A field's value as a button that opens the list to choose it from.
struct FieldValueButton<Label: View>: View {
    let field: TrackerField
    let isEnabled: Bool
    @ViewBuilder let label: () -> Label
    let onChoose: ([FieldOption]) -> Void

    @State private var isPicking = false

    var body: some View {
        Button { isPicking = true } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable(isEnabled)
        .disabled(!isEnabled)
        .popover(isPresented: $isPicking, arrowEdge: .leading) {
            TrackerFieldPicker(field: field, isPresented: $isPicking, onChoose: onChoose)
        }
    }
}

/// A date field's day as a button that opens a calendar. A day clicked is
/// chosen, and the calendar closes.
private struct FieldDayButton<Label: View>: View {
    let field: TrackerField
    let isEnabled: Bool
    @ViewBuilder let label: () -> Label
    let onChoose: (Date?) -> Void

    @State private var isPicking = false
    @State private var day = Date()

    var body: some View {
        Button {
            day = field.date ?? Date()
            isPicking = true
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable(isEnabled)
        .disabled(!isEnabled)
        .popover(isPresented: $isPicking, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                DatePicker("", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.locale, Localization.shared.locale)
                // Today is also what an empty field's calendar opens on, where
                // clicking it would change nothing: this is how to choose it.
                HStack(spacing: Theme.Spacing.xsmall) {
                    RelayButton(relayLocalized("Today")) { choose(Date()) }
                    if field.canBeEmpty, field.date != nil {
                        RelayButton(field.emptyText ?? relayLocalized("None"), kind: .ghost) { choose(nil) }
                    }
                }
            }
            .padding(Theme.Spacing.medium)
            .onChange(of: day) { _, picked in choose(picked) }
        }
    }

    private func choose(_ date: Date?) {
        onChoose(date)
        isPicking = false
    }
}

/// A length of time as a button that opens a field to type it in, read back
/// underneath as it is typed. What is typed is kept when the field closes,
/// however it closes, since clicking away is how most people finish typing;
/// what cannot be read as a length is dropped, and emptied is none.
private struct FieldLengthButton<Label: View>: View {
    let field: TrackerField
    let isEnabled: Bool
    @ViewBuilder let label: () -> Label
    let onChoose: (Int?) -> Void

    @State private var isTyping = false
    @State private var typed = ""

    var body: some View {
        Button {
            typed = field.text ?? ""
            isTyping = true
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable(isEnabled)
        .disabled(!isEnabled)
        .popover(isPresented: $isTyping, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 4) {
                RelayTextField("1h 30m", text: $typed, autofocus: true) { isTyping = false }
                    .frame(width: 200)
                Text(verbatim: TrackerText.reading(ofLength: typed))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(WorkDuration.minutes(from: typed) == nil && !typed.isEmpty
                        ? Theme.Palette.statusError
                        : Theme.Palette.textTertiary)
            }
            .padding(Theme.Spacing.medium)
            .onDisappear(perform: commit)
        }
    }

    private func commit() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (field.text ?? "") else { return }
        if text.isEmpty {
            onChoose(nil)
        } else if let minutes = WorkDuration.minutes(from: text) {
            onChoose(minutes)
        }
    }
}
