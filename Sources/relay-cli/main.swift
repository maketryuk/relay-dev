import Darwin
import Foundation
import RelayProtocol

// `relay`: what an agent, or a person, runs in a Relay terminal to have the
// app do something — take the words apart, ask the app, print its answer.
// Exit status: 0 done, 1 refused or failed, 2 not a command.

let environment = ProcessInfo.processInfo.environment

switch CommandParser.parse(Array(CommandLine.arguments.dropFirst())) {
case let .help(text):
    print(text)
    exit(0)
case .version:
    print("relay \(RelayVersion.current)")
    exit(0)
case let .usage(error, json):
    Report.usage(error, json: json)
    exit(2)
case let .run(run):
    let socket = ControlEnvironment.socketPath(in: environment, bundleIdentifier: Bundle.main.bundleIdentifier)
    let request = ControlRequest(
        directory: FileManager.default.currentDirectoryPath,
        sessionID: environment[AgentHookEnvironment.sessionKey],
        command: run.command
    )
    let result = ControlClient.send(request, to: socket, timeout: run.spec.timeout)
    exit(Report.emit(Report.response(for: result, environment: environment), for: run.spec, json: run.json))
}
