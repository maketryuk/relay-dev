import Foundation
import OSLog
import RelayProtocol

/// The app's half of the `relay` command.
///
/// Each request is carried out by the functions the sidebar and New Worktree
/// call, on the model they change, so what a command does is what the window
/// shows — there is no second account of a worktree to fall out of step.
extension AppModel {
    /// One per process: there is one socket to listen on.
    private static var controlServer: ControlServer?
    private static let controlLog = Logger(subsystem: "com.maketryuk.relay", category: "control")

    func startControlServer() {
        guard Self.controlServer == nil else { return }
        let url = RelayPaths.controlSocketURL(beside: RelayPaths.socketURL)
        let server = ControlServer(socketURL: url) { [weak self] request in
            guard let self else { return .failure(ControlFailure(.refused, "Relay is closing.")) }
            return await self.handleControl(request)
        }
        do {
            try server.start()
            Self.controlServer = server
        } catch {
            // The command then says Relay is not running, which for this copy
            // of it is near enough the truth.
            Self.controlLog.error("control socket unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    func handleControl(_ request: ControlRequest) async -> ControlResponse {
        let scope: (project: Project, worktrees: [GitWorktree])
        switch await controlScope(for: request) {
        case let .failure(failure): return .failure(failure)
        case let .success(found): scope = found
        }
        let (project, listed) = scope
        let current = WorktreeMembership.worktree(containing: request.directory, among: listed)

        switch request.command {
        case .worktreeList:
            return ControlResponse(
                project: controlProject(project),
                worktrees: listed.map { controlWorktree($0, in: project, current: current) }
            )

        case .worktreeCurrent:
            return target(nil, from: request.directory, among: listed) { worktree in
                ControlResponse(project: controlProject(project), worktree: controlWorktree(worktree, in: project, current: current))
            }

        case let .worktreeCreate(name, base, agent, prompt):
            return await answerCreate(named: name, from: base, agent: agent, prompt: prompt, in: project)

        case let .worktreeRemove(target, force):
            let worktree: GitWorktree
            switch ControlTargets.worktree(target, from: request.directory, among: listed) {
            case let .failure(failure): return .failure(failure)
            case let .success(found): worktree = found
            }
            return await answerRemove(worktree, force: force, described: controlWorktree(worktree, in: project, current: current), in: project)

        case let .worktreeSet(target, status, clearsStatus, comment):
            guard status != nil || clearsStatus || comment != nil else {
                return .failure(ControlFailure(.invalidArgument, "Nothing to set: pass a status, a comment, or both."))
            }
            return self.target(target, from: request.directory, among: listed) { worktree in
                if clearsStatus {
                    setWorktreeStatus(nil, at: worktree.path)
                } else if let status {
                    setWorktreeStatus(status, at: worktree.path)
                }
                if let comment { setWorktreeComment(comment, at: worktree.path) }
                return ControlResponse(project: controlProject(project), worktree: controlWorktree(worktree, in: project, current: current))
            }
        }
    }

    /// The project a request is about, with its worktrees as git lists them now.
    private func controlScope(for request: ControlRequest) async -> Result<(project: Project, worktrees: [GitWorktree]), ControlFailure> {
        let sessionProject = request.sessionID.flatMap { sessions[SessionID(rawValue: $0)]?.projectID }
        func resolve() -> Project? {
            ControlTargets.project(
                sessionProject: sessionProject,
                directory: request.directory,
                projects: projects,
                worktrees: worktrees
            ).flatMap(project)
        }
        var found = resolve()
        if found == nil {
            // A worktree made in a terminal a moment ago is not in the list
            // the sidebar last read.
            for candidate in projects where gitRepositories.contains(candidate.id) {
                _ = await readWorktrees(of: candidate)
            }
            found = resolve()
        }
        guard let project = found else {
            return .failure(ControlFailure(
                .notInProject,
                "\(request.directory) is not inside a Relay project. "
                    + "Run this in a Relay terminal, or in the folder of a project Relay has open."
            ))
        }
        guard let listed = await readWorktrees(of: project) else {
            return .failure(ControlFailure(
                .notARepository,
                "\(project.name) is not a git repository, so it has no worktrees."
            ))
        }
        return .success((project, listed))
    }

    /// Git's list as it is now rather than as the last tick read it, taken in
    /// by the sidebar too, so a command never answers about a worktree the
    /// window does not show.
    private func readWorktrees(of project: Project) async -> [GitWorktree]? {
        let home = project.rootPath
        let found = await Task.detached(priority: .userInitiated, operation: {
            GitWorktreeActions.list(at: home)
        }).value
        guard let found else { return nil }
        adopt(found, in: project.id)
        return visibleWorktrees(in: project.id)
    }

    private func target(
        _ target: String?,
        from directory: String,
        among listed: [GitWorktree],
        then answer: (GitWorktree) -> ControlResponse
    ) -> ControlResponse {
        switch ControlTargets.worktree(target, from: directory, among: listed) {
        case let .failure(failure): .failure(failure)
        case let .success(worktree): answer(worktree)
        }
    }

    private func answerCreate(
        named name: String,
        from base: String?,
        agent: String?,
        prompt: String?,
        in project: Project
    ) async -> ControlResponse {
        var preset: SessionPreset?
        if let agent {
            guard let match = ControlTargets.preset(named: agent, in: sessionPresets) else {
                let names = sessionPresets.map(\.name).joined(separator: ", ")
                return .failure(ControlFailure(
                    .noSuchPreset,
                    "No session preset is called \(agent). The presets are \(names); "
                        + "claude, codex, gemini and opencode also name their agent."
                ))
            }
            preset = match
        }
        let text = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, preset?.kind.isAgent != true {
            return .failure(ControlFailure(
                .invalidArgument,
                preset.map { "\($0.name) is not an agent, so there is nothing to type a prompt into." }
                    ?? "A prompt needs an agent to be typed into: pass --agent."
            ))
        }

        switch await addWorktree(named: name, from: base, in: project) {
        case let .created(created):
            // New Worktree is only ever opened on the project in front, and the
            // agent's terminal is what the prompt waits for; so the project
            // comes to the front first, as it would have to for the window.
            if preset != nil, selectedProjectID != project.id { selectProject(project.id) }
            openCreatedWorktree(created, starting: preset, prompt: text, in: project.id)
            return ControlResponse(
                project: controlProject(project),
                worktree: controlWorktree(created, in: project, current: nil),
                agent: preset?.name
            )
        case .unusableName:
            return .failure(ControlFailure(.invalidArgument, "Nothing is left of \(name) that git accepts as a branch name."))
        case let .alreadyOpen(branch, holder):
            return .failure(ControlFailure(
                .alreadyOpen,
                "\(branch) is already checked out in \(holder.path), and git will not check a branch out twice."
            ))
        case let .refused(failure):
            return .failure(ControlFailure(.refused, Self.summarised(failure)))
        case let .unlisted(branch):
            return .failure(ControlFailure(
                .refused,
                "Git made \(branch) but does not list it. git worktree list shows where it went."
            ))
        }
    }

    private func answerRemove(
        _ worktree: GitWorktree,
        force: Bool,
        described: ControlWorktree,
        in project: Project
    ) async -> ControlResponse {
        guard canRemoveWorktree(worktree, in: project.id) else {
            let reason = worktree.path == homeWorktree(of: project.id)?.path
                ? "\(worktree.name) is \(project.name)'s own folder: remove the project from Relay instead."
                : "\(worktree.name) is the repository's main worktree, which git never removes."
            return .failure(ControlFailure(.refused, reason))
        }
        if !force {
            let path = worktree.path
            let status = await Task.detached(priority: .userInitiated, operation: { GitProbe.status(at: path) }).value
            if let status, status.isDirty {
                let files = status.changedFiles == 1 ? "1 file" : "\(status.changedFiles) files"
                return .failure(ControlFailure(
                    .uncommittedChanges,
                    "\(worktree.name) has uncommitted changes in \(files). "
                        + "Commit them, or pass --force to remove it and lose them."
                ))
            }
        }
        let removal = await performWorktreeRemoval(worktree, discardingChanges: force, in: project.id)
        if let failure = removal.failure {
            return .failure(ControlFailure(.refused, Self.summarised(failure)))
        }
        let branch: ControlBranchOutcome = switch removal.branch {
        case .deleted: .deleted
        case .keptUnmerged: .keptUnmerged
        case .untouched: .untouched
        }
        return ControlResponse(project: controlProject(project), worktree: described, branch: branch)
    }

    private func controlProject(_ project: Project) -> ControlProject {
        ControlProject(id: project.id.rawValue, name: project.name, path: project.rootPath)
    }

    private func controlWorktree(_ worktree: GitWorktree, in project: Project, current: GitWorktree?) -> ControlWorktree {
        ControlWorktree(
            path: worktree.path,
            branch: worktree.branch,
            name: worktree.name,
            head: worktree.head,
            isMain: worktree.isMain,
            isProjectFolder: worktree.path == homeWorktree(of: project.id)?.path,
            isCurrent: worktree.path == current?.path,
            isLocked: worktree.isLocked,
            changes: worktreeStatuses[worktree.path].map {
                ControlChanges(
                    changedFiles: $0.changedFiles,
                    insertions: $0.insertions,
                    deletions: $0.deletions,
                    ahead: $0.ahead,
                    behind: $0.behind
                )
            },
            note: worktreeNote(at: worktree.path)
        )
    }
}
