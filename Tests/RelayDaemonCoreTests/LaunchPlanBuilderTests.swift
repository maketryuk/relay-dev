import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

@Suite("Launch plan construction")
struct LaunchPlanBuilderTests {
    private func spec(kind: SessionKind, command: [String] = [], directory: String = "/tmp") -> SessionSpec {
        SessionSpec(
            projectID: .generate(),
            kind: kind,
            name: "Test",
            workingDirectory: directory,
            command: command
        )
    }

    @Test("A shell session launches the login shell interactively")
    func shellLaunchesLoginShell() {
        let plan = LaunchPlanBuilder.makePlan(for: spec(kind: .shell))
        #expect(plan.arguments == ["-l"])
        #expect(FileManager.default.isExecutableFile(atPath: plan.executable))
    }

    @Test("Agents run through an interactive login shell so PATH resolves")
    func agentsRunThroughLoginShell() {
        // `claude` is typically installed by nvm/mise/Homebrew, none of which are
        // on a GUI process's inherited PATH.
        let plan = LaunchPlanBuilder.makePlan(for: spec(kind: .claude))
        #expect(plan.arguments.count == 2)
        #expect(plan.arguments[0] == "-lic")
        #expect(plan.arguments[1] == "exec claude")
    }

    @Test("Arguments needing quoting are escaped")
    func quotesUnsafeArguments() {
        let plan = LaunchPlanBuilder.makePlan(
            for: spec(kind: .custom, command: ["echo", "hello world", "it's"])
        )
        #expect(plan.arguments[1] == "exec echo 'hello world' 'it'\\''s'")
    }

    @Test("Safe argument characters are left unquoted")
    func leavesSafeArgumentsAlone() {
        let plan = LaunchPlanBuilder.makePlan(
            for: spec(kind: .custom, command: ["npm", "run", "dev", "--port=3000"])
        )
        #expect(plan.arguments[1] == "exec npm run dev --port=3000")
    }

    @Test("A missing working directory falls back to home")
    func fallsBackToHomeDirectory() {
        let plan = LaunchPlanBuilder.makePlan(
            for: spec(kind: .shell, directory: "/definitely/not/a/real/path")
        )
        #expect(plan.workingDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test("An existing working directory is honoured")
    func honoursWorkingDirectory() {
        let plan = LaunchPlanBuilder.makePlan(for: spec(kind: .shell, directory: "/usr"))
        #expect(plan.workingDirectory == "/usr")
    }

    @Test("Terminal environment advertises colour support")
    func environmentIsTerminalReady() {
        let plan = LaunchPlanBuilder.makePlan(for: spec(kind: .shell))
        #expect(plan.environment["TERM"] == "xterm-256color")
        #expect(plan.environment["COLORTERM"] == "truecolor")
        #expect(plan.environment["TERM_PROGRAM"] == "Relay")
        #expect(plan.environment["RELAY_SESSION"] == "1")
        #expect(plan.environment["LANG"] != nil)
    }

    @Test("XPC variables inherited from the GUI are not passed to children")
    func stripsXPCEnvironment() {
        let plan = LaunchPlanBuilder.makePlan(for: spec(kind: .shell))
        #expect(plan.environment["XPC_SERVICE_NAME"] == nil)
        #expect(plan.environment["XPC_FLAGS"] == nil)
    }

    @Test("Caller-supplied environment overrides the defaults")
    func customEnvironmentWins() {
        var custom = spec(kind: .shell)
        custom.environment = ["TERM": "dumb", "MY_VAR": "value"]
        let plan = LaunchPlanBuilder.makePlan(for: custom)
        #expect(plan.environment["TERM"] == "dumb")
        #expect(plan.environment["MY_VAR"] == "value")
    }

    @Test("The window size requested by the client is carried through")
    func carriesWindowSize() {
        var sized = spec(kind: .shell)
        sized.columns = 132
        sized.rows = 43
        let plan = LaunchPlanBuilder.makePlan(for: sized)
        #expect(plan.columns == 132)
        #expect(plan.rows == 43)
    }
}

@Suite("Inherited session markers")
struct InheritedEnvironmentTests {
    private let launched: [String: String] = [
        "PATH": "/usr/bin",
        "HOME": "/Users/me",
        "CLAUDECODE": "1",
        "CLAUDE_CODE_CHILD_SESSION": "1",
        "CLAUDE_CODE_SESSION_ID": "abc",
        "CLAUDE_PID": "4242",
        "XPC_SERVICE_NAME": "0",
        "MY_OWN_VAR": "keep me",
    ]

    @Test("A session does not inherit the agent session Relay was launched from")
    func stripsAgentMarkers() {
        // Left in place, a Claude session spawned here decides it is a child of
        // the one that launched Relay and turns its own transcript saving off.
        let environment = LaunchPlanBuilder.makeEnvironment(extra: [:], base: launched)
        #expect(environment["CLAUDECODE"] == nil)
        #expect(environment["CLAUDE_CODE_CHILD_SESSION"] == nil)
        #expect(environment["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(environment["CLAUDE_PID"] == nil)
    }

    @Test("Everything else the user set is passed through untouched")
    func keepsTheRest() {
        // Stripping widely would break the shell setup people actually rely on.
        let environment = LaunchPlanBuilder.makeEnvironment(extra: [:], base: launched)
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["MY_OWN_VAR"] == "keep me")
    }

    @Test("The launcher's own noise is dropped too")
    func stripsLauncherNoise() {
        #expect(LaunchPlanBuilder.makeEnvironment(extra: [:], base: launched)["XPC_SERVICE_NAME"] == nil)
    }

    @Test("A caller may still set anything it likes, including a stripped name")
    func callerWins() {
        // The filter is about what was inherited, not about what Relay is asked
        // to pass on purpose.
        let environment = LaunchPlanBuilder.makeEnvironment(
            extra: ["CLAUDE_CODE_SESSION_ID": "deliberate"],
            base: launched
        )
        #expect(environment["CLAUDE_CODE_SESSION_ID"] == "deliberate")
    }

    @Test("Relay still says which terminal this is")
    func setsItsOwnMarkers() {
        let environment = LaunchPlanBuilder.makeEnvironment(extra: [:], base: launched)
        #expect(environment["TERM_PROGRAM"] == "Relay")
        #expect(environment["RELAY_SESSION"] == "1")
    }
}
