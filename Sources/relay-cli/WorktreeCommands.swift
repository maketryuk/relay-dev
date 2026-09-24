import Foundation
import RelayProtocol

/// `relay worktree …`: the checkouts of the project the command is run in.
enum WorktreeCommands {
    static let group = CommandGroup(
        name: "worktree",
        summary: "List, make and remove the project's worktrees, and say how the work in one is going.",
        commands: [list, current, create, remove, set]
    )

    private static let target = CommandSpec.Argument(name: "name|path", isRequired: false)

    static let list = CommandSpec(
        group: "worktree",
        name: "list",
        aliases: ["ls"],
        summary: "List the project's worktrees; * marks the one you are in.",
        notes: [
            "The project is the one this terminal belongs to, or else the one whose folder you are in.",
            "Changes are as the sidebar last read them, a few seconds old at most.",
        ],
        examples: ["relay worktree list", "relay worktree list --json"],
        request: { _ in .worktreeList },
        describe: { WorktreeReport.list($0) }
    )

    static let current = CommandSpec(
        group: "worktree",
        name: "current",
        summary: "Show the worktree you are in.",
        examples: ["relay worktree current", "relay worktree current --json"],
        request: { _ in .worktreeCurrent },
        describe: { $0.worktree.map(WorktreeReport.show) ?? "" }
    )

    static let create = CommandSpec(
        group: "worktree",
        name: "create",
        summary: "Make a worktree on a new branch, and start an agent in it with a prompt.",
        argument: CommandSpec.Argument(name: "name", isRequired: true),
        options: [
            CommandSpec.Option(
                name: "base",
                value: "ref",
                summary: "Where the new branch starts. Default: HEAD of the project's folder."
            ),
            CommandSpec.Option(
                name: "agent",
                value: "preset",
                summary: "Start a session preset in it: claude, codex, or a preset's name."
            ),
            CommandSpec.Option(
                name: "prompt",
                value: "text",
                summary: "Typed into the agent once it is ready for it. Needs --agent."
            ),
        ],
        notes: [
            "Named and placed as New Worktree does: the branch is <name> made acceptable to git, "
                + "checked out in ~/.relay/worktrees/<repository>/<branch>.",
            "A name that is already a local branch opens that branch; --base is then not used.",
            "Relay turns to the new worktree, and shows the agent it started, as New Worktree does.",
        ],
        examples: [
            "relay worktree create fix-login",
            "relay worktree create fix-login --agent claude --prompt \"Fix the redirect after login\"",
            "relay worktree create spike/cache --base origin/main --agent codex --json",
        ],
        timeout: 300,
        request: { parsed in
            guard let name = parsed.argument, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw UsageError(message: "relay worktree create needs a name.", help: "relay worktree create --help")
            }
            for option in ["base", "agent"] where parsed.value(option)?.isEmpty == true {
                throw UsageError(message: "--\(option) needs a value.", help: "relay worktree create --help")
            }
            if parsed.value("prompt") != nil, parsed.value("agent") == nil {
                throw UsageError(
                    message: "--prompt is typed into an agent: pass --agent too, such as --agent claude.",
                    help: "relay worktree create --help"
                )
            }
            return .worktreeCreate(
                name: name,
                base: parsed.value("base"),
                agent: parsed.value("agent"),
                prompt: parsed.value("prompt")
            )
        },
        describe: { WorktreeReport.created($0) }
    )

    static let remove = CommandSpec(
        group: "worktree",
        name: "rm",
        aliases: ["remove"],
        summary: "Remove a worktree, and its branch if Relay made it and nothing on it is unmerged.",
        argument: target,
        options: [
            CommandSpec.Option(name: "force", value: nil, summary: "Remove it even with uncommitted changes, which are lost."),
        ],
        notes: [
            "Without a name or path, the worktree you are in; a name is a branch or a folder name.",
            "Closes the sessions running in it, this terminal too if it is one of them.",
            "Never the project's own folder, nor the repository's main worktree.",
        ],
        examples: [
            "relay worktree rm fix-login",
            "relay worktree rm ~/.relay/worktrees/shop/fix-login --force --json",
        ],
        timeout: 300,
        request: { parsed in .worktreeRemove(target: parsed.argument, force: parsed.isOn("force")) },
        describe: { WorktreeReport.removed($0) }
    )

    static let set = CommandSpec(
        group: "worktree",
        name: "set",
        summary: "Say how the work in a worktree is going: a status, a comment, or both.",
        argument: target,
        options: [
            CommandSpec.Option(
                name: "status",
                value: "status",
                summary: "todo, in-progress, in-review, completed, or none to clear it."
            ),
            CommandSpec.Option(name: "comment", value: "text", summary: "One short line; \"\" clears it."),
        ],
        notes: [
            "Without a name or path, the worktree you are in.",
            "Shown beside the worktree in Relay's sidebar. Keep the comment current: "
                + "set it after a repro, a fix, a test run, or when blocked.",
        ],
        examples: [
            "relay worktree set --status in-progress --comment \"Reproduced; writing the fix\"",
            "relay worktree set fix-login --status in-review",
            "relay worktree set --comment \"\"",
        ],
        request: { parsed in
            var status: WorktreeWorkStatus?
            var clearsStatus = false
            if let raw = parsed.value("status")?.lowercased() {
                if raw == "none" {
                    clearsStatus = true
                } else if let named = WorktreeWorkStatus(rawValue: raw) {
                    status = named
                } else {
                    let names = WorktreeWorkStatus.allCases.map(\.rawValue).joined(separator: ", ")
                    throw UsageError(
                        message: "--status is one of \(names), or none; not \(raw).",
                        help: "relay worktree set --help"
                    )
                }
            }
            let comment = parsed.value("comment")
            guard status != nil || clearsStatus || comment != nil else {
                throw UsageError(
                    message: "Nothing to set: pass --status, --comment, or both.",
                    help: "relay worktree set --help"
                )
            }
            return .worktreeSet(target: parsed.argument, status: status, clearsStatus: clearsStatus, comment: comment)
        },
        describe: { WorktreeReport.updated($0) }
    )
}

/// How the answers read to a person. `--json` is for everything else.
enum WorktreeReport {
    static func list(_ response: ControlResponse, home: String = NSHomeDirectory()) -> String {
        let worktrees = response.worktrees ?? []
        var lines: [String] = []
        if let project = response.project {
            lines.append("\(project.name) — \(abbreviating(project.path, home: home))")
        }
        let names = worktrees.map(\.name)
        let paths = worktrees.map { abbreviating($0.path, home: home) }
        let nameWidth = names.map(\.count).max() ?? 0
        let pathWidth = paths.map(\.count).max() ?? 0
        for (index, worktree) in worktrees.enumerated() {
            let details = self.details(of: worktree)
            var line = (worktree.isCurrent ? "* " : "  ")
                + padded(names[index], to: nameWidth) + "  "
                + padded(paths[index], to: details.isEmpty ? 0 : pathWidth)
            if !details.isEmpty { line += "  " + details.joined(separator: "  ") }
            lines.append(line.trimmingTrailingSpaces())
        }
        if worktrees.isEmpty { lines.append("No worktrees.") }
        return lines.joined(separator: "\n")
    }

    static func show(_ worktree: ControlWorktree) -> String {
        var lines = ["name: \(worktree.name)", "path: \(worktree.path)"]
        lines.append("branch: \(worktree.branch ?? "none (HEAD is detached)")")
        if let changes = worktree.changes { lines.append("changes: \(summary(of: changes))") }
        let kinds = kinds(of: worktree)
        if !kinds.isEmpty { lines.append("is: \(kinds.joined(separator: ", "))") }
        if let status = worktree.note?.status { lines.append("status: \(status.rawValue)") }
        if let comment = worktree.note?.comment, !comment.isEmpty { lines.append("comment: \(comment)") }
        return lines.joined(separator: "\n")
    }

    static func created(_ response: ControlResponse) -> String {
        guard let worktree = response.worktree else { return "" }
        var lines = ["Created \(worktree.name) in \(worktree.path)."]
        if let agent = response.agent {
            lines.append("Started \(agent) in it; a prompt is typed in once it is ready for one.")
        }
        return lines.joined(separator: "\n")
    }

    static func removed(_ response: ControlResponse) -> String {
        guard let worktree = response.worktree else { return "" }
        var lines = ["Removed \(worktree.name) from \(worktree.path)."]
        if let branch = worktree.branch {
            switch response.branch {
            case .deleted:
                lines.append("Deleted branch \(branch): Relay made it, and nothing on it was unmerged.")
            case .keptUnmerged:
                lines.append("Kept branch \(branch): it has commits that are not merged anywhere yet.")
            case .untouched:
                lines.append("Kept branch \(branch): Relay did not make it.")
            case nil:
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    static func updated(_ response: ControlResponse) -> String {
        guard let worktree = response.worktree else { return "" }
        var lines = ["Updated \(worktree.name)."]
        if let status = worktree.note?.status { lines.append("status: \(status.rawValue)") }
        if let comment = worktree.note?.comment, !comment.isEmpty { lines.append("comment: \(comment)") }
        return lines.joined(separator: "\n")
    }

    private static func details(of worktree: ControlWorktree) -> [String] {
        var details: [String] = []
        if let changes = worktree.changes { details.append(summary(of: changes)) }
        details += kinds(of: worktree)
        if let status = worktree.note?.status { details.append("[\(status.rawValue)]") }
        if let comment = worktree.note?.comment, !comment.isEmpty { details.append(comment) }
        return details
    }

    private static func kinds(of worktree: ControlWorktree) -> [String] {
        var kinds: [String] = []
        if worktree.isProjectFolder { kinds.append("project folder") } else if worktree.isMain { kinds.append("main") }
        if worktree.branch == nil { kinds.append("detached") }
        if worktree.isLocked { kinds.append("locked") }
        return kinds
    }

    static func summary(of changes: ControlChanges) -> String {
        var parts = [changes.changedFiles == 0
            ? "clean"
            : "\(changes.changedFiles) changed +\(changes.insertions) -\(changes.deletions)"]
        if changes.ahead > 0 { parts.append("\(changes.ahead) ahead") }
        if changes.behind > 0 { parts.append("\(changes.behind) behind") }
        return parts.joined(separator: ", ")
    }

    static func abbreviating(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func padded(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var text = self
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}
