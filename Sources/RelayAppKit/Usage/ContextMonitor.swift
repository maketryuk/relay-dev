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
        let targets = watched.map {
            (
                id: $0.id,
                kind: $0.kind,
                directory: $0.workingDirectory,
                startedAt: $0.startedAt,
                conversationID: ResumedConversation.identifier(in: $0.command, kind: $0.kind)
            )
        }
        guard !targets.isEmpty else { return }

        let found = await Task.detached(priority: .utility) { () -> [SessionID: SessionContext] in
            var result: [SessionID: SessionContext] = [:]
            for target in targets {
                let context: SessionContext? = switch target.kind {
                case .claude:
                    ClaudeContextReader.read(
                        workingDirectory: target.directory,
                        startedAt: target.startedAt,
                        conversationID: target.conversationID
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
}
