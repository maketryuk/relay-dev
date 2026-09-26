import Foundation
import RelayTracker

/// An issue written out for an agent's prompt.
///
/// In English whatever the window is in, like the review and the TODO
/// handovers: the labels are for the agent, and the issue's own words — its
/// summary, its description, what people said on it — go through untouched.
enum IssueTranscript {
    /// How many of the newest comments go along. A long thread is mostly
    /// history, and a prompt the agent has to wade through to find the task is
    /// a worse prompt.
    static let commentLimit = 20

    static func compose(_ issue: TrackerIssue, comments: [TrackerComment], link: URL?) -> String {
        var header = ["Issue: \(issue.key) — \(issue.summary)"]
        if let link { header.append("Link: \(link.absoluteString)") }
        for field in issue.fields {
            guard let value = written(field) else { continue }
            header.append("\(field.name): \(value)")
        }
        if !issue.tags.isEmpty {
            header.append("Tags: " + issue.tags.map(\.name).joined(separator: ", "))
        }
        var blocks = [header.joined(separator: "\n")]

        let description = issue.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            blocks.append("Description:\n\(description)")
        }

        let said = comments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !said.isEmpty {
            let shown = said.suffix(commentLimit)
            var lines = ["Comments:"]
            if said.count > shown.count {
                lines.append("(\(said.count - shown.count) earlier comments left out)")
            }
            for comment in shown {
                let author = comment.author?.name ?? "Someone"
                lines.append("\(author), \(day(comment.created)):\n\(comment.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// A card is all there is when the issue has not been read in full yet.
    static func compose(_ card: TrackerCard, link: URL?) -> String {
        compose(
            TrackerIssue(
                id: card.id,
                key: card.key,
                summary: card.summary,
                project: card.project,
                fields: card.fields,
                tags: card.tags
            ),
            comments: [],
            link: link
        )
    }

    /// What a field says, or nil when it says nothing worth passing on.
    private static func written(_ field: TrackerField) -> String? {
        switch field.kind {
        case .option, .user:
            let values = field.values.map(\.title)
            return values.isEmpty ? nil : values.joined(separator: ", ")
        case .date:
            return field.date.map(day)
        case .period, .text, .other:
            let text = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A text field can hold a page; the prompt gets the line.
            guard !text.isEmpty, !text.contains("\n") else { return nil }
            return text
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// A branch for working on the issue: its key, then as much of its summary
    /// as reads as a branch name. Letters outside ASCII are left for the key
    /// to stand in for — a branch that has to be typed in a terminal should
    /// not need a second keyboard layout.
    static func branchName(for key: String, summary: String) -> String {
        let words = summary
            .lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .prefix(6)
        var name = key
        for word in words where name.count + word.count + 1 <= 60 {
            name += "-" + word
        }
        return WorktreeNaming.branchName(from: name)
    }
}
