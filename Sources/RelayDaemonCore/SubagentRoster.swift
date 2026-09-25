import Foundation
import RelayProtocol

/// The subagents a session's agent has started, as its hooks tell of them.
///
/// Claude Code says when a subagent starts and stops, and every event from one
/// carries its id, its type and the directory it works in. What none of them
/// carries is what it was asked to do: that is in the parent's call to the
/// `Agent` tool, which names no agent until it returns — at once for a
/// background agent, only at the end for a foreground one. So a row's
/// description comes from whichever of these says so first, most certain
/// first:
///
/// 1. something that names both — the call's answer, Claude Code's note on the
///    subagent (read by the helper), its list of background tasks;
/// 2. elimination: the one call of that type still waiting for its agent when
///    the agent started. Two of a type started together are never guessed
///    between, and anything that names the pair later replaces the guess.
///
/// A value type with the clock passed in, like the tracker it belongs to.
struct SubagentRoster {
    /// Rows kept per session. Past it, the oldest finished row goes first.
    static let capacity = 12
    /// Calls to `Agent` remembered while they wait for their agent.
    static let pendingCapacity = 16
    /// How long a finished row stays up: long enough to be seen on a glance
    /// back at the sidebar, short enough that the sidebar is not a history.
    static let finishedLinger: TimeInterval = 2 * 60
    /// A subagent that has said nothing for this long is taken off the list.
    /// The tracker's own measure of a hook worth believing: a background agent
    /// can sit through a long build without a word, so anything short would
    /// take working agents away.
    static let silenceLimit: TimeInterval = AgentStatusTracker.hookFreshness
    /// How long a background agent finishing keeps its parent's turn open.
    /// Claude Code hands the result back as a new prompt within a fraction of
    /// a second, and without this the session would flicker to finished and
    /// back in between.
    static let handoffGrace: TimeInterval = 3

    struct Subagent: Equatable {
        enum State: Equatable {
            case working
            case waiting(AgentStatusTracker.Wait)
            case finished
        }

        var id: String
        var agentType: String?
        var description: String?
        /// Chosen by elimination, and replaced by anything that names it.
        var isDescriptionInferred = false
        var toolUseID: String?
        var workingDirectory: String?
        /// Nil while nothing has said.
        var runsInBackground: Bool?
        var state: State
        var startedAt: Date
        var heardAt: Date
        var finishedAt: Date?

        var isActive: Bool { state != .finished }
    }

    private struct PendingCall: Equatable {
        var toolUseID: String
        var description: String?
        var agentType: String?
        var runsInBackground: Bool?
        var claimedBy: String?
    }

    private(set) var agents: [Subagent] = []
    private var pending: [PendingCall] = []
    private var lastBackgroundFinish: Date?

    var snapshots: [SubagentSnapshot] {
        agents.map { agent in
            SubagentSnapshot(
                id: agent.id,
                agentType: agent.agentType,
                description: agent.description,
                workingDirectory: agent.workingDirectory,
                status: agent.status,
                runsInBackground: agent.runsInBackground ?? false,
                startedAt: agent.startedAt,
                finishedAt: agent.finishedAt
            )
        }
    }

    /// Whether the parent's turn is still going on without it: a subagent of
    /// its is at work in the background, or one has just finished and its
    /// result is on the way back to the parent.
    func holdsTurnOpen(endedAt turnEnd: Date, now: Date) -> Bool {
        if agents.contains(where: { $0.isActive && $0.runsInBackground == true }) { return true }
        guard let finish = lastBackgroundFinish, finish >= turnEnd else { return false }
        return now.timeIntervalSince(finish) < Self.handoffGrace
    }

    var hasForegroundWork: Bool {
        agents.contains { $0.isActive && $0.runsInBackground != true }
    }

    // MARK: - Events

    mutating func apply(_ event: AgentHookEvent, at now: Date) {
        if let delegation = event.delegation {
            note(delegation, on: event, at: now)
        }
        // Before the event itself, so that a parent's `Stop` knows which of
        // its subagents are running in the background before it ends the rest.
        if let running = event.backgroundAgents {
            reconcile(running, excepting: event.name == "SubagentStop" ? event.subagentID : nil, at: now)
        }
        if let id = event.subagentID {
            hear(from: id, event, at: now)
            return
        }
        switch event.name {
        case "Stop", "StopFailure":
            endForegroundWork(at: now)
            // Every call of the turn has returned by the time it ends.
            pending.removeAll()
        case "SessionStart" where ["startup", "resume", "clear"].contains(event.source ?? ""):
            clear()
        case "SessionEnd":
            clear()
        default:
            break
        }
    }

    /// The parent's turn is over, and a foreground subagent lives inside one.
    /// A background agent this could not tell from one is ended too, and its
    /// next event puts it back.
    @discardableResult
    mutating func endForegroundWork(at now: Date) -> Bool {
        var changed = false
        for index in agents.indices where agents[index].isActive && agents[index].runsInBackground != true {
            finish(at: index, now: now)
            changed = true
        }
        return changed
    }

    /// Time passing: a finished row goes after a while, and a working one that
    /// has gone silent goes too. A waiting one does not: a question is
    /// answered or it is not, and sitting unanswered is not silence.
    @discardableResult
    mutating func expire(now: Date) -> Bool {
        let before = agents.count
        agents.removeAll { agent in
            switch agent.state {
            case .finished:
                return now.timeIntervalSince(agent.finishedAt ?? agent.heardAt) >= Self.finishedLinger
            case .working:
                return now.timeIntervalSince(agent.heardAt) >= Self.silenceLimit
            case .waiting:
                return false
            }
        }
        return agents.count != before
    }

    mutating func clear() {
        agents.removeAll()
        pending.removeAll()
        lastBackgroundFinish = nil
    }

    // MARK: - Calls that start agents

    private mutating func note(_ delegation: AgentHookEvent.Delegation, on event: AgentHookEvent, at now: Date) {
        guard let call = delegation.toolUseID ?? event.toolUseID else { return }
        switch event.name {
        case "PreToolUse":
            guard !pending.contains(where: { $0.toolUseID == call }) else { return }
            pending.append(PendingCall(
                toolUseID: call,
                description: delegation.description,
                agentType: delegation.agentType,
                runsInBackground: delegation.runsInBackground
            ))
            if pending.count > Self.pendingCapacity { pending.removeFirst(pending.count - Self.pendingCapacity) }

        case "PostToolUse":
            pending.removeAll { $0.toolUseID == call }
            guard let id = delegation.agentID else { return }
            var named = delegation
            named.toolUseID = call
            // A background call answers the moment its agent has started, and
            // may overtake the agent's own first event on the way here.
            link(id, to: named, creatingIfRunning: delegation.runsInBackground == true, at: now)

        case "PostToolUseFailure":
            pending.removeAll { $0.toolUseID == call }
            // A call that failed has no work going on under it any more.
            agents.removeAll { $0.toolUseID == call && $0.isActive && $0.runsInBackground != true }

        default:
            break
        }
    }

    /// Something has named the agent and its task together.
    private mutating func link(
        _ id: String,
        to delegation: AgentHookEvent.Delegation,
        creatingIfRunning: Bool,
        at now: Date
    ) {
        let index: Int
        if let existing = agents.firstIndex(where: { $0.id == id }) {
            index = existing
        } else {
            guard creatingIfRunning else { return }
            index = insert(Subagent(id: id, state: .working, startedAt: now, heardAt: now))
        }
        if let description = delegation.description {
            agents[index].description = description
            agents[index].isDescriptionInferred = false
        }
        if let call = delegation.toolUseID {
            agents[index].toolUseID = call
            // A guess that gave this call's task to another agent was wrong.
            for other in agents.indices where other != index
                && agents[other].isDescriptionInferred && agents[other].toolUseID == call {
                agents[other].description = nil
                agents[other].toolUseID = nil
                agents[other].isDescriptionInferred = false
            }
            if let claimed = pending.firstIndex(where: { $0.toolUseID == call }) {
                pending[claimed].claimedBy = id
            }
        }
        if agents[index].agentType == nil { agents[index].agentType = delegation.agentType }
        if let background = delegation.runsInBackground { agents[index].runsInBackground = background }
    }

    // MARK: - Events from the subagents

    private mutating func hear(from id: String, _ event: AgentHookEvent, at now: Date) {
        let index: Int
        if let existing = agents.firstIndex(where: { $0.id == id }) {
            index = existing
        } else {
            // Nothing to show for an agent first heard of as it finished.
            guard event.name != "SubagentStop" else { return }
            index = insert(Subagent(
                id: id,
                agentType: event.agentType,
                workingDirectory: event.workingDirectory,
                state: .working,
                startedAt: now,
                heardAt: now
            ))
            if event.assignment?.description == nil { inferTask(of: index) }
        }
        agents[index].heardAt = now
        if let type = event.agentType { agents[index].agentType = type }
        if let directory = event.workingDirectory { agents[index].workingDirectory = directory }
        if let assignment = event.assignment {
            link(id, to: assignment, creatingIfRunning: false, at: now)
        }

        switch event.name {
        case "SubagentStop":
            finish(at: index, now: now)
        case "SubagentStart":
            resume(at: index)
        default:
            if !agents[index].isActive {
                // Work starting again after a finish is an agent resumed; the
                // other events are stragglers of the turn that ended.
                guard event.name == "PreToolUse" else { return }
                resume(at: index)
            }
            if let wait = AgentStatusTracker.wait(for: event) {
                agents[index].state = .waiting(wait)
            } else if case let .waiting(wait) = agents[index].state, AgentStatusTracker.ends(wait, event) {
                agents[index].state = .working
            }
        }
    }

    private mutating func resume(at index: Int) {
        agents[index].state = .working
        agents[index].finishedAt = nil
    }

    private mutating func finish(at index: Int, now: Date) {
        guard agents[index].isActive else { return }
        agents[index].state = .finished
        agents[index].finishedAt = now
        if agents[index].runsInBackground == true { lastBackgroundFinish = now }
    }

    /// The one call of the agent's type still waiting for an agent, when there
    /// is exactly one. A call's `PreToolUse` finishes before its agent starts,
    /// so the call is among those waiting — but so is every other call of the
    /// type made at the same time, and those are left alone.
    private mutating func inferTask(of index: Int) {
        guard let type = agents[index].agentType else { return }
        let candidates = pending.indices.filter { pending[$0].claimedBy == nil && pending[$0].agentType == type }
        guard candidates.count == 1, let chosen = candidates.first else { return }
        pending[chosen].claimedBy = agents[index].id
        agents[index].description = pending[chosen].description
        agents[index].isDescriptionInferred = pending[chosen].description != nil
        agents[index].toolUseID = pending[chosen].toolUseID
        if let background = pending[chosen].runsInBackground { agents[index].runsInBackground = background }
    }

    /// What Claude Code lists as still running in the background. It names
    /// each agent with its task, and an agent it no longer lists is done.
    /// `SubagentStop` lists the agent stopping as though it were still going,
    /// which is why that one is left to its own event.
    private mutating func reconcile(_ running: [AgentHookEvent.Delegation], excepting stopping: String?, at now: Date) {
        let listed = Set(running.compactMap(\.agentID))
        for entry in running {
            guard let id = entry.agentID, id != stopping else { continue }
            if let index = agents.firstIndex(where: { $0.id == id }) {
                agents[index].runsInBackground = true
                if agents[index].description == nil || agents[index].isDescriptionInferred, let description = entry.description {
                    agents[index].description = description
                    agents[index].isDescriptionInferred = false
                }
                if agents[index].agentType == nil { agents[index].agentType = entry.agentType }
            } else {
                insert(Subagent(
                    id: id,
                    agentType: entry.agentType,
                    description: entry.description,
                    runsInBackground: true,
                    state: .working,
                    startedAt: now,
                    heardAt: now
                ))
            }
        }
        for index in agents.indices where agents[index].isActive && agents[index].runsInBackground == true
            && agents[index].id != stopping && !listed.contains(agents[index].id) {
            finish(at: index, now: now)
        }
    }

    @discardableResult
    private mutating func insert(_ agent: Subagent) -> Int {
        if agents.count >= Self.capacity {
            let victim = agents.indices.filter { !agents[$0].isActive }
                .min { (agents[$0].finishedAt ?? .distantPast) < (agents[$1].finishedAt ?? .distantPast) }
                ?? agents.indices.min { agents[$0].heardAt < agents[$1].heardAt }
            if let victim { agents.remove(at: victim) }
        }
        agents.append(agent)
        return agents.count - 1
    }
}

private extension SubagentRoster.Subagent {
    var status: RuntimeStatus {
        switch state {
        case .working: .working
        case .waiting: .waiting
        case .finished: .finished
        }
    }
}
