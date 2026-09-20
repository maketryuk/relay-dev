import Foundation

/// The middle pane of a merge: the file as it will be committed, and what in it
/// is still in dispute.
///
/// The disputed passages are **not** marked in the text. git's markers are how
/// git hands a conflict over, not how a person reads one — `<<<<<<< HEAD` in
/// the middle of your own code is a line about a commit you did not ask about,
/// and it has to be deleted by hand before the file is worth anything. So the
/// text here is always the file: where a conflict has not been answered it
/// stands as the common ancestor, which is what both sides were before either
/// of them touched it, and what is unanswered is held beside the text as line
/// ranges rather than inside it.
///
/// Which is the whole cost of this: the ranges have to survive typing, and
/// `edited(to:)` is where that happens.
struct MergeDocument: Equatable, Sendable {
    /// One passage git could not settle, and where it currently sits.
    struct Region: Equatable, Sendable, Identifiable {
        var id: Int
        var ours: [String]
        var base: [String]
        var theirs: [String]
        /// Unanswered while this is nil, which is what Apply waits for.
        var choice: GitConflictChoice?
        /// The first line of the passage in the result.
        var start: Int
        /// How many lines of the result the passage takes up now, which is not
        /// how many either side has: it starts as the ancestor and becomes
        /// whatever was taken or typed.
        var count: Int

        var isAnswered: Bool { choice != nil }
        var end: Int { start + count }

        func lines(for choice: GitConflictChoice) -> [String] {
            switch choice {
            case .ours: ours
            case .theirs: theirs
            case .both: ours + theirs
            case .base: base
            }
        }

        /// The room the passage needs for every pane to show it at the same
        /// height, which is what keeps the three panes' lines level.
        var height: Int { max(count, max(ours.count, theirs.count)) }
    }

    /// One row of a side pane. `filler` is the empty space that keeps a
    /// passage the same height in every pane.
    enum SideRow: Equatable, Sendable {
        case line(number: Int, text: String, region: Int?)
        case filler(region: Int)

        var region: Int? {
            switch self {
            case let .line(_, _, region): region
            case let .filler(region): region
            }
        }
    }

    var lines: [String]
    var regions: [Region]

    var text: String { lines.joined(separator: "\n") }
    var isResolved: Bool { regions.allSatisfy(\.isAnswered) }
    var unanswered: Int { regions.filter { !$0.isAnswered }.count }

    /// A conflicted file as it stands when the panel opens: every
    /// non-conflicting change already applied — git's own merge did that — and
    /// every conflict standing as the ancestor of the two sides.
    static func opened(_ file: GitConflictFile) -> MergeDocument {
        var lines: [String] = []
        var regions: [Region] = []

        for segment in file.segments {
            switch segment {
            case let .settled(text):
                lines.append(contentsOf: text)
            case let .conflict(hunk):
                // No ancestor means git was never asked for one, or there is
                // none — a file both sides added. The passage is then empty
                // until a side is taken, which is honest: neither side's text
                // was there before.
                let base = hunk.base ?? []
                regions.append(Region(
                    id: hunk.id,
                    ours: hunk.ours,
                    base: base,
                    theirs: hunk.theirs,
                    choice: nil,
                    start: lines.count,
                    count: base.count
                ))
                lines.append(contentsOf: base)
            }
        }
        return MergeDocument(lines: lines, regions: regions)
    }

    func region(_ id: Int) -> Region? {
        regions.first { $0.id == id }
    }

    /// The document with one passage answered.
    ///
    /// Answering again is allowed and replaces the answer: the arrows are not
    /// one-way, because deciding a conflict is exactly where people change
    /// their minds.
    func taking(_ choice: GitConflictChoice, region id: Int) -> MergeDocument {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return self }
        let region = regions[index]
        let replacement = region.lines(for: choice)
        let delta = replacement.count - region.count

        var copy = self
        copy.lines.replaceSubrange(region.start ..< region.end, with: replacement)
        copy.regions[index].choice = choice
        copy.regions[index].count = replacement.count
        for other in copy.regions.indices where copy.regions[other].start > region.start {
            copy.regions[other].start += delta
        }
        return copy
    }

    /// The document after the text was typed into.
    ///
    /// There is nothing in the text to re-parse — that is the point of it — so
    /// the passages are followed rather than found. Typing makes one
    /// contiguous change, and the lines the old and the new text share at the
    /// front and at the back bound it: everything before is where it was,
    /// everything after moves by the difference, and a passage the change
    /// landed inside grows or shrinks with it.
    func edited(to text: String) -> MergeDocument {
        let updated = text.components(separatedBy: "\n")
        guard updated != lines else { return self }

        var prefix = 0
        while prefix < lines.count, prefix < updated.count, lines[prefix] == updated[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < lines.count - prefix,
              suffix < updated.count - prefix,
              lines[lines.count - 1 - suffix] == updated[updated.count - 1 - suffix] {
            suffix += 1
        }

        let changed = prefix ..< (lines.count - suffix)
        let delta = updated.count - lines.count

        var copy = self
        copy.lines = updated
        for index in copy.regions.indices {
            var region = copy.regions[index]
            if region.end <= changed.lowerBound {
                // Before the change: where it was.
            } else if region.start >= changed.upperBound {
                region.start += delta
            } else {
                // The change is inside the passage, or across its edge. It
                // absorbs the difference, and what it holds is no longer
                // either side as written — which is allowed, and is why an
                // arrow replaces whatever is there now rather than what was.
                let start = min(region.start, changed.lowerBound)
                let end = max(region.end, changed.upperBound) + delta
                region.start = start
                region.count = max(0, end - start)
            }
            region.start = min(max(0, region.start), updated.count)
            region.count = min(region.count, updated.count - region.start)
            copy.regions[index] = region
        }
        return copy
    }

    /// Which lines of the result are still in dispute.
    ///
    /// Only those. A passage that has been answered stops being marked
    /// anywhere — the text of it is the answer, and a file still striped with
    /// the colours of decisions already taken says nothing except that
    /// something happened here once.
    func disputed() -> Set<Int> {
        var lines = Set<Int>()
        for region in regions where !region.isAnswered {
            lines.formUnion(region.start ..< region.end)
        }
        return lines
    }

    /// How much empty room to leave above a line of the result, in lines, so
    /// that a passage shorter here than in the panes beside it does not pull
    /// everything after it out of step.
    func gaps() -> [Int: Int] {
        var gaps: [Int: Int] = [:]
        for region in regions {
            let missing = region.height - region.count
            // Nothing to hang it on past the end of the file, where trailing
            // space is invisible anyway.
            guard missing > 0, region.end < lines.count else { continue }
            gaps[region.end, default: 0] += missing
        }
        return gaps
    }

    /// One side, line by line, padded so every passage stands at the same
    /// height as it does in the result.
    ///
    /// The settled lines are the result's, not that side's own. git's merge
    /// has already applied what only one side changed, so those lines are the
    /// same in both panes — a side pane here says what this side wanted where
    /// the two disagreed, and what everyone agrees on everywhere else.
    func rows(for side: GitConflictChoice) -> [SideRow] {
        var rows: [SideRow] = []
        var number = 1
        var cursor = 0

        func settled(upTo end: Int) {
            guard cursor < end else { return }
            for index in cursor ..< end {
                rows.append(.line(number: number, text: lines[index], region: nil))
                number += 1
            }
        }

        for region in regions.sorted(by: { $0.start < $1.start }) {
            settled(upTo: region.start)
            let own = region.lines(for: side)
            for line in own {
                rows.append(.line(number: number, text: line, region: region.id))
                number += 1
            }
            for _ in own.count ..< region.height {
                rows.append(.filler(region: region.id))
            }
            cursor = region.end
        }
        settled(upTo: lines.count)
        return rows
    }
}
