import RelayProtocol
import RelayUI
import SwiftUI

/// A file open beside the terminals.
///
/// Deliberately not a document window: no tabs of its own, no toolbar, no
/// status bar. A pane shows one file, and the arrangement of panes is the
/// arrangement of the work — which is the same thing a split terminal is for.
struct FilePane: View {
    @Environment(AppModel.self) private var model
    let path: String
    let projectID: ProjectID

    /// True while a name under the pointer is drawn as a link.
    @State private var isLinking = false

    /// The find bar, which belongs to the pane rather than to the file: two
    /// panes on one file are two people looking for two different things.
    @State private var isFinding = false
    @State private var findQuery = ""
    @State private var found = CodeTextView.FindMatches()
    @FocusState private var isFindFocused: Bool

    private var file: OpenFile? { model.editors[path] }
    private var isFocused: Bool { model.editors.focused == path }

    var body: some View {
        if let file {
            VStack(spacing: 0) {
                header(file)
                RelayDivider()

                if isFinding {
                    findBar(file)
                    RelayDivider()
                }

                if !model.diagnostics.isEmpty {
                    RelayDivider()
                    problemBar(file)
                }

                CodeTextView(
                    text: Binding(get: { file.text }, set: { file.text = $0 }),
                    isEditable: !file.isVendored,
                    fontSize: CGFloat(model.editorFontSize),
                    language: file.language,
                    onFocus: { model.focusFile(at: path, caret: $0) },
                    onCommandClick: { model.goToDefinition(at: $0, in: path, projectID: projectID) },
                    onLink: { isLinking = $0 },
                    reveal: file.reveal,
                    find: isFinding && !found.isEmpty ? found : nil,
                    occurrences: file.occurrences,
                    problems: problems(in: file)
                )
                // The underline says the name can be clicked; so should the
                // pointer, which is the half of that promise a hand reaches
                // for first.
                .relayPointer(isLinking ? .clickable : .text)
            }
            .background(Theme.Palette.base)
            // Only the pane being worked in answers ⌘F; the others are not
            // where the person pressing it is looking.
            .onChange(of: model.findRequest) { _, _ in
                guard model.editors.focused == path else { return }
                isFinding = true
                isFindFocused = true
                refreshMatches(file)
            }
            .onChange(of: findQuery) { _, _ in refreshMatches(file) }
            .onChange(of: file.text) { _, _ in
                if isFinding { refreshMatches(file) }
                model.checkOpenFile(in: projectID)
            }
            // On opening, and again whenever the file is written out: the
            // checker reads the buffer, so a save is not what it waits for —
            // but a save is when it is worth being sure.
            .task(id: path) { model.checkOpenFile(in: projectID, immediately: true) }
            .onChange(of: file.isModified) { _, isModified in
                if !isModified { model.checkOpenFile(in: projectID, immediately: true) }
            }
        } else {
            EmptyStateView(
                systemImage: "doc.text",
                title: relayLocalized("File unavailable"),
                message: relayLocalized("This file could not be read from disk.")
            )
            .background(Theme.Palette.base)
        }
    }

    private func header(_ file: OpenFile) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            // One slot, two things to say. A saved file shows what it is; a
            // file with unsaved work shows the dot every editor uses for it,
            // which is rarely up for long — leaving the pane writes the file
            // — but the moment between typing and leaving is exactly when a
            // person wants to be sure. An empty slot, which is what an
            // invisible dot left behind, reads as a gap nobody meant.
            ZStack {
                if file.isModified {
                    Circle()
                        .fill(Theme.Palette.statusWaiting)
                        .frame(width: 6, height: 6)
                } else {
                    Image(systemName: file.isVendored ? "lock.doc" : "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .frame(width: 14)

            Text(verbatim: file.name)
                .font(Theme.Typography.row)
                .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)

            Text(verbatim: relativePath)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: Theme.Spacing.small)

            // Said rather than left to be discovered by typing into it and
            // watching nothing happen.
            if file.isVendored {
                Text(verbatim: relayLocalized("Read-only"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            if let failure = file.failure {
                Text(verbatim: failure)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.statusError)
                    .lineLimit(1)
            }

            IconButton(systemImage: "xmark", help: "", size: 20) {
                model.closeFile(at: path, in: projectID)
            }
            .relayTooltip(relayLocalized("Close File"), shortcut: model.binding(for: .closeSession))
        }
        .padding(.horizontal, Theme.Spacing.small)
        .frame(height: Theme.Metrics.contextBarHeight + 4)
        .background(Theme.Palette.sidebar)
        .contentShape(Rectangle())
        .onTapGesture { model.focusFile(at: path) }
    }

    /// A field at the top of the pane, the way every editor puts it.
    private func findBar(_ file: OpenFile) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textTertiary)

            TextField(relayLocalized("Find"), text: $findQuery)
                .textFieldStyle(.plain)
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($isFindFocused)
                // Return walks forward and ⇧Return back, which is what the
                // key does in every find bar; Escape gives the file back.
                .onKeyPress(keys: [.return], phases: .down) { press in
                    step(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }

            Text(verbatim: found.counter(for: findQuery))
                .font(Theme.Typography.caption)
                .foregroundStyle(found.isEmpty && !findQuery.isEmpty
                    ? Theme.Palette.statusError
                    : Theme.Palette.textTertiary)
                .monospacedDigit()

            IconButton(systemImage: "chevron.up", help: "", size: 20) { step(-1) }
                .disabled(found.isEmpty)
            IconButton(systemImage: "chevron.down", help: "", size: 20) { step(1) }
                .disabled(found.isEmpty)
            IconButton(systemImage: "xmark", help: "", size: 20) { endFind() }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 5)
        .background(Theme.Palette.sidebar)
        // Escape is taken at the window: a text field swallows it before
        // SwiftUI sees it, which is why `onKeyPress` was never called. Only
        // while this pane has the keyboard, though — Escape belongs to the
        // terminal when the terminal is what somebody is typing in, and vim
        // would never see it again.
        .background {
            KeyCaptureView(onEscape: hasTheKeyboard ? { endFind() } : nil)
        }
    }

    /// What the checker said, where it said it.
    private func problems(in file: OpenFile) -> [CodeTextView.Problem] {
        model.diagnostics.compactMap { diagnostic in
            guard let range = diagnostic.range(in: file.text) else { return nil }
            let rule = diagnostic.rule.map { " (\($0))" } ?? ""
            return CodeTextView.Problem(
                range: range,
                isError: diagnostic.severity == .error,
                message: diagnostic.message + rule
            )
        }
    }

    /// The strip under the header: how many there are, and what the one the
    /// caret is nearest says.
    private func problemBar(_ file: OpenFile) -> some View {
        let errors = model.diagnostics.filter { $0.severity == .error }.count
        let warnings = model.diagnostics.count - errors
        let shown = nearestProblem(to: file.caret, in: file)

        return HStack(spacing: Theme.Spacing.small) {
            if errors > 0 {
                count("xmark.octagon.fill", errors, tint: Theme.Palette.statusError)
            }
            if warnings > 0 {
                count("exclamationmark.triangle.fill", warnings, tint: Theme.Palette.statusWaiting)
            }

            if let shown {
                Text(verbatim: shown.message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let rule = shown.rule {
                    Text(verbatim: rule)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            if let name = model.checkerName {
                Text(verbatim: name)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 4)
        .background(Theme.Palette.sidebar)
        .contentShape(Rectangle())
        .onTapGesture { goToNextProblem(in: file) }
        .clickable()
        .relayTooltip(relayLocalized("Go to the next problem"))
    }

    private func count(_ symbol: String, _ number: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(tint)
            Text(verbatim: "\(number)")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .monospacedDigit()
        }
    }

    /// The problem on the caret's line, or the first one after it.
    private func nearestProblem(to caret: Int, in file: OpenFile) -> Diagnostic? {
        let sorted = model.diagnostics.sorted { $0.line < $1.line }
        guard let line = line(of: caret, in: file.text) else { return sorted.first }
        return sorted.first { $0.line == line } ?? sorted.first { $0.line > line } ?? sorted.first
    }

    private func goToNextProblem(in file: OpenFile) {
        let sorted = model.diagnostics.sorted { $0.line < $1.line }
        guard !sorted.isEmpty else { return }
        let line = line(of: file.caret, in: file.text) ?? 0
        let next = sorted.first { $0.line > line } ?? sorted[0]
        guard let range = next.range(in: file.text) else { return }
        file.jump(to: range)
    }

    private func line(of offset: Int, in text: String) -> Int? {
        let source = text as NSString
        guard offset >= 0, offset <= source.length else { return nil }
        var start = 0
        var number = 1
        while start < offset, start < source.length {
            let range = source.lineRange(for: NSRange(location: start, length: 0))
            let next = NSMaxRange(range)
            guard next > start, next <= offset else { break }
            start = next
            number += 1
        }
        return number
    }

    /// Whether Escape is this pane's to take.
    private var hasTheKeyboard: Bool {
        isFindFocused || model.editors.focused == path
    }

    private func refreshMatches(_ file: OpenFile) {
        found = CodeTextView.FindMatches(ranges: TextSearch.ranges(of: findQuery, in: file.text), current: 0)
    }

    private func step(_ direction: Int) {
        found = found.stepped(direction)
    }

    private func endFind() {
        isFinding = false
        isFindFocused = false
        findQuery = ""
        found = CodeTextView.FindMatches()
    }

    /// The path as it reads inside the project, since the project name is
    /// already on the rail and the home directory is nobody's news.
    private var relativePath: String {
        guard let root = model.project(projectID)?.rootPath else { return path }
        let directory = (path as NSString).deletingLastPathComponent
        guard directory.hasPrefix(root) else {
            return HomeRelativePath.abbreviating(directory)
        }
        let trimmed = String(directory.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "" : trimmed
    }
}
