import Foundation
import RelayProtocol
import Testing

@testable import relay_cli

@Suite("Reading the relay command line")
struct CommandParserTests {
    private func command(_ words: String...) throws -> Invocation.Run {
        guard case let .run(run) = CommandParser.parse(words) else {
            Issue.record("\(words) was not read as a command: \(CommandParser.parse(words))")
            throw Unexpected()
        }
        return run
    }

    private func usage(_ words: String...) throws -> (UsageError, json: Bool) {
        guard case let .usage(error, json) = CommandParser.parse(words) else {
            Issue.record("\(words) was not refused: \(CommandParser.parse(words))")
            throw Unexpected()
        }
        return (error, json)
    }

    private func help(_ words: String...) throws -> String {
        guard case let .help(text) = CommandParser.parse(words) else {
            Issue.record("\(words) did not ask for help: \(CommandParser.parse(words))")
            throw Unexpected()
        }
        return text
    }

    private struct Unexpected: Error {}

    @Test("Each worktree command becomes the request it names")
    func readsEachCommand() throws {
        #expect(try command("worktree", "list").command == .worktreeList)
        #expect(try command("worktree", "current").command == .worktreeCurrent)
        #expect(try command("worktree", "rm", "fix-login").command == .worktreeRemove(target: "fix-login", force: false))
        #expect(try command("worktree", "rm", "--force").command == .worktreeRemove(target: nil, force: true))
    }

    @Test("A command answers to the other verb it is known by")
    func aliases() throws {
        #expect(try command("worktree", "ls").command == .worktreeList)
        #expect(try command("worktree", "remove", "x").command == .worktreeRemove(target: "x", force: false))
    }

    @Test("create carries its name, base, agent and prompt, in either spelling of an option")
    func create() throws {
        let run = try command(
            "worktree", "create", "fix login", "--base=origin/main", "--agent", "claude",
            "--prompt", "Fix the redirect", "--json"
        )
        #expect(run.command == .worktreeCreate(
            name: "fix login",
            base: "origin/main",
            agent: "claude",
            prompt: "Fix the redirect"
        ))
        #expect(run.json)
        #expect(run.spec.timeout > 60)
    }

    @Test("The word after an option is its value, dashes and all")
    func valuesThatLookLikeOptions() throws {
        let run = try command("worktree", "create", "x", "--agent", "codex", "--prompt", "--help me")
        #expect(run.command == .worktreeCreate(name: "x", base: nil, agent: "codex", prompt: "--help me"))
        #expect(try command("worktree", "set", "--comment", "-").command
            == .worktreeSet(target: nil, status: nil, clearsStatus: false, comment: "-"))
    }

    @Test("A name that starts with a dash is given after --")
    func endOfOptions() throws {
        #expect(try command("worktree", "rm", "--", "-odd").command == .worktreeRemove(target: "-odd", force: false))
        #expect(try usage("worktree", "rm", "-odd").0.message.contains("-odd"))
    }

    @Test("A prompt with nobody to hand it to is refused before anything is asked")
    func promptNeedsAgent() throws {
        let (error, _) = try usage("worktree", "create", "x", "--prompt", "do it")
        #expect(error.message.contains("--agent"))
        #expect(error.help == "relay worktree create --help")
    }

    @Test("create needs a name, and options that take a value get one")
    func createNeedsItsParts() throws {
        #expect(try usage("worktree", "create").0.message.contains("needs a name"))
        #expect(try usage("worktree", "create", "x", "--base").0.message == "--base needs a value.")
        #expect(try usage("worktree", "create", "x", "--agent", "").0.message == "--agent needs a value.")
        #expect(try usage("worktree", "create", "x", "y").0.message.contains("was given x and y"))
    }

    @Test("set reads each status, none clears it, and an empty comment is a comment")
    func set() throws {
        #expect(try command("worktree", "set", "--status", "in-progress").command
            == .worktreeSet(target: nil, status: .inProgress, clearsStatus: false, comment: nil))
        #expect(try command("worktree", "set", "fix", "--status", "In-Review").command
            == .worktreeSet(target: "fix", status: .inReview, clearsStatus: false, comment: nil))
        #expect(try command("worktree", "set", "--status", "none").command
            == .worktreeSet(target: nil, status: nil, clearsStatus: true, comment: nil))
        #expect(try command("worktree", "set", "--comment", "").command
            == .worktreeSet(target: nil, status: nil, clearsStatus: false, comment: ""))
    }

    @Test("set refuses a status it does not know, and a call that sets nothing")
    func setRefusals() throws {
        #expect(try usage("worktree", "set", "--status", "done").0.message.contains("todo, in-progress, in-review, completed"))
        #expect(try usage("worktree", "set").0.message.contains("Nothing to set"))
    }

    @Test("Options a command does not have, and ones given twice, are refused by name")
    func unknownOptions() throws {
        #expect(try usage("worktree", "list", "--force").0.message == "relay worktree list has no option --force.")
        #expect(try usage("worktree", "rm", "--force=yes").0.message == "--force takes no value.")
        #expect(try usage("worktree", "set", "--comment", "a", "--comment", "b").0.message == "--comment is given twice.")
        #expect(try usage("worktree", "list", "extra").0.message.contains("takes no argument"))
    }

    @Test("A usage error keeps --json, so a program still gets JSON back")
    func usageRemembersJSON() throws {
        #expect(try usage("worktree", "set", "--json").json)
        #expect(try usage("worktree", "set").json == false)
        #expect(try usage("frobnicate", "--json").json)
    }

    @Test("Unknown groups and commands say what there is instead")
    func unknownCommands() throws {
        #expect(try usage("frobnicate").0.help == "relay help")
        let (error, _) = try usage("worktree", "frobnicate")
        #expect(error.message.contains("list, current, create, rm, set"))
        #expect(try usage("worktree").0.message.contains("needs a command"))
    }

    @Test("Help is there at every level, and a command's help wins over its options")
    func helpEverywhere() throws {
        #expect(try help().contains("relay worktree list"))
        #expect(try help("--help").contains("Usage: relay <group>"))
        #expect(try help("help", "worktree").contains("Commands:"))
        #expect(try help("worktree", "--help").contains("Commands:"))
        let create = try help("worktree", "create", "--help")
        #expect(create.contains("Usage: relay worktree create <name> [--base <ref>] [--agent <preset>] [--prompt <text>] [--json]"))
        #expect(create.contains("Examples:"))
        #expect(try help("help", "worktree", "remove").contains("relay worktree rm"))
        #expect(try help("worktree", "set", "--status", "bogus", "-h").contains("--status <status>"))
    }

    @Test("The version is asked for either way")
    func version() {
        for words in [["--version"], ["version"]] {
            guard case .version = CommandParser.parse(words) else {
                Issue.record("\(words) did not ask for the version")
                continue
            }
        }
    }
}

@Suite("Printing the app's answers")
struct WorktreeReportTests {
    private let home = "/Users/me"

    private func worktree(
        _ name: String,
        at path: String,
        current: Bool = false,
        folder: Bool = false,
        changes: ControlChanges? = nil,
        note: WorktreeNote? = nil
    ) -> ControlWorktree {
        ControlWorktree(
            path: path,
            branch: name,
            name: name,
            isMain: folder,
            isProjectFolder: folder,
            isCurrent: current,
            changes: changes,
            note: note
        )
    }

    @Test("The list marks where you are and shortens the home folder")
    func list() {
        let response = ControlResponse(
            project: ControlProject(id: "p", name: "shop", path: "/Users/me/code/shop"),
            worktrees: [
                worktree("main", at: "/Users/me/code/shop", folder: true,
                         changes: ControlChanges(changedFiles: 0, insertions: 0, deletions: 0, ahead: 0, behind: 0)),
                worktree("fix-login", at: "/Users/me/.relay/worktrees/shop/fix-login", current: true,
                         changes: ControlChanges(changedFiles: 2, insertions: 10, deletions: 3, ahead: 1, behind: 0),
                         note: WorktreeNote(status: .inProgress, comment: "testing the fix")),
            ]
        )
        let lines = WorktreeReport.list(response, home: home).components(separatedBy: "\n")
        #expect(lines[0] == "shop — ~/code/shop")
        #expect(lines[1].hasPrefix("  main       ~/code/shop"))
        #expect(lines[1].hasSuffix("clean  project folder"))
        #expect(lines[2].hasPrefix("* fix-login  ~/.relay/worktrees/shop/fix-login"))
        #expect(lines[2].hasSuffix("2 changed +10 -3, 1 ahead  [in-progress]  testing the fix"))
    }

    @Test("What rm did to the branch is said in words")
    func removal() {
        let removed = worktree("spike", at: "/tmp/spike")
        let deleted = WorktreeReport.removed(ControlResponse(worktree: removed, branch: .deleted))
        #expect(deleted.contains("Deleted branch spike"))
        let kept = WorktreeReport.removed(ControlResponse(worktree: removed, branch: .keptUnmerged))
        #expect(kept.contains("not merged anywhere"))
    }

    @Test("Relay not running is one sentence, naming Dev only when it could be meant")
    func notRunning() {
        let bare = Report.notRunning(socket: "/tmp/relay-501-control.sock", environment: [:])
        #expect(bare.hasPrefix("Relay is not running"))
        #expect(bare.contains("RELAY_FLAVOUR=dev"))
        #expect(!bare.contains("\n"))
        let inTerminal = Report.notRunning(
            socket: "/tmp/relay-dev-501-control.sock",
            environment: [ControlEnvironment.socketKey: "/tmp/relay-dev-501-control.sock"]
        )
        #expect(!inTerminal.contains("RELAY_FLAVOUR"))
    }
}
