import Darwin
import Foundation
import RelayProtocol

// The command an agent's hook runs inside a Relay terminal: read what the
// agent says on stdin, send the part a status needs to the daemon, and get out
// of the way. It must never fail the agent, so every path ends in exit 0.

let agent = CommandLine.arguments.dropFirst().first.flatMap(AgentHookEvent.Agent.init(rawValue:))

// Claude reads a hook's stdout as its decision, and treats a permission hook
// that says nothing as one that refused. An empty object is "no opinion", so
// Claude goes on to ask the person as it would have. It is written before
// anything else can go wrong.
if agent == .claude {
    FileHandle.standardOutput.write(Data("{}\n".utf8))
}

// All of it, even when it will not be used: an agent writing to a pipe nobody
// reads can block on it.
let payload = FileHandle.standardInput.readDataToEndOfFile()

/// What a subagent was asked to do, from the note Claude Code keeps on it:
/// its own events never say. The note is written a moment after the subagent
/// starts, so its first event may find none, and a later one will.
func assignment(of event: AgentHookEvent, transcriptPath: String?) -> AgentHookEvent.Delegation? {
    guard let agentID = event.subagentID,
          let transcriptPath,
          let url = AgentHookEvent.Delegation.noteURL(transcriptPath: transcriptPath, agentID: agentID),
          let file = FileHandle(forReadingAtPath: url.path)
    else { return nil }
    defer { try? file.close() }
    // A note is a couple of hundred bytes; anything much longer is not one.
    guard let note = try? file.read(upToCount: 16 * 1024) else { return nil }
    return AgentHookEvent.Delegation(note: note, agentID: agentID)
}

let environment = ProcessInfo.processInfo.environment
if let agent,
   let sessionID = environment[AgentHookEnvironment.sessionKey],
   let socket = environment[AgentHookEnvironment.socketKey],
   let read = AgentHookPayload(
       payload,
       agent: agent,
       sessionID: sessionID,
       ancestry: ProcessAncestor.ofCurrentProcess()
   ) {
    var event = read.event
    event.assignment = assignment(of: event, transcriptPath: read.transcriptPath)
    AgentHookDelivery.send(event, to: socket)
}
exit(0)
