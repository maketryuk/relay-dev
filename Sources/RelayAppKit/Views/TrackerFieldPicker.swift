import RelayTracker
import RelayUI
import SwiftUI

/// A field's value picked from a list that can be searched, as the tracker's
/// own picker does it: a state or a priority in its colour, a person with
/// their picture, and several at once where the field holds several.
///
/// One value is set the moment it is clicked. Several are ticked and set
/// together when the list closes, so ticking three people is one write and
/// not three, each of which the tracker would announce to everyone on it.
struct TrackerFieldPicker: View {
    @Environment(AppModel.self) private var model
    let field: TrackerField
    @Binding var isPresented: Bool
    let onChoose: ([FieldOption]) -> Void

    @State private var query = ""
    @State private var focus = ListFocus()
    @State private var ticked: [FieldOption] = []

    private var rows: [Row] {
        Self.rows(for: field, query: query, me: model.tracker.user?.login)
    }

    enum Row: Equatable, Identifiable {
        /// No value: "Unassigned", "No priority".
        case none(String)
        case option(FieldOption)

        var id: String {
            switch self {
            case .none: "\u{0}none"
            case let .option(option): TrackerFieldPicker.key(of: option)
            }
        }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            // Return is the list's, caught below before the field sees it.
            RelayTextField(relayLocalized("Search"), text: $query, systemImage: "magnifyingglass", autofocus: true)
                .padding(Theme.Spacing.small)
            RelayDivider()
            if rows.isEmpty {
                Text(relayLocalized("No matches"))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(Theme.Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                KeyboardScrollingList(focusedRow: focus.row, identifyingRow: { rows[safe: $0]?.id }) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, isFocused: index == focus.row) { activate(rows, at: index) }
                                .id(row.id)
                        }
                    }
                    .padding(Theme.Spacing.xsmall)
                }
                // As tall as the rows, up to a point: a popover sizes itself
                // to what it holds, and a scroll view holds nothing of its own.
                .frame(height: min(CGFloat(rows.count) * (Self.rowHeight + 1) + Theme.Spacing.small, 320))
            }
        }
        .frame(width: 300)
        // Up, down and Return only: left and right move the caret in the
        // search field, and Escape closes the popover as it always does.
        .background {
            KeyCaptureView(
                onMoveDown: { focus = ListNavigation.movingRow(focus, by: 1, rowCount: rows.count) },
                onMoveUp: { focus = ListNavigation.movingRow(focus, by: -1, rowCount: rows.count) },
                onReturn: { activate(rows, at: focus.row) }
            )
        }
        .onChange(of: query) { focus = ListFocus() }
        .onAppear { ticked = field.values }
        .onDisappear {
            guard field.allowsSeveral, Set(ticked.map(Self.key)) != Set(field.values.map(Self.key)) else { return }
            onChoose(ticked)
        }
    }

    private func activate(_ rows: [Row], at index: Int) {
        guard let row = rows[safe: index] else { return }
        switch row {
        case .none:
            onChoose([])
            isPresented = false
        case let .option(option):
            if field.allowsSeveral {
                if let at = ticked.firstIndex(where: { Self.key(of: $0) == Self.key(of: option) }) {
                    ticked.remove(at: at)
                } else {
                    ticked.append(option)
                }
            } else {
                if Self.key(of: option) != field.values.first.map(Self.key) { onChoose([option]) }
                isPresented = false
            }
        }
    }

    private func isChosen(_ row: Row) -> Bool {
        switch row {
        case .none:
            return field.values.isEmpty
        case let .option(option):
            let chosen = field.allowsSeveral ? ticked : field.values
            return chosen.contains { Self.key(of: $0) == Self.key(of: option) }
        }
    }

    private func rowView(_ row: Row, isFocused: Bool, action: @escaping () -> Void) -> some View {
        TrackerFieldPickerRow(isFocused: isFocused, action: action) {
            HStack(spacing: Theme.Spacing.small) {
                mark(isChosen(row))
                switch row {
                case let .none(title):
                    Text(verbatim: title)
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textSecondary)
                case let .option(option):
                    if field.kind == .user {
                        TrackerAvatar(name: option.title, avatar: option.avatar, size: 20)
                        Text(verbatim: option.title)
                            .font(Theme.Typography.row)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        if let login = option.login, login != option.title {
                            Text(verbatim: login)
                                .font(Theme.Typography.rowSecondary)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(1)
                        }
                    } else if option.color != nil {
                        TrackerChip(text: option.title, color: option.color)
                            .lineLimit(1)
                    } else {
                        Text(verbatim: option.title)
                            .font(Theme.Typography.row)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// A tick for one value, a box for several — which also says, before
    /// anything is clicked, whether a click closes the list.
    @ViewBuilder
    private func mark(_ isOn: Bool) -> some View {
        if field.allowsSeveral {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(isOn ? Theme.Palette.accent : Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(isOn ? Theme.Palette.accent : Theme.Palette.borderStrong, lineWidth: 1)
                )
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .opacity(isOn ? 1 : 0)
                .frame(width: 14)
        }
    }

    static let rowHeight: CGFloat = 30

    // MARK: - What is listed

    /// A person by login, a value by its name: what a write names them by,
    /// and so what says two of them are the same one.
    nonisolated static func key(of option: FieldOption) -> String {
        option.login ?? option.name
    }

    /// The values to offer, best match first once something is typed. People
    /// in alphabetical order with whoever is signed in first, since that is
    /// who an issue is most often given to; anything else in the tracker's
    /// order, which for a state or a priority is its meaning.
    static func rows(for field: TrackerField, query: String, me: String?) -> [Row] {
        var options = field.options
        if field.kind == .user {
            options.sort { one, other in
                if one.login == me, other.login != me { return true }
                if other.login == me, one.login != me { return false }
                return one.title.localizedCaseInsensitiveCompare(other.title) == .orderedAscending
            }
        }
        let search = RelaySearchQuery(query)
        if search.isEmpty {
            let none = field.canBeEmpty && !field.allowsSeveral
                ? [Row.none(field.emptyText ?? relayLocalized("None"))] : []
            return none + options.map(Row.option)
        }
        return options
            .enumerated()
            .compactMap { offset, option -> (Int, Int, FieldOption)? in
                search.score([option.title, option.name, option.login ?? ""]).map { ($0, offset, option) }
            }
            .sorted { ($0.0, -$0.1) > ($1.0, -$1.1) }
            .map { Row.option($0.2) }
    }
}

/// One line of the list: highlighted under the pointer and under the
/// keyboard alike.
private struct TrackerFieldPickerRow<Content: View>: View {
    let isFocused: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, Theme.Spacing.small)
                .frame(height: TrackerFieldPicker.rowHeight)
                .background(isFocused || isHovering ? Theme.Palette.surfaceHover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { isHovering = $0 }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
