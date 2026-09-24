import RelayProtocol
import RelayUI
import SwiftUI

@MainActor
extension WorktreeWorkStatus {
    var localizedName: String {
        switch self {
        case .todo: relayLocalized("To Do")
        case .inProgress: relayLocalized("In Progress")
        case .inReview: relayLocalized("In Review")
        case .completed: relayLocalized("Completed")
        }
    }

    /// What the mark says when it is pointed at or read aloud.
    var localizedDescription: String {
        String(format: relayLocalized("Status: %@"), localizedName)
    }
}

/// A worktree's status as a disc filling up inside a ring: empty to do, half
/// in progress, three quarters in review, whole once completed.
///
/// A family of shapes of its own, so it is never taken for the mark of an
/// agent on the same heading — those are a spinner, a question, a check and a
/// dot, and none of them sits in a ring. The colours are the agents' own for
/// the same meanings: blue under way, amber waiting on a person, green done.
struct WorktreeStatusMark: View {
    let status: WorktreeWorkStatus
    var size: CGFloat = 11

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint, lineWidth: ringWidth)
            // A gap as wide as the ring, or the fill runs into it and three
            // quarters cannot be told from whole at this size.
            FilledArc(fraction: fraction)
                .fill(tint)
                .padding(ringWidth * 2)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(status.localizedDescription)
    }

    private var ringWidth: CGFloat { max(1, size / 11) }

    private var fraction: Double {
        switch status {
        case .todo: 0
        case .inProgress: 0.5
        case .inReview: 0.75
        case .completed: 1
        }
    }

    private var tint: Color {
        switch status {
        case .todo: Theme.Palette.textSecondary
        case .inProgress: Theme.Palette.statusWorking
        case .inReview: Theme.Palette.statusWaiting
        case .completed: Theme.Palette.statusFinished
        }
    }
}

/// Filled clockwise from twelve o'clock, the way a clock face is read.
private struct FilledArc: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard fraction < 1 else {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            return path
        }
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// The comment under a worktree's heading: one line, cut short at the end,
/// all of it in the tooltip.
struct WorktreeCommentLine: View {
    let comment: String

    var body: some View {
        // An agent's comment can come with line breaks in it, and one line is
        // what there is room for.
        Text(verbatim: comment.split(whereSeparator: \.isNewline).joined(separator: " "))
            .font(Theme.Typography.rowSecondary)
            .foregroundStyle(Theme.Palette.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .relayTooltip(comment)
            .accessibilityLabel(String(format: relayLocalized("Comment: %@"), comment))
    }
}

extension View {
    /// Stacks a worktree's comment under its heading's row, inside what the
    /// heading draws around itself — the hover, the click that folds it, the
    /// menu — so the two lines are one heading rather than a row and a
    /// caption.
    func worktreeComment(_ comment: String?, inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            self
            if let comment {
                WorktreeCommentLine(comment: comment)
                    .padding(.leading, inset)
                    .padding(.bottom, 1)
            }
        }
    }
}

/// The comment being written, where it will be shown.
///
/// Return keeps it, Escape leaves it as it was, and keeping an empty field
/// takes the comment away.
struct WorktreeCommentEditor: View {
    @Environment(AppModel.self) private var model
    let path: String
    let onClose: () -> Void

    @State private var draft: String

    init(path: String, comment: String?, onClose: @escaping () -> Void) {
        self.path = path
        self.onClose = onClose
        _draft = State(initialValue: comment ?? "")
    }

    var body: some View {
        InlineRenameField(
            relayLocalized("Fix implemented; running tests"),
            text: $draft,
            allowsBlank: true,
            onCommit: {
                model.setWorktreeComment(draft, at: path)
                onClose()
            },
            onCancel: onClose
        )
    }
}

/// The part of a worktree heading's menu that says where the work is.
struct WorktreeNoteMenu: View {
    let model: AppModel
    let path: String
    let onEditComment: () -> Void

    var body: some View {
        let note = model.worktreeNote(at: path)

        Picker(relayLocalized("Status"), selection: Binding(
            get: { note?.status },
            set: { model.setWorktreeStatus($0, at: path) }
        )) {
            ForEach(WorktreeWorkStatus.allCases, id: \.self) { status in
                Text(status.localizedName).tag(Optional(status))
            }
            Text(relayLocalized("None")).tag(WorktreeWorkStatus?.none)
        }
        .pickerStyle(.menu)

        if note?.comment == nil {
            Button(relayLocalized("Add Comment…"), action: onEditComment)
        } else {
            Button(relayLocalized("Edit Comment…"), action: onEditComment)
            Button(relayLocalized("Clear Comment")) { model.setWorktreeComment(nil, at: path) }
        }
    }
}
