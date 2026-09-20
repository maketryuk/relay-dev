import RelayProtocol
import RelayUI
import SwiftUI

/// Which declaration of a name was meant.
///
/// Shown only when the answer is genuinely several: the index knows names
/// rather than types, so two classes with a `handle` method are two honest
/// candidates and picking one of them silently would be a guess dressed as an
/// answer. One candidate never reaches here — that jump has already happened.
struct DefinitionsPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var focus = ListFocus()

    private var matches: [SymbolDefinition] { model.definitionMatches }

    var body: some View {
        KeyboardScrollingList(
            focusedRow: focus.row,
            identifyingRow: { matches.indices.contains($0) ? matches[$0].id : nil }
        ) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, definition in
                    SidebarRow(
                        title: definition.name,
                        subtitle: place(of: definition),
                        systemImage: definition.kind.systemImage,
                        isSelected: focus.row == index,
                        action: { model.openDefinition(definition) }
                    )
                }
            }
            .padding(Theme.Spacing.small)
        }
        .keyboardNavigableList(rowCount: matches.count, actionCount: 1, focus: $focus) {
            guard matches.indices.contains(focus.row) else { return }
            model.openDefinition(matches[focus.row])
        }
    }

    /// The file and the line, as the project reads them. The project root is
    /// dropped because every candidate shares it and what tells two of them
    /// apart is the rest.
    private func place(of definition: SymbolDefinition) -> String {
        let root = project.rootPath
        let path = definition.path.hasPrefix(root)
            ? String(definition.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : HomeRelativePath.abbreviating(definition.path)
        return "\(path):\(definition.line)"
    }
}
