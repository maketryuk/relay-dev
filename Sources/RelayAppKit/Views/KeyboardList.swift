import RelayUI
import SwiftUI

/// Where the keyboard is inside a list: which row, and which of that row's
/// actions.
struct ListFocus: Equatable {
    var row = 0
    var action = 0
}

/// One thing a row can do, in the order the keyboard walks them.
///
/// The row and the list have to agree on that order — the list decides what
/// Return runs, the row decides what is drawn — so both read the same array
/// rather than each building its own.
struct RowAction: Identifiable {
    let id: String
    let systemImage: String
    let label: String
    var tint: Color?
    let run: () -> Void
}

/// Where the keyboard's highlight lands.
///
/// Separated from the modifier so the rules can be stated once: it stops at the
/// ends, it never points past a list that has shrunk under it, and moving to
/// another row starts that row's actions from the beginning.
enum ListNavigation {
    static func movingRow(_ focus: ListFocus, by offset: Int, rowCount: Int) -> ListFocus {
        guard rowCount > 0 else { return ListFocus() }
        return ListFocus(row: min(max(focus.row + offset, 0), rowCount - 1), action: 0)
    }

    static func movingAction(_ focus: ListFocus, by offset: Int, actionCount: Int) -> ListFocus {
        guard actionCount > 0 else { return ListFocus(row: focus.row, action: 0) }
        return ListFocus(row: focus.row, action: min(max(focus.action + offset, 0), actionCount - 1))
    }

    static func clamping(_ focus: ListFocus, rowCount: Int, actionCount: Int) -> ListFocus {
        ListFocus(
            row: min(max(focus.row, 0), max(rowCount - 1, 0)),
            action: min(max(focus.action, 0), max(actionCount - 1, 0))
        )
    }
}

/// Arrow-key navigation for a list inside a panel.
///
/// Up and down walk the rows, left and right walk the highlighted row's actions,
/// and Return runs the one in focus. The panels open from the keyboard and close
/// from the keyboard; having to reach for the mouse to actually *do* the thing
/// is most of what made them tiresome.
struct KeyboardNavigableList: ViewModifier {
    let rowCount: Int
    /// How many actions the highlighted row offers.
    let actionCount: Int
    @Binding var focus: ListFocus
    let onActivate: () -> Void

    func body(content: Content) -> some View {
        content
            .background {
                // Escape is deliberately left alone: the panel closes on it, and
                // a list that swallowed it would trap the user inside.
                KeyCaptureView(
                    onMoveDown: { focus = ListNavigation.movingRow(focus, by: 1, rowCount: rowCount) },
                    onMoveUp: { focus = ListNavigation.movingRow(focus, by: -1, rowCount: rowCount) },
                    onMoveRight: { focus = ListNavigation.movingAction(focus, by: 1, actionCount: actionCount) },
                    onMoveLeft: { focus = ListNavigation.movingAction(focus, by: -1, actionCount: actionCount) },
                    onReturn: { if rowCount > 0 { onActivate() } }
                )
            }
            // Filtering shrinks the list under the highlight; landing on nothing
            // makes Return do nothing for no visible reason.
            .onChange(of: rowCount) { _, updated in
                focus = ListNavigation.clamping(focus, rowCount: updated, actionCount: actionCount)
            }
            .onChange(of: actionCount) { _, updated in
                focus = ListNavigation.clamping(focus, rowCount: rowCount, actionCount: updated)
            }
    }
}

extension View {
    func keyboardNavigableList(
        rowCount: Int,
        actionCount: Int,
        focus: Binding<ListFocus>,
        onActivate: @escaping () -> Void
    ) -> some View {
        modifier(KeyboardNavigableList(
            rowCount: rowCount,
            actionCount: actionCount,
            focus: focus,
            onActivate: onActivate
        ))
    }
}

/// A scrolling list that keeps the keyboard's row on screen.
///
/// A container rather than a modifier, because `ScrollViewReader` has to sit
/// outside the scroll view it reads — which is most of why following the
/// highlight was written out twice and then forgotten twice. A list that can be
/// walked with the arrow keys but not followed with them is a list that can be
/// walked off the bottom of.
struct KeyboardScrollingList<RowID: Hashable, Content: View>: View {
    /// The row the keyboard is on.
    let focusedRow: Int
    /// What identifies that row to the scroll view, or nil when the index
    /// points past a list that has been filtered out from under it.
    let identifyingRow: (Int) -> RowID?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                content()
            }
            .onChange(of: focusedRow) { _, row in
                guard let id = identifyingRow(row) else { return }
                // Centred rather than scrolled the least that would reveal it.
                // "Wholly visible" is measured against the scroll view, and a
                // pinned section header floats over its content rather than
                // shortening it — so the least that reveals a row puts it
                // under the header, which is where it stops being visible.
                //
                // This costs less than it sounds: the offset is clamped to the
                // content, so at either end of a list nothing moves at all, and
                // in the middle each keypress scrolls exactly one row.
                withAnimation(.easeOut(duration: 0.12)) {
                    scroller.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

/// The actions of a highlighted row, with the one in focus marked.
struct RowActionBar: View {
    let actions: [RowAction]
    /// Nil when the keyboard is elsewhere.
    let focusedAction: Int?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                IconButton(
                    systemImage: action.systemImage,
                    help: "",
                    isKeyboardFocused: index == focusedAction,
                    tint: action.tint,
                    action: action.run
                )
                .relayTooltip(action.label)
            }
        }
    }
}
