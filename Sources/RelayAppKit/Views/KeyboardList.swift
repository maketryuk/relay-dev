import SwiftUI

/// Where the keyboard's highlight lands.
///
/// Separated from the modifier so the two rules can be stated once: it stops at
/// the ends, and it never points past a list that has shrunk under it.
enum ListNavigation {
    static func moving(_ index: Int, by offset: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + offset, 0), count - 1)
    }

    static func clamping(_ index: Int, count: Int) -> Int {
        min(max(index, 0), max(count - 1, 0))
    }
}

/// Arrow-key navigation for a list inside a panel.
///
/// The panels open from the keyboard and close from the keyboard; having to
/// reach for the mouse in between is most of what made them tiresome. The
/// modifier owns only the index — what a row looks like when it is highlighted,
/// and what Return does to it, belong to the list.
struct KeyboardNavigableList: ViewModifier {
    let count: Int
    @Binding var highlighted: Int
    let onActivate: () -> Void

    func body(content: Content) -> some View {
        content
            .background {
                // Escape is deliberately left alone: the panel closes on it, and
                // a list that swallowed it would trap the user inside.
                KeyCaptureView(
                    onMoveDown: { move(by: 1) },
                    onMoveUp: { move(by: -1) },
                    onReturn: { if count > 0 { onActivate() } }
                )
            }
            // Filtering shrinks the list under the highlight; landing on nothing
            // makes Return do nothing for no visible reason.
            .onChange(of: count) { _, updated in
                highlighted = ListNavigation.clamping(highlighted, count: updated)
            }
    }

    private func move(by offset: Int) {
        highlighted = ListNavigation.moving(highlighted, by: offset, count: count)
    }
}

extension View {
    func keyboardNavigableList(
        count: Int,
        highlighted: Binding<Int>,
        onActivate: @escaping () -> Void
    ) -> some View {
        modifier(KeyboardNavigableList(count: count, highlighted: highlighted, onActivate: onActivate))
    }
}
