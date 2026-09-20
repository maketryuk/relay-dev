import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Text waiting for a session")
struct PendingInputTests {
    @Test("A session that is still working is not typed into")
    func notWhileWorking() {
        // Typed while the agent is printing, the text is echoed into a prompt
        // that then redraws over it — the review is gone and nothing says so.
        #expect(!PendingInputPolicy.isReady(status: .working, hasTerminal: true))
        #expect(!PendingInputPolicy.isReady(status: .starting, hasTerminal: true))
    }

    @Test("A session with no terminal yet is not typed into either")
    func notWithoutATerminal() {
        // Relay asks the terminal whether it understands a bracketed paste.
        // Without one the text goes as plain keystrokes, and every newline in a
        // review sends the half-written message before it.
        #expect(!PendingInputPolicy.isReady(status: .waiting, hasTerminal: false))
        #expect(!PendingInputPolicy.isReady(status: .idle, hasTerminal: false))
    }

    @Test("A session at its prompt, with a terminal, takes the text")
    func readyAtThePrompt() {
        #expect(PendingInputPolicy.isReady(status: .waiting, hasTerminal: true))
        #expect(PendingInputPolicy.isReady(status: .idle, hasTerminal: true))
    }

    @Test("A finished session is not typed into")
    func notWhenFinished() {
        #expect(!PendingInputPolicy.isReady(status: .finished, hasTerminal: true))
        #expect(!PendingInputPolicy.isReady(status: .error, hasTerminal: true))
        #expect(!PendingInputPolicy.isReady(status: .offline, hasTerminal: true))
    }

    @Test("Notes travel with the text they became")
    func carriesTheNotes() {
        // The bug this closes: the notes were forgotten when the session was
        // asked for, not when the text reached it. If the hand-over never
        // happened — and it did not, whenever the session reached its prompt
        // before the queue was set — the review was gone from both places.
        let ids = [UUID(), UUID()]
        let pending = PendingInput(text: "review", commentIDs: ids)

        #expect(pending.commentIDs == ids)
        #expect(PendingInput(text: "todo").commentIDs.isEmpty)
    }
}
