import Observation
import RelayProtocol
import RelayUI
import SwiftUI

/// What the tree is showing and what is being typed into it.
///
/// One object rather than five bindings: the tree is recursive, and every
/// level needs the open folders, the row being renamed and the row being
/// created in. Passing them one at a time meant a signature nobody could read
/// and a new one every time the menu grew.
@MainActor
@Observable
final class FileTreeState {
    /// What is being typed into the tree, and where.
    struct Editing: Equatable {
        enum Kind: Equatable {
            case rename
            case newFile
            case newFolder
        }

        let kind: Kind
        /// The file being renamed, or the folder being created in.
        let path: String
    }

    var expanded: Set<String> = []
    /// Bumped to make every open folder read itself again.
    var generation = 0
    var editing: Editing?
    var editingText = ""
    /// The entry a confirmation is being asked about.
    var pendingDelete: FileTree.Entry?

    func begin(_ kind: Editing.Kind, at path: String, name: String = "") {
        editing = Editing(kind: kind, path: path)
        editingText = name
        if kind != .rename { expanded.insert(path) }
    }

    func endEditing() {
        editing = nil
        editingText = ""
    }

    /// Read the folders again: a file has appeared, gone or changed its name.
    func reread() {
        generation += 1
    }
}

/// The project's files, for opening one.
///
/// A tree rather than a flat list because a path is how a project is
/// remembered — `Views/GitPanel.swift` is found by walking to it — and folders
/// are read when they are opened rather than at launch, so a `node_modules`
/// costs nothing until somebody asks for it.
struct FileTreePane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var state = FileTreeState()

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        FileTreeLevel(directory: project.rootPath, depth: 0, project: project, state: state)
                    }
                    .padding(.vertical, Theme.Spacing.xsmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Also when the tab is opened rather than only when the file
                // changes: a file opened while the tree was not on screen has
                // still to be found on it when it comes back.
                .task(id: model.editors.recent) { await reveal(model.editors.recent, with: proxy) }
            }
            // The empty space below the rows belongs to the project itself,
            // which is where a new file at the top level comes from.
            .contextMenu { rootMenu }
        }
        .background(Theme.Palette.sidebar)
        .confirmationDialog(
            relayLocalized("Move to Trash?"),
            isPresented: Binding(
                get: { state.pendingDelete != nil },
                set: { if !$0 { state.pendingDelete = nil } }
            ),
            presenting: state.pendingDelete
        ) { entry in
            Button(relayLocalized("Move to Trash"), role: .destructive) {
                model.deleteFile(at: entry.path, in: project.id)
                state.pendingDelete = nil
                state.reread()
            }
            Button(relayLocalized("Cancel"), role: .cancel) { state.pendingDelete = nil }
        } message: { entry in
            Text(String(format: relayLocalized("%@ goes to the Trash, where you can get it back."), entry.name))
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(verbatim: project.name)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            // Nothing watches the directory yet, so a file an agent has just
            // written appears when this is pressed. The watcher is the next
            // thing to build here, not the reason to withhold the tree.
            IconButton(systemImage: "arrow.clockwise", help: "", size: 24) {
                state.reread()
                // The names a file declares are read from the same disk, and
                // go stale the same way. So does the list of the files.
                model.symbols.invalidate(root: project.rootPath)
                model.files.invalidate(root: project.rootPath)
            }
            .relayTooltip(relayLocalized("Re-read files"))
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.small)
    }

    @ViewBuilder
    private var rootMenu: some View {
        Button(relayLocalized("New File")) { state.begin(.newFile, at: project.rootPath) }
        Button(relayLocalized("New Folder")) { state.begin(.newFolder, at: project.rootPath) }
        Divider()
        Button(relayLocalized("Reveal in Finder")) { model.revealInFinder(project) }
    }

    /// Opens every folder down to the file being worked in, and brings its row
    /// into view.
    private func reveal(_ path: String?, with proxy: ScrollViewProxy) async {
        guard let path else { return }
        state.expanded.formUnion(FileTree.ancestors(of: path, under: project.rootPath))

        // A folder's rows are read from disk when it opens, so the row to
        // scroll to does not exist in the turn that opened its folder.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(path, anchor: .center)
        }
    }
}

/// One directory's worth of rows, and the directories opened inside it.
///
/// Its own type because the recursion has to be: a function returning `some
/// View` cannot call itself, and `PaneTreeView` solves the same problem the
/// same way.
struct FileTreeLevel: View {
    @Environment(AppModel.self) private var model
    let directory: String
    let depth: Int
    let project: Project
    let state: FileTreeState

    @State private var entries: [FileTree.Entry] = []
    @State private var failure: String?

    // A real container rather than a `ForEach` or a `Group`: both of those are
    // transparent, and a modifier on them is applied to each child instead of
    // to the whole. The read below then never ran for a folder whose contents
    // had not been read yet — which is every folder — and the tree came up
    // empty. The cost is that one directory's rows are built together rather
    // than lazily, which for a directory listing is nothing.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure {
                Text(verbatim: failure)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.statusError)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, 4)
            }

            // The name being typed for something that does not exist yet,
            // at the top of the folder it will appear in.
            if let editing = state.editing, editing.path == directory, editing.kind != .rename {
                nameField(placeholder: editing.kind == .newFolder
                    ? relayLocalized("Folder name")
                    : relayLocalized("File name")) {
                    model.createFile(
                        named: state.editingText,
                        in: directory,
                        isDirectory: editing.kind == .newFolder,
                        in: project.id
                    )
                    state.endEditing()
                    state.reread()
                }
            }

            ForEach(entries) { entry in
                if state.editing == FileTreeState.Editing(kind: .rename, path: entry.path) {
                    nameField(placeholder: relayLocalized("Name")) {
                        model.renameFile(at: entry.path, to: state.editingText, in: project.id)
                        state.endEditing()
                        state.reread()
                    }
                } else {
                    FileTreeRow(
                        entry: entry,
                        depth: depth,
                        isExpanded: state.expanded.contains(entry.path),
                        isOpen: model.editors[entry.path] != nil,
                        isCurrent: model.editors.recent == entry.path,
                        isModified: model.editors[entry.path]?.isModified == true
                    ) {
                        open(entry)
                    }
                    .id(entry.path)
                    .contextMenu { menu(for: entry) }
                }

                if entry.isDirectory, state.expanded.contains(entry.path) {
                    FileTreeLevel(directory: entry.path, depth: depth + 1, project: project, state: state)
                }
            }
        }
        // Read when the folder appears and again when the tree is refreshed,
        // rather than on every redraw: this is a disk read inside a view body.
        .task(id: "\(directory)#\(state.generation)") {
            do {
                entries = try FileTree.entries(in: directory)
                failure = nil
            } catch {
                entries = []
                failure = error.localizedDescription
            }
        }
    }

    /// The order is PhpStorm's, because that is the order the hand already
    /// knows: what can be made, then what can be taken, then what changes the
    /// file itself.
    @ViewBuilder
    private func menu(for entry: FileTree.Entry) -> some View {
        Button(relayLocalized("New File")) { state.begin(.newFile, at: parent(of: entry)) }
        Button(relayLocalized("New Folder")) { state.begin(.newFolder, at: parent(of: entry)) }

        Divider()

        Button(relayLocalized("Copy Path")) { model.copyPath(of: entry.path, native: false, in: project.id) }
        Button(relayLocalized("Copy Native Path")) { model.copyPath(of: entry.path, native: true, in: project.id) }
        Button(relayLocalized("Reveal in Finder")) { model.revealInFinder(entry.path) }

        Divider()

        Button(relayLocalized("Rename")) { state.begin(.rename, at: entry.path, name: entry.name) }
        Button(relayLocalized("Delete"), role: .destructive) { state.pendingDelete = entry }
    }

    /// A new file goes in the folder that was clicked, or beside the file that
    /// was — which is what every tree does and nobody has to be told.
    private func parent(of entry: FileTree.Entry) -> String {
        entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
    }

    private func nameField(placeholder: String, onCommit: @escaping () -> Void) -> some View {
        InlineRenameField(
            placeholder,
            text: Binding(get: { state.editingText }, set: { state.editingText = $0 }),
            onCommit: onCommit,
            onCancel: { state.endEditing() }
        )
        .padding(.leading, CGFloat(depth) * 12 + Theme.Spacing.small)
        .padding(.trailing, Theme.Spacing.small)
        .padding(.vertical, 2)
    }

    private func open(_ entry: FileTree.Entry) {
        guard !entry.isDirectory else {
            if state.expanded.contains(entry.path) {
                state.expanded.remove(entry.path)
            } else {
                state.expanded.insert(entry.path)
            }
            return
        }
        model.openFile(at: entry.path, in: project.id)
    }
}

private struct FileTreeRow: View {
    let entry: FileTree.Entry
    let depth: Int
    let isExpanded: Bool
    let isOpen: Bool
    /// The one file the keyboard was last in, which is the one the tree
    /// points at. Several files can be open at once and only one of them is
    /// the one being worked on.
    let isCurrent: Bool
    let isModified: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xsmall) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(width: 10)

                Text(verbatim: entry.name)
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(isOpen ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(isCurrent ? .semibold : .regular)

                if isModified {
                    Circle()
                        .fill(Theme.Palette.statusWaiting)
                        .frame(width: 4, height: 4)
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 12 + Theme.Spacing.small)
            .padding(.trailing, Theme.Spacing.small)
            .padding(.vertical, 3)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { isHovering = $0 }
    }

    private var symbol: String {
        guard entry.isDirectory else { return "doc" }
        return isExpanded ? "chevron.down" : "chevron.right"
    }

    /// Three steps rather than two: the file being worked in, the files open
    /// beside it, and everything else. Open and current looked the same, so a
    /// tree with four files open said nothing about which one the window was
    /// actually showing.
    private var background: Color {
        if isCurrent { return Theme.Palette.accentMuted }
        if isOpen { return Theme.Palette.surfaceActive }
        return isHovering ? Theme.Palette.surfaceHover : .clear
    }
}
