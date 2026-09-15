import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

@Suite("Shell activity detection")
struct ShellActivityAdapterTests {
    private let adapter = ShellActivityAdapter()

    @Test(
        "Confirmation prompts mean the shell is waiting for the user",
        arguments: [
            "rm: remove regular file 'a.txt'? (y/n) ",
            "Overwrite existing file? [y/N]",
            "Enter passphrase for key '/Users/me/.ssh/id_ed25519':",
            "Are you sure you want to continue connecting?",
            "Press enter to continue",
        ]
    )
    func detectsPrompts(tail: String) {
        #expect(adapter.verdict(tail: tail, producedOutput: true) == .waitingForUser)
    }

    @Test(
        "A shell prompt after real output means the command finished",
        arguments: ["~/project $ ", "user@mac ~ % ", "➜  project git:(main) ", "root# "]
    )
    func promptAfterWorkIsCompleted(tail: String) {
        #expect(adapter.verdict(tail: tail, producedOutput: true) == .completed)
    }

    @Test("A prompt with no preceding work is merely idle")
    func promptWithoutWorkIsIdle() {
        // A freshly spawned shell prints its prompt; that is not finished work.
        #expect(adapter.verdict(tail: "~/project $ ", producedOutput: false) == .idle)
    }

    @Test("Output that is neither a prompt nor a question is idle")
    func unrecognisedTailIsIdle() {
        #expect(adapter.verdict(tail: "some trailing log line", producedOutput: true) == .idle)
    }

    @Test("Prompt detection is case-insensitive")
    func caseInsensitive() {
        #expect(adapter.verdict(tail: "ARE YOU SURE?", producedOutput: true) == .waitingForUser)
    }
}

@Suite("Agent activity detection")
struct AgentActivityAdapterTests {
    private let adapter = AgentActivityAdapter()

    @Test(
        "Interactive choice UI means the agent is blocked on the user",
        arguments: [
            "Do you want to make this edit to config.ts?\n❯ 1. Yes\n  2. No",
            "Allow this tool call?",
            "Should I proceed with the refactor?",
            "Waiting for your response",
        ]
    )
    func detectsAgentQuestions(tail: String) {
        #expect(adapter.verdict(tail: tail, producedOutput: true) == .waitingForUser)
    }

    @Test("Substantial output followed by quiet means the task completed")
    func completionAfterWork() {
        let tail = "Updated 3 files.\n\n│ > \n"
        #expect(adapter.verdict(tail: tail, producedOutput: true) == .completed)
    }

    @Test("An idle input box with no work done is idle, not finished")
    func idleInputBox() {
        let tail = "│ > Try \"fix the tests\"\n/help for help"
        #expect(adapter.verdict(tail: tail, producedOutput: false) == .idle)
    }

    @Test("A question outranks the completion signal")
    func questionBeatsCompletion() {
        // Both a question and a full transcript are present; the user is blocked.
        let tail = "Edited 4 files.\nDo you want to run the tests?\n❯ 1. Yes"
        #expect(adapter.verdict(tail: tail, producedOutput: true) == .waitingForUser)
    }

    @Test("Adapters are selected by session kind")
    func adapterSelection() {
        #expect(ActivityAdapters.adapter(for: .shell) is ShellActivityAdapter)
        #expect(ActivityAdapters.adapter(for: .ssh) is ShellActivityAdapter)
        #expect(ActivityAdapters.adapter(for: .custom) is ShellActivityAdapter)
        #expect(ActivityAdapters.adapter(for: .claude) is AgentActivityAdapter)
        #expect(ActivityAdapters.adapter(for: .codex) is AgentActivityAdapter)
        #expect(ActivityAdapters.adapter(for: .gemini) is AgentActivityAdapter)
        #expect(ActivityAdapters.adapter(for: .opencode) is AgentActivityAdapter)
    }
}
