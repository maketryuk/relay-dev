import Foundation
import RelayProtocol

/// What has been said about the worktrees of each project: a status and a
/// comment apiece.
///
/// Filed by project as well as by path, because the only thing that says a
/// worktree has gone is its repository's list, and a list speaks for one
/// repository. Keyed by path alone, a worktree removed while Relay was not
/// running would never be seen to go, and its note would turn up on whatever
/// was made in that folder next — which Relay does for the same branch name.
struct WorktreeNotes: Equatable, Sendable {
    /// Project, then the worktree's path as git spells it.
    private(set) var byProject: [ProjectID: [String: WorktreeNote]]

    init(_ byProject: [ProjectID: [String: WorktreeNote]] = [:]) {
        self.byProject = byProject.filter { !$0.value.isEmpty }
    }

    /// From the workspace file, which keys projects by their raw identifier.
    init(persisted: [String: [String: WorktreeNote]]) {
        self.init(Dictionary(uniqueKeysWithValues: persisted.map { (ProjectID(rawValue: $0.key), $0.value) }))
    }

    var persisted: [String: [String: WorktreeNote]] {
        Dictionary(uniqueKeysWithValues: byProject.map { ($0.key.rawValue, $0.value) })
    }

    /// Two projects can be checkouts of one repository, and then both list the
    /// same worktree; what was said last is what stands.
    func note(at path: String) -> WorktreeNote? {
        byProject.values.compactMap { $0[path] }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Changes what is said about the worktree at `path`, under every project
    /// in `projects` — the ones whose list names it.
    ///
    /// Stamped only when something changed, so saying the same thing twice
    /// does not make an old note look new. A note left with nothing in it goes
    /// from every project, so that no older copy is left to show through.
    /// Returns whether anything changed.
    @discardableResult
    mutating func revise(
        at path: String,
        listedBy projects: [ProjectID],
        on date: Date = Date(),
        _ change: (inout WorktreeNote) -> Void
    ) -> Bool {
        guard !projects.isEmpty else { return false }
        let current = note(at: path)
        var revised = current ?? WorktreeNote(updatedAt: date)
        change(&revised)
        guard revised.status != current?.status || revised.comment != current?.comment else { return false }
        revised.updatedAt = date

        if revised.isEmpty {
            for project in Array(byProject.keys) {
                byProject[project]?.removeValue(forKey: path)
                if byProject[project]?.isEmpty == true { byProject.removeValue(forKey: project) }
            }
        } else {
            for project in projects {
                byProject[project, default: [:]][path] = revised
            }
        }
        return true
    }

    /// Keeps what was said about the worktrees in a fresh list of the
    /// project's, and lets go of the rest of that project's notes.
    ///
    /// An empty list is taken for a failure rather than for an answer: git
    /// always names the checkout it was asked in, and what people wrote cannot
    /// be read back from anywhere once it is dropped. Returns whether anything
    /// went.
    @discardableResult
    mutating func keep(only listed: [GitWorktree], in project: ProjectID) -> Bool {
        guard !listed.isEmpty, let notes = byProject[project] else { return false }
        let paths = Set(listed.map(\.path))
        let kept = notes.filter { paths.contains($0.key) }
        guard kept.count != notes.count else { return false }
        byProject[project] = kept.isEmpty ? nil : kept
        return true
    }

    /// A project that is removed takes what was said about its worktrees with
    /// it: no list of its will ever arrive to say which of them are gone.
    @discardableResult
    mutating func forget(_ project: ProjectID) -> Bool {
        byProject.removeValue(forKey: project) != nil
    }

    /// What a typed comment is kept as: trimmed, and nothing at all when only
    /// space was typed.
    static func comment(from typed: String?) -> String? {
        guard let trimmed = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
