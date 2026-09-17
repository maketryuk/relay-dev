import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

@Suite("Restarting a session")
struct SessionRestartTests {
    private func snapshot(
        kind: SessionKind,
        name: String = "SSH",
        command: [String],
        workingDirectory: String = "/Users/me/code/relay",
        projectID: ProjectID = .generate(),
        role: SessionRole = .interactive
    ) -> SessionSnapshot {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return SessionSnapshot(
            id: SessionID(rawValue: "s1"),
            projectID: projectID,
            kind: kind,
            name: name,
            workingDirectory: workingDirectory,
            command: command,
            status: .error,
            pid: nil,
            exitCode: 1,
            startedAt: start,
            lastActivityAt: start,
            columns: 118,
            rows: 30,
            role: role
        )
    }

    @Test("An SSH session is reconnected to the host it was connected to")
    func keepsTheSSHDestination() {
        // Rebuilding from the kind gives `ssh` with no destination, which is
        // not a connection but a usage message.
        let spec = SessionRestart.spec(for: snapshot(kind: .ssh, command: ["ssh", "staging"]))
        #expect(spec.command == ["ssh", "staging"])
    }

    @Test("A command with its arguments is started again in full")
    func keepsArguments() {
        let spec = SessionRestart.spec(
            for: snapshot(kind: .claude, name: "Claude", command: ["claude", "--permission-mode", "auto"])
        )
        #expect(spec.command == ["claude", "--permission-mode", "auto"])
    }

    @Test("A shell is still a shell, not a command called empty")
    func keepsAnEmptyCommandEmpty() {
        // An empty command means "the login shell", which is what the spec
        // fills in; it must not be mistaken for something that went missing.
        let spec = SessionRestart.spec(for: snapshot(kind: .shell, name: "Terminal", command: []))
        #expect(spec.command == SessionKind.shell.defaultCommand)
    }

    @Test("The session comes back where it was, called what it was called")
    func keepsPlaceAndName() {
        let spec = SessionRestart.spec(
            for: snapshot(kind: .ssh, name: "bastion", command: ["ssh", "bastion"], workingDirectory: "/tmp/sub")
        )
        #expect(spec.name == "bastion")
        #expect(spec.workingDirectory == "/tmp/sub")
    }

    @Test("It comes back in its own project, not in whichever one is in front")
    func keepsItsProject() {
        let owner = ProjectID.generate()
        let spec = SessionRestart.spec(for: snapshot(kind: .ssh, command: ["ssh", "staging"], projectID: owner))
        #expect(spec.projectID == owner)
    }

    @Test("A service restarted from its pane is still a service")
    func keepsTheRole() {
        // Losing the role leaves the service panel with a running process it no
        // longer recognises as the service it started.
        let spec = SessionRestart.spec(
            for: snapshot(kind: .custom, name: "Dev", command: ["pnpm", "dev"], role: .service(id: "dev"))
        )
        #expect(spec.role == .service(id: "dev"))
    }
}
