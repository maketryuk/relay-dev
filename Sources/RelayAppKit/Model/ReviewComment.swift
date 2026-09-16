import Foundation
import RelayProtocol

/// A remark on one line of a diff.
///
/// The point of writing one here rather than in the terminal is that the line
/// it belongs to comes with it: an agent given "this is wrong" has to guess,
/// and an agent given the file, the line number and the line itself does not.
struct ReviewComment: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    /// Which project's working copy it was written on. Notes are kept on disk
    /// and a window shows one project at a time; without this they would all
    /// pile into whichever project happened to be open.
    var projectID: ProjectID
    var path: String
    /// The line as numbered in the working copy, when it exists there — a
    /// deleted line has no number on that side and is quoted instead.
    var line: Int?
    /// What the line says, kept so the remark survives the file changing under
    /// it: by the time an agent reads this, the numbers may have moved.
    var code: String
    var text: String

    init(id: UUID = UUID(), projectID: ProjectID, path: String, line: Int?, code: String, text: String) {
        self.id = id
        self.projectID = projectID
        self.path = path
        self.line = line
        self.code = code
        self.text = text
    }
}

/// Turns a set of remarks into something worth pasting into an agent's prompt.
///
/// One block per remark, each naming its file again: an agent reading this has
/// to be able to act on any one line of it without holding the rest in its
/// head, and a block that says only "line 64" belongs to whichever file was
/// mentioned last — which is how a remark ends up applied to the wrong one.
///
/// Ordered by file and then by line, because that is the order the work has to
/// be done in.
enum ReviewCommentTranscript {
    static func compose(_ comments: [ReviewComment]) -> String {
        let ordered = comments.sorted {
            $0.path == $1.path ? ($0.line ?? 0) < ($1.line ?? 0) : $0.path < $1.path
        }
        return ordered.map(block(for:)).joined(separator: "\n\n")
    }

    /// Flush left, because a terminal prompt indents what is typed into it and
    /// a second indent on top of that reads as formatting that went wrong.
    private static func block(for comment: ReviewComment) -> String {
        var lines = ["File: \(comment.path)"]
        if let line = comment.line {
            lines.append("Line: \(line)")
        }
        lines.append("User comment: \"\(comment.text)\"")
        return lines.joined(separator: "\n")
    }
}
