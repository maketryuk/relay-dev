import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Context window")
struct ContextWindowTests {
    @Test("A declared window is used as given")
    func declaredWins() {
        #expect(ContextWindow.resolve(observed: 1_000, declared: 258_400) == 258_400)
    }

    @Test("Without one, the smallest window that fits is assumed")
    func infersFromWhatFits() {
        // Claude Code records neither the window nor the suffix that tells the
        // long-context variant apart, so the one reliable fact is that a window
        // cannot be smaller than what is already inside it.
        #expect(ContextWindow.resolve(observed: 50_000, declared: nil) == 200_000)
        #expect(ContextWindow.resolve(observed: 813_339, declared: nil) == 1_000_000)
    }

    @Test("The bar can never read over full")
    func neverExceedsTheWindow() {
        let context = SessionContext(
            tokens: 2_000_000,
            window: ContextWindow.resolve(observed: 2_000_000, declared: nil),
            isWindowDeclared: false,
            model: nil,
            slices: [],
            measuredAt: nil
        )
        #expect(context.fraction.map { $0 <= 1 } == true)
    }

    @Test("Nothing observed means nothing to assume")
    func emptyObservation() {
        #expect(ContextWindow.resolve(observed: 0, declared: nil) == nil)
    }
}

@Suite("Token formatting")
struct TokenFormattingTests {
    @Test("Large numbers are written the way people say them")
    func shortForms() {
        #expect(TokenFormatting.short(813_339) == "813K")
        #expect(TokenFormatting.short(1_240_000) == "1.2M")
        #expect(TokenFormatting.short(12_400_000) == "12M")
        #expect(TokenFormatting.short(842) == "842")
    }
}

@Suite("Claude context")
struct ClaudeContextReaderTests {
    private func turn(cacheRead: Int, cacheCreate: Int, input: Int, output: Int) -> [String: Any] {
        [
            "type": "assistant",
            "message": [
                "model": "claude-opus-5",
                "usage": [
                    "cache_read_input_tokens": cacheRead,
                    "cache_creation_input_tokens": cacheCreate,
                    "input_tokens": input,
                    "output_tokens": output,
                ],
            ],
        ]
    }

    @Test("The window holds everything that was sent, cached or not")
    func sumsTheInputSide() throws {
        let context = try #require(ClaudeContextReader.parse(
            [turn(cacheRead: 813_208, cacheCreate: 129, input: 2, output: 1_001)],
            measuredAt: nil
        ))
        #expect(context.tokens == 813_339)
        #expect(context.model == "claude-opus-5")
        #expect(context.window == 1_000_000)
        #expect(!context.isWindowDeclared)
    }

    @Test("The last turn is the one that counts")
    func usesTheLatestTurn() throws {
        // Earlier turns describe a window that has since grown.
        let context = try #require(ClaudeContextReader.parse(
            [
                turn(cacheRead: 1_000, cacheCreate: 0, input: 0, output: 10),
                turn(cacheRead: 50_000, cacheCreate: 0, input: 0, output: 10),
            ],
            measuredAt: nil
        ))
        #expect(context.tokens == 50_000)
    }

    @Test("The split is only what the agent actually reports")
    func slicesAreReported() throws {
        let context = try #require(ClaudeContextReader.parse(
            [turn(cacheRead: 100, cacheCreate: 20, input: 5, output: 7)],
            measuredAt: nil
        ))
        #expect(context.slices.map(\.kind) == [.cached, .newlyCached, .fresh, .output])
        #expect(context.slices.map(\.tokens) == [100, 20, 5, 7])
    }

    @Test("A part worth nothing is left out rather than shown as zero")
    func dropsEmptySlices() throws {
        let context = try #require(ClaudeContextReader.parse(
            [turn(cacheRead: 100, cacheCreate: 0, input: 0, output: 0)],
            measuredAt: nil
        ))
        #expect(context.slices.map(\.kind) == [.cached])
    }

    @Test("A transcript with no assistant turn yields nothing")
    func toleratesAbsence() {
        #expect(ClaudeContextReader.parse([], measuredAt: nil) == nil)
        #expect(ClaudeContextReader.parse([["type": "user"]], measuredAt: nil) == nil)
    }

    @Test("Both spellings of a project folder are tried")
    func folderNaming() {
        // A path with a dot is flattened too, and guessing one way means finding
        // nothing at all for those projects.
        #expect(ClaudeContextReader.directoryNames(for: "/Users/me/shop") == ["-Users-me-shop"])
        #expect(ClaudeContextReader.directoryNames(for: "/Users/me/my.app")
            == ["-Users-me-my.app", "-Users-me-my-app"])
    }
}

@Suite("Codex context")
struct CodexContextReaderTests {
    private func record(_ info: [String: Any]) -> [String: Any] {
        ["type": "event", "payload": ["info": info]]
    }

    private var usage: [String: Any] {
        [
            "last_token_usage": [
                "input_tokens": 32_223,
                "cached_input_tokens": 31_744,
                "cache_write_input_tokens": 0,
                "output_tokens": 533,
                "reasoning_output_tokens": 177,
            ],
            "model_context_window": 258_400,
        ]
    }

    @Test("Codex states its own window, so nothing is assumed")
    func usesTheDeclaredWindow() throws {
        let context = try #require(CodexContextReader.parse([record(usage)], measuredAt: nil))
        #expect(context.window == 258_400)
        #expect(context.isWindowDeclared)
        #expect(context.tokens == 32_223)
    }

    @Test("The cached share is part of the input, not another addend")
    func cachedIsInsideInput() throws {
        // Counting it twice would put the window over full on a long session.
        let context = try #require(CodexContextReader.parse([record(usage)], measuredAt: nil))
        let fresh = try #require(context.slices.first { $0.kind == .fresh })
        #expect(fresh.tokens == 32_223 - 31_744)
        #expect(context.tokens == 32_223)
    }

    @Test("Reasoning is separated from the rest of the output")
    func reasoningIsItsOwnSlice() throws {
        let context = try #require(CodexContextReader.parse([record(usage)], measuredAt: nil))
        #expect(context.slices.first { $0.kind == .reasoning }?.tokens == 177)
        #expect(context.slices.first { $0.kind == .output }?.tokens == 533 - 177)
    }

    @Test("A log with no usage in it yields nothing")
    func toleratesAbsence() {
        #expect(CodexContextReader.parse([], measuredAt: nil) == nil)
        #expect(CodexContextReader.parse([["type": "message"]], measuredAt: nil) == nil)
    }
}

@Suite("Reading a tail")
struct TranscriptTailTests {
    @Test("A record cut in half by the tail is dropped")
    func dropsThePartialFirstLine() {
        // The tail starts wherever the offset landed, which is usually
        // mid-record. Half of one is not one.
        let lines = TranscriptTail.lines(in: "ne\":1}\n{\"two\":2}\n", isWholeFile: false)
        #expect(lines == ["{\"two\":2}"])
    }

    @Test("A file read whole keeps its first line")
    func keepsEverythingWhenWhole() {
        let lines = TranscriptTail.lines(in: "{\"one\":1}\n{\"two\":2}\n", isWholeFile: true)
        #expect(lines.count == 2)
    }
}

@Suite("Codex session identity")
struct CodexSessionMetaTests {
    @Test("A session_meta line far larger than a page is still read whole")
    func readsALongFirstLine() throws {
        // Codex records the environment it started with, which runs to tens of
        // kilobytes. Reading less returns half a record, which parses as
        // nothing and quietly matches no session at all — the exact way this
        // first failed.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let padding = String(repeating: "x", count: 64 * 1024)
        let meta = """
        {"type":"session_meta","payload":{"cwd":"/Users/me/shop","timestamp":"2026-09-15T09:57:00.937Z","instructions":"\(padding)"}}
        """
        let log = directory.appendingPathComponent("rollout-test.jsonl")
        try "\(meta)\n{\"type\":\"event\"}\n".write(to: log, atomically: true, encoding: .utf8)

        let found = try #require(CodexContextReader.sessionMeta(of: log))
        #expect(found.directory == "/Users/me/shop")
        #expect(found.startedAt != nil)
    }

    @Test("A first line with no newline yet is not a record")
    func refusesAnUnterminatedLine() throws {
        // A log being written to can end mid-record; half of one is not one.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = directory.appendingPathComponent("rollout-partial.jsonl")
        try #"{"type":"session_meta","payload":{"cwd":"/Users/me"#.write(to: log, atomically: true, encoding: .utf8)
        #expect(CodexContextReader.sessionMeta(of: log) == nil)
    }
}

@Suite("Matching a session to its transcript")
struct TranscriptMatchingTests {
    private let started = Date(timeIntervalSince1970: 10_000)

    private func candidate(_ name: String, at offset: TimeInterval) -> (url: URL, createdAt: Date) {
        (URL(fileURLWithPath: "/transcripts/\(name).jsonl"), started.addingTimeInterval(offset))
    }

    @Test("The transcript that began with the session is the session's")
    func picksTheOneThatStartedWithIt() {
        let chosen = ClaudeContextReader.choose(
            from: [candidate("old", at: -86_400), candidate("ours", at: 2)],
            startedAt: started
        )
        #expect(chosen?.lastPathComponent == "ours.jsonl")
    }

    @Test("A conversation that was already running is never claimed")
    func refusesOlderTranscripts() {
        // The bug this replaces: a freshly opened pane showed a long-running
        // conversation's 93% as if it were its own, because that transcript was
        // the most recently written.
        let chosen = ClaudeContextReader.choose(
            from: [candidate("someone-elses", at: -3_600)],
            startedAt: started
        )
        #expect(chosen == nil)
    }

    @Test("Between two that began alongside it, the closer one wins")
    func picksTheNearestStart() {
        let chosen = ClaudeContextReader.choose(
            from: [candidate("later", at: 40), candidate("ours", at: 1)],
            startedAt: started
        )
        #expect(chosen?.lastPathComponent == "ours.jsonl")
    }

    @Test("The CLI opens its transcript a moment after being spawned")
    func allowsForStartupSlack() {
        // Relay spawns the process; the transcript appears once the CLI is up.
        let chosen = ClaudeContextReader.choose(
            from: [candidate("ours", at: -5)],
            startedAt: started
        )
        #expect(chosen?.lastPathComponent == "ours.jsonl")
    }

    @Test("Nothing to match means nothing is reported")
    func emptyCandidates() {
        #expect(ClaudeContextReader.choose(from: [], startedAt: started) == nil)
    }
}

@Suite("Conversations")
struct ConversationTests {
    private func claude(_ title: String?, prompt: String?, branch: String? = "main") -> Conversation? {
        var objects: [[String: Any]] = []
        if let title { objects.append(["type": "ai-title", "aiTitle": title]) }
        if let prompt { objects.append(["type": "last-prompt", "lastPrompt": prompt]) }
        if let branch { objects.append(["gitBranch": branch, "type": "assistant"]) }
        return ClaudeConversationReader.conversation(
            id: "abc-123",
            objects: objects,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test("A conversation is named by the title the agent generated")
    func usesTheGeneratedTitle() throws {
        let conversation = try #require(claude("Implement the daemon", prompt: "start over"))
        #expect(conversation.title == "Implement the daemon")
        #expect(conversation.lastPrompt == "start over")
        #expect(conversation.branch == "main")
    }

    @Test("Without one, the last thing the user said names it")
    func fallsBackToThePrompt() throws {
        let conversation = try #require(claude(nil, prompt: "fix the failing test\nand push"))
        #expect(conversation.title == "fix the failing test")
    }

    @Test("A transcript with nothing to show for itself is not listed")
    func skipsUnnameable() {
        // A row saying only "Claude" is a row nobody can choose between.
        #expect(claude(nil, prompt: nil) == nil)
    }

    @Test("A detached HEAD is not a branch worth showing")
    func ignoresDetachedHead() throws {
        let conversation = try #require(claude("Something", prompt: nil, branch: "HEAD"))
        #expect(conversation.branch == nil)
    }

    @Test("Resuming asks the agent to continue, rather than starting again")
    func resumeCommands() {
        let claude = Conversation(id: "s1", kind: .claude, title: "t", lastPrompt: nil, branch: nil, updatedAt: Date())
        let codex = Conversation(id: "s2", kind: .codex, title: "t", lastPrompt: nil, branch: nil, updatedAt: Date())
        #expect(claude.resumeCommand == ["claude", "--resume", "s1"])
        #expect(codex.resumeCommand == ["codex", "resume", "s2"])
    }

    @Test("The most recent conversation is the one offered first")
    func sortedByRecency() {
        let older = Conversation(id: "a", kind: .claude, title: "a", lastPrompt: nil, branch: nil,
                                 updatedAt: Date(timeIntervalSince1970: 100))
        let newer = Conversation(id: "b", kind: .claude, title: "b", lastPrompt: nil, branch: nil,
                                 updatedAt: Date(timeIntervalSince1970: 200))
        #expect(ConversationSorting.byRecency([older, newer]).map(\.id) == ["b", "a"])
    }

    @Test("A long prompt is trimmed to its first line")
    func summarises() {
        #expect(ConversationSorting.summary(of: "  do the thing  \nthen another") == "do the thing")
        #expect(ConversationSorting.summary(of: String(repeating: "x", count: 200)).hasSuffix("…"))
    }

    @Test("Codex is named by the first thing the person said")
    func codexSkipsTheInjectedContext() throws {
        // The desktop app injects a `developer` turn describing the environment;
        // naming conversations after it would name them all the same.
        let objects: [[String: Any]] = [
            ["payload": ["type": "message", "role": "developer",
                         "content": [["type": "input_text", "text": "<app-context>…"]]]],
            ["payload": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": "add a status bar"]]]],
        ]
        #expect(CodexConversationReader.firstUserMessage(in: objects) == "add a status bar")
    }
}
