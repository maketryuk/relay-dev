import Foundation
import RelayProtocol
import RelayUI

/// The project that is not one.
///
/// Sometimes the question has nothing to do with any codebase — how a flag
/// works, what a command does, what to call something. Answering it used to
/// mean leaving Relay for a terminal, or adopting a directory as a project to
/// hold a conversation that was never about it, and the rail filled with
/// projects nobody was working on.
///
/// It is modelled as a `Project` rather than as a session with no project
/// because everything a session needs is keyed by one: the pane layout, the
/// last-selected session, the order the rows are in, the history. A nullable
/// project identifier would have put a `nil` branch through all of it to save
/// one directory that has to exist anyway — the agent has to be started
/// somewhere, and "somewhere" is what this is.
///
/// What it is not: it is never in `projects`, so it cannot be removed,
/// reordered, renamed or configured, and nothing about it is written to the
/// workspace file except the sessions that happen to be in it.
extension ProjectID {
    /// Fixed, because it is written into the workspace file as the key of the
    /// layout and the selection. A generated one would lose both on relaunch.
    static let chat = ProjectID(rawValue: "relay.chat")
}

extension Project {
    /// Main-actor isolated because its name is localised, and the language is
    /// interface state. Every caller is a view or the model, so this costs
    /// nothing.
    @MainActor
    static var chat: Project {
        Project(
            id: .chat,
            name: relayLocalized("Chat"),
            rootPath: RelayPaths.chatDirectory.path,
            // Fixed rather than "now": the value is compared every time SwiftUI
            // asks whether the tile changed, and a clock in it means it always
            // has.
            createdAt: Date(timeIntervalSince1970: 0),
            defaultAgent: .claude
        )
    }

    var isChat: Bool { id == .chat }
}
