import Foundation

/// A branch as the switcher needs to show it.
struct GitBranch: Identifiable, Equatable, Sendable {
    /// Short name: `main` locally, `origin/main` on a remote.
    var name: String
    var isRemote: Bool
    var isCurrent: Bool
    /// What a local branch follows, when it follows anything.
    var upstream: String?

    var id: String { (isRemote ? "remote:" : "local:") + name }

    /// What `git switch` is given.
    ///
    /// A remote branch is switched to by its bare name: git then creates the
    /// local branch that follows it, which is what picking `origin/feature`
    /// from a list is understood to mean.
    var switchName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

/// Reads `git for-each-ref` over heads and remotes in one call.
///
/// The full ref name is asked for alongside the short one, because only the
/// full one says what a ref *is*: `refs/remotes/origin/HEAD` shortens to plain
/// `origin`, which reads as a local branch of that name and is not a branch at
/// all.
enum GitBranchParser {
    static let format = "%(refname)\t%(refname:short)\t%(HEAD)\t%(upstream:short)\t%(symref)"

    static func parse(_ output: String) -> [GitBranch] {
        var branches: [GitBranch] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let ref = String(fields[0])
            let name = String(fields[1])
            guard !name.isEmpty else { continue }

            // A symbolic ref is a pointer to a branch, not one: `origin/HEAD`
            // is how a remote says which branch it defaults to.
            let symref = fields.count > 4 ? String(fields[4]) : ""
            guard symref.isEmpty else { continue }

            let isRemote = ref.hasPrefix("refs/remotes/")
            guard isRemote || ref.hasPrefix("refs/heads/") else { continue }

            let upstream = fields.count > 3 ? String(fields[3]) : ""
            branches.append(GitBranch(
                name: name,
                isRemote: isRemote,
                isCurrent: (fields.count > 2 ? String(fields[2]) : "") == "*",
                upstream: upstream.isEmpty ? nil : upstream
            ))
        }

        // A remote branch that is already checked out locally is the same
        // branch twice in a list of places to go.
        let tracked = Set(branches.compactMap(\.upstream))
        return branches.filter { !($0.isRemote && tracked.contains($0.name)) }
    }
}
