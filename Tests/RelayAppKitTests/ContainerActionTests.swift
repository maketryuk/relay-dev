import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

@Suite("Container actions")
struct ContainerActionTests {
    private let container = DockerContainer(
        id: "abc",
        name: "shop.php",
        service: "php",
        state: "running"
    )

    @Test("A shell is opened inside the container, attached to a terminal")
    func shellExecsInteractively() {
        let arguments = ContainerAction.shell.arguments(for: container)
        // Both flags matter: without a TTY there is no prompt, and without
        // --interactive there is nothing to type into it.
        #expect(arguments.starts(with: ["exec", "--interactive", "--tty", "shop.php"]))
        #expect(arguments.contains("sh"))
    }

    @Test("Bash is preferred, and its absence is asked about rather than tried")
    func fallsBackToShWithoutRisking() {
        // A failed `exec` ends the shell instead of carrying on, so a fallback
        // written as `exec bash || exec sh` would never reach the `sh`.
        #expect(ContainerAction.preferredShell.contains("command -v bash"))
        #expect(ContainerAction.preferredShell.contains("exec sh"))
        #expect(ContainerAction.preferredShell.hasPrefix("exec bash") == false)
    }

    @Test("What is watched gets a terminal and what merely happens does not")
    func onlyTheReadableOnesTakeASession() {
        #expect(ContainerAction.shell.needsTerminal)
        #expect(ContainerAction.logs.needsTerminal)
        #expect(ContainerAction.start.needsTerminal == false)
        #expect(ContainerAction.stop.needsTerminal == false)
        #expect(ContainerAction.restart.needsTerminal == false)
    }

    @Test("Each action names its own session")
    func sessionsAreNamedAfterTheAction() {
        // Two terminals on the same container are a log and a prompt, and the
        // list has to say which is which.
        #expect(ContainerAction.shell.sessionPrefix == "shell")
        #expect(ContainerAction.logs.sessionPrefix == "logs")
    }

    @Test("The other actions still address the container by name")
    func lifecycleActionsAreUnchanged() {
        #expect(ContainerAction.start.arguments(for: container) == ["start", "shop.php"])
        #expect(ContainerAction.stop.arguments(for: container) == ["stop", "shop.php"])
        #expect(ContainerAction.restart.arguments(for: container) == ["restart", "shop.php"])
    }
}
