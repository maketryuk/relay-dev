import RelayProtocol
import RelayUI
import SwiftUI

/// Everywhere a word appears in the project's files.
///
/// Laid out the way every find-in-files is: the query and its switches at the
/// top, the matching lines under it with the file each came from on the
/// right, and the file itself below — because the line alone rarely settles
/// whether it is the one that was meant, and opening each candidate to find
/// out is the thing this panel exists to avoid.
struct SearchPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var focus = ListFocus()
    @State private var preview: String?
    @State private var previewID = UUID()

    private var hits: [TextHit] { model.searchHits }
    private var selected: TextHit? { hits.indices.contains(focus.row) ? hits[focus.row] : nil }

    var body: some View {
        VStack(spacing: 0) {
            field
            RelayDivider()
            results
            if let selected {
                RelayDivider()
                previewPane(of: selected)
            }
        }
        .keyboardNavigableList(rowCount: hits.count, actionCount: 1, focus: $focus) {
            if let selected { model.open(selected, in: project.id) }
        }
        .onChange(of: model.searchQuery) { _, _ in restart() }
        .onChange(of: model.searchOptions) { _, _ in restart() }
        // A panel reopened on the same search shows it rather than a blank
        // page: the answer is still true, and running it again to say the
        // same thing is a wait for nothing.
        .task { if hits.isEmpty { model.search(in: project.id) } }
        .task(id: selected?.id) { await loadPreview() }
    }

    private var field: some View {
        HStack(spacing: Theme.Spacing.small) {
            RelayTextField(
                relayLocalized("Search in files"),
                text: Bindable(model).searchQuery,
                systemImage: "magnifyingglass",
                autofocus: true
            ) {
                if let selected { model.open(selected, in: project.id) }
            }

            toggle("Cc", help: relayLocalized("Match case"), isOn: model.searchOptions.isCaseSensitive) {
                model.searchOptions.isCaseSensitive.toggle()
            }
            toggle("W", help: relayLocalized("Whole words"), isOn: model.searchOptions.matchesWholeWords) {
                model.searchOptions.matchesWholeWords.toggle()
            }
            toggle(".*", help: relayLocalized("Regular expression"), isOn: model.searchOptions.isRegularExpression) {
                model.searchOptions.isRegularExpression.toggle()
            }
        }
        // The panel's own insets: the field sat against the title bar,
        // because a modal's body starts where the header stops.
        .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private func toggle(_ label: String, help: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                .frame(width: 24, height: 22)
                .background(isOn ? Theme.Palette.accentMuted : .clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .relayTooltip(help)
    }

    @ViewBuilder
    private var results: some View {
        if hits.isEmpty {
            EmptyStateView(
                systemImage: model.isSearching ? "ellipsis" : "magnifyingglass",
                title: model.isSearching ? relayLocalized("Searching…") : relayLocalized("No matches"),
                message: model.isSearching
                    ? ""
                    : relayLocalized("Two letters or more, and only the project's own files.")
            )
            .frame(maxHeight: .infinity)
        } else {
            KeyboardScrollingList(
                focusedRow: focus.row,
                identifyingRow: { hits.indices.contains($0) ? hits[$0].id : nil }
            ) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        row(hit, isFocused: index == focus.row)
                    }
                    if model.searchWasTruncated {
                        Text(String(format: relayLocalized("First %d matches"), hits.count))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .padding(Theme.Spacing.small)
                    }
                }
                .padding(Theme.Spacing.small)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ hit: TextHit, isFocused: Bool) -> some View {
        Button {
            focus.row = hits.firstIndex { $0.id == hit.id } ?? focus.row
            model.open(hit, in: project.id)
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Text(marked(hit))
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: Theme.Spacing.small)

                Text(verbatim: "\((hit.path as NSString).lastPathComponent) \(hit.line)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 3)
            .background(isFocused ? Theme.Palette.surfaceActive : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .id(hit.id)
    }

    /// The file the highlighted line is in, at the line.
    private func previewPane(of hit: TextHit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.small) {
                Text(verbatim: (hit.path as NSString).lastPathComponent)
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(verbatim: FileMatching.relative(
                    (hit.path as NSString).deletingLastPathComponent,
                    to: model.workingRoot(of: project.id) ?? project.rootPath
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 6)

            if let preview {
                CodeTextView(
                    text: .constant(preview),
                    isEditable: false,
                    fontSize: 11.5,
                    language: SourceLanguage.detect(path: hit.path, contents: preview),
                    reveal: OpenFile.Reveal(id: previewID, range: hit.range)
                )
                .relayPointer(.text)
            } else {
                Color.clear
            }
        }
        .frame(height: 260)
        .background(Theme.Palette.base)
    }

    /// The line with the match picked out, which is the whole point of showing
    /// the line rather than the file name alone.
    private func marked(_ hit: TextHit) -> AttributedString {
        var line = AttributedString(hit.text)
        line.foregroundColor = Theme.Palette.textSecondary

        guard let range = Range(hit.inLine, in: hit.text),
              let lower = AttributedString.Index(range.lowerBound, within: line),
              let upper = AttributedString.Index(range.upperBound, within: line)
        else { return line }

        line[lower ..< upper].foregroundColor = Theme.Palette.textPrimary
        line[lower ..< upper].backgroundColor = Theme.Palette.accentMuted
        return line
    }

    private func restart() {
        focus = ListFocus()
        model.search(in: project.id)
    }

    /// Read from the buffer when the file is open, so what is previewed is
    /// what is on screen rather than what was on disk before the last edit.
    private func loadPreview() async {
        guard let hit = selected else {
            preview = nil
            return
        }
        if let open = model.editors[hit.path] {
            preview = open.text
        } else {
            let path = hit.path
            preview = await Task.detached(priority: .userInitiated) {
                try? String(contentsOfFile: path, encoding: .utf8)
            }.value
        }
        previewID = UUID()
    }
}
