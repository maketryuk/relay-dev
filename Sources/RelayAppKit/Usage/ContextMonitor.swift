import Foundation
import Observation
import RelayProtocol

/// Keeps the context figure current for the sessions on screen.
///
/// Only for sessions Relay can attribute to an agent: a plain shell has no
/// context to fill, and asking about it would be inventing a question.
@MainActor
@Observable
final class ContextMonitor {
    /// The window moves once per turn, and a turn is measured in seconds at
    /// best. Ten seconds is well inside that and costs a tail read.
    static let refreshInterval: TimeInterval = 10

    private(set) var contexts: [SessionID: SessionContext] = [:]

    /// What the user says their Claude sessions run with. Automatic leaves the
    /// window to be worked out, which is what it was before there was a choice.
    var claudeWindow: ContextWindowPreference = .automatic {
        didSet {
            guard claudeWindow != oldValue else { return }
            Task { [weak self] in await self?.refresh() }
        }
    }

    private var task: Task<Void, Never>?
    private var watched: [SessionSnapshot] = []

    /// Called as the selection changes. Reading is scoped to what is visible:
    /// a project with thirty sessions should not make Relay read thirty
    /// transcripts every ten seconds.
    ///
    /// A changed set is read at once rather than at the next tick. Ten seconds
    /// is nothing while a figure is only drifting, and a very long time to stare
    /// at a terminal that is not saying how full it is.
    func watch(_ sessions: [SessionSnapshot]) {
        let agents = sessions.filter { $0.kind.isAgent }
        guard agents.map(\.id) != watched.map(\.id) else { return }
        watched = agents

        guard !watched.isEmpty else {
            task?.cancel()
            task = nil
            return
        }
        guard task == nil else {
            Task { [weak self] in await self?.refresh() }
            return
        }

        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    func context(for sessionID: SessionID) -> SessionContext? {
        contexts[sessionID]
    }

    func refresh() async {
        let preferredWindow = claudeWindow.tokens
        let targets = watched.map {
            (
                id: $0.id,
                kind: $0.kind,
                directory: $0.workingDirectory,
                startedAt: $0.startedAt,
                conversationID: ResumedConversation.identifier(in: $0.command, kind: $0.kind),
                // The command outranks the setting: a session started with a
                // model argument is running that model, whatever the setting
                // says about the others.
                declaredWindow: ClaudeModelWindow.declared(byCommand: $0.command) ?? preferredWindow
            )
        }
        guard !targets.isEmpty else { return }

        let found = await Task.detached(priority: .utility) { () -> [SessionID: SessionContext] in
            var result: [SessionID: SessionContext] = [:]
            for target in targets {
                let context: SessionContext? = switch target.kind {
                case .claude:
                    Self.claudeContext(
                        directory: target.directory,
                        startedAt: target.startedAt,
                        conversationID: target.conversationID,
                        declaredWindow: target.declaredWindow
                    )
                case .codex:
                    CodexContextReader.read(
                        workingDirectory: target.directory,
                        startedAt: target.startedAt,
                        conversationID: target.conversationID
                    )
                default:
                    nil
                }
                if let context { result[target.id] = context }
            }
            return result
        }.value

        contexts = found
    }

    /// The transcript reading, widened by what the project is known to run.
    ///
    /// Only where nothing was declared: evidence of the model a project last
    /// billed tokens against is enough to stop a 1M session reading as 64% full
    /// at 127K, and not enough to overrule someone who said outright which
    /// window they are on.
    /// Not on the main actor: it reads two files, and it is called from the
    /// same detached task the other readers are.
    private nonisolated static func claudeContext(
        directory: String,
        startedAt: Date,
        conversationID: String?,
        declaredWindow: Int?
    ) -> SessionContext? {
        guard var context = ClaudeContextReader.read(
            workingDirectory: directory,
            startedAt: startedAt,
            conversationID: conversationID,
            declaredWindow: declaredWindow
        ) else { return nil }

        // Nothing to widen once the reading itself has outgrown the smaller
        // window, and the file this consults is large enough not to be read for
        // an answer that cannot change.
        guard !context.isWindowDeclared,
              context.window != ContextWindow.known.last,
              let model = context.model
        else { return context }
        context.window = ContextWindow.widening(
            context.window,
            toAtLeast: ClaudeModelWindow.lastUsed(forModel: model, directory: directory)
        )
        return context
    }
}
