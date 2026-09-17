import RelayProtocol

/// What starting a session again means.
///
/// Extracted from the button so the rule can be stated once and tested: a
/// session is its command, its directory and its name, not merely its kind.
/// Restarting from the kind alone turned `ssh staging` into a bare `ssh`, which
/// answers with a usage message, and a running service into an ordinary
/// terminal the service panel no longer recognised.
enum SessionRestart {
    static func spec(for session: SessionSnapshot) -> SessionSpec {
        SessionSpec(
            projectID: session.projectID,
            kind: session.kind,
            name: session.name,
            workingDirectory: session.workingDirectory,
            command: session.command,
            columns: session.columns,
            rows: session.rows,
            role: session.role
        )
    }
}
