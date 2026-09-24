import Darwin
import Foundation
import RelayProtocol

/// What the command prints, and where. An answer goes to stdout; a refusal is
/// one line on stderr, or with `--json` the whole answer on stdout, so a
/// program reading it has one place to look.
enum Report {
    /// The app's answer, or the one that stands for it when there was none.
    static func response(
        for result: Result<ControlResponse, ControlClient.Failure>,
        environment: [String: String]
    ) -> ControlResponse {
        switch result {
        case let .success(response): response
        case let .failure(failure): .failure(self.failure(failure, environment: environment))
        }
    }

    static func failure(_ failure: ControlClient.Failure, environment: [String: String]) -> ControlFailure {
        switch failure {
        case let .notRunning(socket):
            ControlFailure(.notRunning, notRunning(socket: socket, environment: environment))
        case let .foreignSocket(socket):
            ControlFailure(
                .notRunning,
                "Relay is not running: \(socket) belongs to another user, and is not to be talked to."
            )
        case .timedOut:
            ControlFailure(
                .badResponse,
                "Relay did not answer in time. It may still have done it: relay worktree list shows what is there."
            )
        case let .badResponse(message):
            ControlFailure(.badResponse, message)
        }
    }

    /// Names the other flavour only when it could be the one meant: a
    /// terminal Relay started already says which app it belongs to.
    static func notRunning(socket: String, environment: [String: String]) -> String {
        let message = "Relay is not running: nothing answers on \(socket). Open Relay and run this again"
        let isNamed = environment[ControlEnvironment.socketKey].map { !$0.isEmpty } ?? false
        let isDevelopment = environment[RelayFlavour.environmentKey].flatMap(RelayFlavour.named) == .development
        return isNamed || isDevelopment ? message + "." : message + ", or set RELAY_FLAVOUR=dev to reach Relay Dev."
    }

    /// Prints the answer and returns the exit status it calls for.
    static func emit(_ response: ControlResponse, for spec: CommandSpec, json: Bool) -> Int32 {
        if json {
            printJSON(response)
        } else if response.ok {
            let text = spec.describe(response)
            if !text.isEmpty { print(text) }
        } else {
            printError(response.error?.message ?? "Relay refused, and did not say why.")
        }
        return response.ok ? 0 : 1
    }

    static func usage(_ error: UsageError, json: Bool) {
        if json {
            printJSON(.failure(ControlFailure(.usage, "\(error.message) See \(error.help).")))
        } else {
            printError("\(error.message)\nSee \(error.help).")
        }
    }

    static func printJSON(_ response: ControlResponse) {
        let encoder = ControlProtocol.makeEncoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        guard let data = try? encoder.encode(response) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data("relay: \(message)\n".utf8))
    }
}
