import Foundation
import RelayProtocol
import RelayUI

/// Something the resources popover can end, held while it asks whether to.
///
/// It always asks. The popover lists every session in every project, most of
/// them not the one on screen, and a cross pressed on the wrong row of a list
/// that reorders itself is an agent's afternoon gone.
enum ResourceClosing: Equatable, Hashable, Sendable {
    case session(SessionID)
    case project(ProjectID)
    case exited
}

/// What ending something would do, worked out before the question is put so
/// that the question can say it.
struct ResourceClosingPlan: Equatable, Sendable {
    /// Terminals and agents, closed — and stopped first when still running.
    var closing: [SessionID] = []
    /// Services, stopped and left in the Services section to start again.
    /// Closing one would take it out of there, and ⌘⇧T would bring it back
    /// as an ordinary terminal.
    var stopping: [SessionID] = []
    /// How many of the closed ones still have something running.
    var running = 0

    var isEmpty: Bool { closing.isEmpty && stopping.isEmpty }

    static func of(_ sessions: [SessionSnapshot]) -> ResourceClosingPlan {
        var plan = ResourceClosingPlan()
        for session in sessions {
            if session.role.isService {
                if session.exitCode == nil { plan.stopping.append(session.id) }
            } else {
                plan.closing.append(session.id)
                if session.exitCode == nil { plan.running += 1 }
            }
        }
        return plan
    }
}

/// The resources popover: every session in every project, with what each
/// costs, and the one place they can all be closed from. The sidebar shows
/// one project at a time, so "which of my twelve terminals is eating the
/// fan" had no answer short of visiting them all.
extension AppModel {
    /// Every live session, and every finished terminal still open. A stopped
    /// service is left out: it costs nothing, and its row is in the Services
    /// section beside the button that starts it again.
    var resourceSessions: [SessionSnapshot] {
        sessionOrder.compactMap { sessions[$0] }.filter { $0.exitCode == nil || !$0.role.isService }
    }

    var exitedResourceSessions: [SessionSnapshot] {
        resourceSessions.filter { $0.exitCode != nil }
    }

    func resourceProjectName(_ id: ProjectID) -> String {
        id == .chat ? relayLocalized("Chat") : project(id)?.name ?? ""
    }

    /// The worktree a session is in, when it is one of its own rather than
    /// the project's folder — the only place the project heading does not
    /// already say.
    func resourceWorktreeName(of session: SessionSnapshot) -> String? {
        guard showsWorktrees(in: session.projectID),
              let worktree = worktree(of: session),
              worktree != homeWorktree(of: session.projectID)
        else { return nil }
        return worktree.name
    }

    func plan(for closing: ResourceClosing) -> ResourceClosingPlan {
        switch closing {
        case let .session(id):
            return ResourceClosingPlan.of(sessions[id].map { [$0] } ?? [])
        case let .project(id):
            return ResourceClosingPlan.of(resourceSessions.filter { $0.projectID == id })
        case .exited:
            return ResourceClosingPlan.of(exitedResourceSessions)
        }
    }

    /// Carries out what the question was about, once it has been answered.
    func end(_ closing: ResourceClosing) {
        let plan = plan(for: closing)
        for id in plan.stopping {
            terminateSession(id)
        }
        for id in plan.closing {
            closeSession(id)
        }
    }

    func toggleResourceProject(_ id: ProjectID) {
        if collapsedResourceProjects.contains(id) {
            collapsedResourceProjects.remove(id)
        } else {
            collapsedResourceProjects.insert(id)
        }
    }

    /// Goes to a session in whichever project it is in.
    func revealSession(_ id: SessionID) {
        guard let session = sessions[id] else { return }
        selectProject(session.projectID)
        selectSession(id)
    }
}
