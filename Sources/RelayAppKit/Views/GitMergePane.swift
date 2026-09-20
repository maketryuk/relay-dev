import RelayProtocol
import RelayUI
import SwiftUI

/// Three revisions of one file: what each side wrote, and what is going to be
/// committed.
///
/// The middle is a text editor, not a list of buttons, because the answer to a
/// conflict is often neither side as written — a line from each, or a line that
/// mentions both. Taking a side is a shortcut for an edit, and the edit is
/// always available.
///
/// What it does not have is git's markers. The result is the file: a passage
/// nobody has answered yet stands there as the ancestor both sides started
/// from, and what is unanswered is held in `MergeDocument` beside the text
/// rather than spelled out in it.
struct GitMergePane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let path: String

    /// The one size everything here is laid out at. The side panes are SwiftUI
    /// and the middle is a text view, so nothing makes their rows the same
    /// height except saying so.
    private static let fontSize: CGFloat = 12.5
    /// Room under every line, in both kinds of pane. It is also what gives the
    /// gutter the height to put a glyph worth seeing in.
    private static let lineSpacing: CGFloat = 4
    private static var rowHeight: CGFloat {
        CodeTextView.pitch(fontSize: fontSize, lineSpacing: lineSpacing)
    }
    /// The room the editor leaves above its first line, matched by the panes so
    /// that line one is level in all three.
    private static let topInset: CGFloat = 6

    /// The file as it will be committed, and what in it is still in dispute.
    @State private var document = MergeDocument(lines: [], regions: [])
    /// The editor's own copy. Edits travel from here into the document, which
    /// follows its passages through them; the arrows travel the other way.
    @State private var text = ""
    @State private var isLoaded = false

    private var original: GitConflictFile? { model.conflict(path, in: project.id) }
    private var operation: GitMergeState.Operation? { model.mergeState(in: project.id).operation }

    var body: some View {
        ModalSurface(path, onDismiss: { model.dismissModal() }) {
            VStack(spacing: 0) {
                if !isLoaded {
                    // Only ever seen if the panel is reached with nothing
                    // loaded: the model reads the file before opening it.
                    EmptyStateView(
                        systemImage: "doc.text",
                        title: relayLocalized("Reading…"),
                        message: ""
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    toolbar
                    RelayDivider()
                    panes
                }
            }
        } footer: {
            footer
        }
        // The model reads the file, so the first frame this panel draws
        // already has it: a panel that fills in a moment after it opens cannot
        // be told apart from a broken one.
        .onChange(of: original, initial: true) { _, file in
            guard !isLoaded, let file, file.hasConflicts else { return }
            document = MergeDocument.opened(file)
            text = document.text
            isLoaded = true
        }
        // Typing. The document follows its passages through the change rather
        // than looking for markers, since there are none to look for.
        .onChange(of: text) { _, typed in
            guard isLoaded, typed != document.text else { return }
            document = document.edited(to: typed)
        }
        .task {
            // Belt and braces: the panel can be reached with nothing loaded —
            // reopened after a reload, say — and then it asks for itself.
            guard model.conflict(path, in: project.id) == nil else { return }
            model.loadConflict(path, in: project.id)
        }
    }

    // MARK: - What is left to settle

    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(status)
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(document.isResolved ? Theme.Palette.statusFinished : Theme.Palette.statusWaiting)
            Spacer(minLength: Theme.Spacing.small)
        }
        .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
        .padding(.vertical, Theme.Spacing.small)
    }

    private var status: String {
        guard !document.isResolved else { return relayLocalized("Nothing left in dispute") }
        return String(format: relayLocalized("Conflicts left: %d"), document.unanswered)
    }

    /// Answers one passage, and puts the result in front of the editor.
    private func take(_ choice: GitConflictChoice, region id: Int) {
        document = document.taking(choice, region: id)
        text = document.text
    }

    private func takeAll(_ choice: GitConflictChoice) {
        for region in document.regions {
            document = document.taking(choice, region: region.id)
        }
        text = document.text
    }

    // MARK: - The three revisions

    private var panes: some View {
        HStack(spacing: 0) {
            revision(
                title: GitMergeNaming.ours(operation: operation, label: ourLabel),
                tint: Theme.Palette.statusError,
                side: .ours,
                glyph: "chevron.right.2",
                help: relayLocalized("Take left")
            )
            RelayDivider(axis: .vertical)
            editor
            RelayDivider(axis: .vertical)
            revision(
                title: GitMergeNaming.theirs(operation: operation, label: theirLabel),
                tint: Theme.Palette.statusFinished,
                side: .theirs,
                glyph: "chevron.left.2",
                help: relayLocalized("Take right")
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ourLabel: String { original?.hunks.first?.ourLabel ?? "" }
    private var theirLabel: String { original?.hunks.first?.theirLabel ?? "" }

    /// One side, read-only, drawn by SwiftUI.
    ///
    /// Not a text view: three of those side by side are three AppKit views
    /// inside one SwiftUI layout, and SwiftUI gives each its own full-size
    /// compositing layer — the later ones covered the earlier ones, so two of
    /// the three panes were simply not on screen. Nothing here needs editing,
    /// and drawing it ourselves is what lets a button stand in the gutter
    /// beside the lines it would take.
    private func revision(
        title: String,
        tint: Color,
        side: GitConflictChoice,
        glyph: String,
        help: String
    ) -> some View {
        let rows = document.rows(for: side)
        // Only the first row of a passage carries the buttons: one pair per
        // conflict, not one per line of it.
        var heads = Set<Int>()
        var seen = Set<Int>()
        for (index, row) in rows.enumerated() {
            guard let region = row.region, !seen.contains(region) else { continue }
            seen.insert(region)
            heads.insert(index)
        }

        return VStack(spacing: 0) {
            paneHeader(title, tint: tint)
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    // Not lazy, deliberately. A `LazyVStack` here — inside a
                    // scroll view with both axes, inside a geometry reader —
                    // left the last of the three panes empty: nothing was
                    // laid out in it at all. The pixel test is what caught it,
                    // since the view tree was perfectly correct.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            line(
                                row,
                                isHead: heads.contains(index),
                                width: geometry.size.width,
                                tint: tint,
                                side: side,
                                glyph: glyph,
                                help: help
                            )
                        }
                    }
                    .padding(.top, Self.topInset)
                }
                .defaultScrollAnchor(.topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Theme.Palette.base)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func line(
        _ row: MergeDocument.SideRow,
        isHead: Bool,
        width: CGFloat,
        tint: Color,
        side: GitConflictChoice,
        glyph: String,
        help: String
    ) -> some View {
        let region = row.region.flatMap { document.region($0) }
        let isAnswered = region?.isAnswered ?? false
        let isDisputed = region != nil && !isAnswered

        return HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 2) {
                // Only while the passage is still in question. Answered, it is
                // part of the file like anything else, and a row that keeps
                // its arrows keeps asking a question that has been settled.
                if let region, isHead, !isAnswered {
                    gutterButton(glyph, help: help, tint: tint) {
                        take(side, region: region.id)
                    }
                    gutterButton("xmark", help: relayLocalized("Ignore"), tint: nil) {
                        take(.base, region: region.id)
                    }
                }
            }
            .frame(width: 42, alignment: .leading)

            Text(verbatim: number(of: row))
                .font(Self.mono)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 30, alignment: .trailing)
                .padding(.trailing, 8)

            Text(verbatim: text(of: row))
                .font(Self.mono)
                .foregroundStyle(Theme.Palette.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(height: Self.rowHeight)
        // Given to the row rather than to the column around it. A scroll view
        // that scrolls sideways proposes no width at all, so `.infinity` there
        // means "as wide as you like" and the row settles on its own text —
        // and a band marking a conflict stopped wherever that line ended.
        .frame(minWidth: width, alignment: .leading)
        .background(isDisputed ? tint.opacity(0.16) : Color.clear)
    }

    /// A button the height of a line of text.
    ///
    /// Its own rather than `IconButton`, whose glyph is a fraction of its box:
    /// the box here cannot be taller than the row it stands in, so the glyph
    /// has to be sized against the row instead of against the button.
    private func gutterButton(
        _ systemImage: String,
        help: String,
        tint: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? Theme.Palette.textSecondary)
                .frame(width: 18, height: Self.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .relayTooltip(help, edge: .top)
    }

    /// The editor's font, so the two kinds of pane are set in one typeface at
    /// one size and a line in either is the same height.
    private static let mono = Font.system(size: fontSize, weight: .regular, design: .monospaced)

    private func number(of row: MergeDocument.SideRow) -> String {
        switch row {
        case let .line(number, _, _): "\(number)"
        case .filler: ""
        }
    }

    private func text(of row: MergeDocument.SideRow) -> String {
        switch row {
        case let .line(_, text, _): text.isEmpty ? " " : text
        // The empty room that keeps this passage the same height as it is in
        // the panes beside it.
        case .filler: " "
        }
    }

    /// The middle: the one pane that is typed into, and so the one AppKit view
    /// in the panel.
    private var editor: some View {
        VStack(spacing: 0) {
            paneHeader(relayLocalized("Result"), tint: Theme.Palette.accent)
            CodeTextView(
                text: $text,
                isEditable: true,
                tints: tints,
                fontSize: Self.fontSize,
                lineSpacing: Self.lineSpacing,
                gaps: document.gaps(),
                language: SourceLanguage.detect(path: path, contents: text)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .relayPointer(.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the result's own lines are tinted with: amber where nobody has
    /// answered yet, and nothing anywhere else.
    private var tints: [Int: Color] {
        Dictionary(
            uniqueKeysWithValues: document.disputed().map {
                ($0, Theme.Palette.statusWaiting.opacity(0.16))
            }
        )
    }

    private func paneHeader(_ title: String, tint: Color) -> some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            Text(verbatim: title)
                .font(Theme.Typography.caption)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 5)
        .background(Theme.Palette.sidebar)
        .relayTooltip(title, edge: .bottom)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.small) {
            RelayButton(relayLocalized("Accept left")) { takeAll(.ours) }
            RelayButton(relayLocalized("Accept right")) { takeAll(.theirs) }

            Spacer(minLength: Theme.Spacing.small)

            RelayButton(relayLocalized("Cancel")) { model.dismissModal() }
            RelayButton(
                relayLocalized("Apply"),
                kind: document.isResolved ? .primary : .secondary
            ) {
                model.applyMerge(text, to: path, in: project.id)
            }
            .disabled(!document.isResolved)
            .opacity(document.isResolved ? 1 : 0.5)
            .relayTooltip(
                document.isResolved
                    ? relayLocalized("Writes the file and stages it")
                    : relayLocalized("Every conflict has to be answered first"),
                edge: .top
            )
        }
    }
}
