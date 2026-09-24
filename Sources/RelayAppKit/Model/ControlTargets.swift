import Foundation
import RelayProtocol

/// What a `relay` command is about, worked out from where it was run.
///
/// Pure, so the rules can be read and tested apart from an app: a project is
/// the terminal's own, or else the one whose folder or worktrees hold the
/// directory; a worktree is the one named, or else the one the directory is in.
enum ControlTargets {
    /// The session's project when there is one; otherwise the project with the
    /// deepest root holding the directory, a worktree's folder counting as its
    /// project's.
    ///
    /// Git spells its worktrees with their symlinks followed, and so does
    /// `getcwd`; a project added through a link is spelled the way it was
    /// added. Both spellings of each are tried, so neither misses the other.
    static func project(
        sessionProject: ProjectID?,
        directory: String,
        projects: [Project],
        worktrees: [ProjectID: [GitWorktree]],
        canonical: (String) -> String = WorktreeMembership.canonical
    ) -> ProjectID? {
        if let sessionProject, projects.contains(where: { $0.id == sessionProject }) { return sessionProject }
        var roots: [(path: String, project: ProjectID)] = []
        for project in projects {
            roots.append((project.rootPath, project.id))
            roots.append((canonical(project.rootPath), project.id))
            roots += (worktrees[project.id] ?? []).map { ($0.path, project.id) }
        }
        let spellings = Set([directory, canonical(directory)])
        return roots
            .filter { root in spellings.contains { DirectoryContainment.contains($0, in: root.path) } }
            .max { $0.path.count < $1.path.count }?
            .project
    }

    /// The worktree `target` names, or the one `directory` is in when it names none.
    ///
    /// A path — anything starting with `/`, `~` or `.` — has to be a
    /// worktree's own folder: `rm src` run inside a worktree must not remove
    /// the worktree `src` is in. Anything else is a branch, or failing that a
    /// folder name, which two worktrees can share.
    static func worktree(
        _ target: String?,
        from directory: String,
        among worktrees: [GitWorktree],
        canonical: (String) -> String = WorktreeMembership.canonical
    ) -> Result<GitWorktree, ControlFailure> {
        guard let target else {
            guard let current = WorktreeMembership.worktree(containing: directory, among: worktrees) else {
                return .failure(ControlFailure(
                    .notInWorktree,
                    "\(directory) is in none of the project's worktrees. Name one, or run relay worktree list."
                ))
            }
            return .success(current)
        }

        if ["/", "~", "."].contains(where: target.hasPrefix) {
            let expanded = (target as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/")
                ? expanded
                : URL(fileURLWithPath: directory).appendingPathComponent(expanded).path
            let standardised = URL(fileURLWithPath: absolute).standardizedFileURL.path
            let spellings = Set([standardised, canonical(standardised)])
            guard let match = worktrees.first(where: { spellings.contains($0.path) }) else {
                return .failure(ControlFailure(
                    .noSuchWorktree,
                    "No worktree of the project is at \(standardised). Run relay worktree list to see them."
                ))
            }
            return .success(match)
        }

        if let byBranch = worktrees.first(where: { $0.branch == target }) { return .success(byBranch) }
        let byFolder = worktrees.filter { URL(fileURLWithPath: $0.path).lastPathComponent == target }
        switch byFolder.count {
        case 1:
            return .success(byFolder[0])
        case 0:
            return .failure(ControlFailure(
                .noSuchWorktree,
                "No worktree of the project is called \(target). Run relay worktree list to see them."
            ))
        default:
            return .failure(ControlFailure(
                .ambiguousWorktree,
                "\(target) is the folder of more than one worktree: "
                    + byFolder.map(\.path).joined(separator: ", ") + ". Name it by its path."
            ))
        }
    }

    /// The preset `--agent` names: one called that, whatever the case, or else
    /// the first of the kind it names — so `claude` finds Claude whatever the
    /// Claude preset has been renamed to, and `gemini` starts Gemini with no
    /// preset for it at all.
    ///
    /// A custom preset with nothing to run is passed over, as New Worktree
    /// passes it over.
    static func preset(named query: String, in presets: [SessionPreset]) -> SessionPreset? {
        let wanted = query.trimmingCharacters(in: .whitespaces).lowercased()
        let runnable = presets.filter { $0.kind != .custom || !($0.customCommand ?? "").isEmpty }
        if let named = runnable.first(where: { $0.name.lowercased() == wanted }) { return named }
        let startable = SessionKind.allCases.filter { $0.isAgent || $0 == .shell }
        guard let kind = startable.first(where: { $0.rawValue == wanted || $0.displayName.lowercased() == wanted })
        else { return nil }
        return SessionPresets.preferred(for: kind, in: runnable)
    }
}
