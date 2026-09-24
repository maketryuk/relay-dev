import Foundation
import Testing

@testable import RelayProtocol

/// The `relay` command and the app come from one bundle, but not always one
/// build: an update replaces the command under a terminal that is still
/// running. These pin the lines both ends write, so a change that would make
/// one unreadable to the other shows up here rather than as a command that
/// quietly does nothing.
@Suite("Control socket wire format")
struct ControlProtocolTests {
    private func line(_ value: some Encodable) throws -> String {
        let data = try ControlProtocol.encodeLine(value)
        #expect(data.last == MessageFraming.delimiter)
        return String(decoding: data.dropLast(), as: UTF8.self)
    }

    private func decoded(_ text: String) -> Result<ControlRequest, ControlFailure> {
        ControlRequest.decode(Data(text.utf8))
    }

    @Test("Every command survives the trip, arguments and all")
    func roundTrip() throws {
        let commands: [ControlCommand] = [
            .worktreeList,
            .worktreeCurrent,
            .worktreeCreate(name: "fix login", base: "origin/main", agent: "claude", prompt: "Fix it\nplease"),
            .worktreeCreate(name: "spike", base: nil, agent: nil, prompt: nil),
            .worktreeRemove(target: "~/.relay/worktrees/shop/spike", force: true),
            .worktreeRemove(target: nil, force: false),
            .worktreeSet(target: "fix", status: .inReview, clearsStatus: false, comment: "ready"),
            .worktreeSet(target: nil, status: nil, clearsStatus: true, comment: ""),
        ]
        for command in commands {
            let request = ControlRequest(directory: "/Users/me/shop", sessionID: "S-1", command: command)
            let data = try ControlProtocol.encodeLine(request)
            #expect(try ControlRequest.decode(data.dropLast()).get() == request)
        }
    }

    @Test("A request is an object with its version, directory and one named command")
    func requestEncoding() throws {
        let request = ControlRequest(
            directory: "/Users/me/shop",
            sessionID: "S-1",
            command: .worktreeCreate(name: "fix", base: nil, agent: "claude", prompt: nil)
        )
        #expect(try line(request) == #"{"command":{"worktreeCreate":{"agent":"claude","name":"fix"}},"directory":"/Users/me/shop","sessionID":"S-1","version":1}"#)
        #expect(try line(ControlRequest(directory: "/", command: .worktreeList))
            == #"{"command":{"worktreeList":{}},"directory":"/","version":1}"#)
    }

    @Test("Each command is encoded under the name the app looks it up by")
    func namesMatchEncodings() throws {
        let samples: [ControlCommand] = [
            .worktreeList,
            .worktreeCurrent,
            .worktreeCreate(name: "a", base: nil, agent: nil, prompt: nil),
            .worktreeRemove(target: nil, force: false),
            .worktreeSet(target: nil, status: nil, clearsStatus: true, comment: nil),
        ]
        #expect(Set(samples.map(\.name)) == Set(ControlCommand.Name.allCases))
        for command in samples {
            let object = try JSONSerialization.jsonObject(with: ControlProtocol.makeEncoder().encode(command))
            #expect((object as? [String: Any])?.keys.first == command.name.rawValue)
        }
    }

    @Test("The statuses and branch outcomes are spelled as the command line spells them")
    func valueSpellings() throws {
        #expect(WorktreeWorkStatus.allCases.map(\.rawValue) == ["todo", "in-progress", "in-review", "completed"])
        #expect(ControlBranchOutcome.allCases.map(\.rawValue) == ["deleted", "kept-unmerged", "untouched"])
        #expect(try line(ControlCommand.worktreeSet(target: nil, status: .inProgress, clearsStatus: false, comment: nil))
            == #"{"worktreeSet":{"clearsStatus":false,"status":"in-progress"}}"#)
    }

    @Test("An answer carries ok, and a refusal its code and sentence")
    func responseEncoding() throws {
        #expect(try line(ControlResponse.failure(ControlFailure(.notInProject, "Not here.")))
            == #"{"error":{"code":"not_in_project","message":"Not here."},"ok":false,"version":1}"#)
        let removed = ControlResponse(
            worktree: ControlWorktree(path: "/w/spike", branch: "spike", name: "spike"),
            branch: .keptUnmerged
        )
        #expect(try line(removed) == #"{"branch":"kept-unmerged","ok":true,"version":1,"worktree":{"branch":"spike","isCurrent":false,"isLocked":false,"isMain":false,"isProjectFolder":false,"name":"spike","path":"/w/spike"}}"#)
    }

    @Test("An answer from a newer app still reads: unknown fields and codes are let through")
    func newerResponsesDecode() throws {
        let text = #"{"version":1,"ok":false,"error":{"code":"quota_exceeded","message":"Later."},"somethingNew":[1,2]}"#
        let response = try MessageFraming.makeDecoder().decode(ControlResponse.self, from: Data(text.utf8))
        #expect(response.error == ControlFailure(ControlFailure.Code(rawValue: "quota_exceeded"), "Later."))
    }

    @Test("A command this build lacks is refused by name, not as a broken line")
    func unknownCommand() {
        let result = decoded(#"{"version":1,"directory":"/","command":{"worktreeArchive":{"target":"x"}}}"#)
        #expect(result.failure?.code == .unknownCommand)
        #expect(result.failure?.message.contains("worktreeArchive") == true)
    }

    @Test("A line that is not a request says so")
    func malformed() {
        #expect(decoded("not json").failure?.code == .badRequest)
        #expect(decoded("[1,2]").failure?.code == .badRequest)
        #expect(decoded(#"{"directory":"/","command":{"worktreeList":{}}}"#).failure?.code == .badRequest)
        #expect(decoded(#"{"version":1,"command":{"worktreeList":{}}}"#).failure?.code == .badRequest)
        #expect(decoded(#"{"version":1,"directory":"/","command":{"worktreeCreate":{}}}"#).failure?.code == .badRequest)
    }

    @Test("A command newer than the app is told to update it")
    func newerVersion() {
        let result = decoded(#"{"version":99,"directory":"/","command":{"worktreeList":{}}}"#)
        #expect(result.failure?.code == .unsupportedVersion)
    }

    @Test("The control socket sits beside the daemon's, one per flavour")
    func socketNaming() {
        let daemon = URL(fileURLWithPath: "/tmp/relay-dev-501.sock")
        #expect(RelayPaths.controlSocketURL(beside: daemon).path == "/tmp/relay-dev-501-control.sock")
        let release = RelayPaths.controlSocketURL(beside: RelayPaths.socketURL(for: .release)).path
        let development = RelayPaths.controlSocketURL(beside: RelayPaths.socketURL(for: .development)).path
        #expect(release != development)
        #expect(release.utf8.count <= UnixSocketAddress.pathLimit)
    }

    @Test("A terminal's socket wins; outside one, the released app unless RELAY_FLAVOUR says Dev")
    func socketChoice() {
        let named = [ControlEnvironment.socketKey: "/tmp/relay-dev-501-control.sock"]
        #expect(ControlEnvironment.socketPath(in: named, bundleIdentifier: nil) == "/tmp/relay-dev-501-control.sock")

        let release = RelayPaths.controlSocketURL(beside: RelayPaths.socketURL(for: .release)).path
        let development = RelayPaths.controlSocketURL(beside: RelayPaths.socketURL(for: .development)).path
        #expect(ControlEnvironment.socketPath(in: [:], bundleIdentifier: nil) == release)
        #expect(ControlEnvironment.socketPath(in: [RelayFlavour.environmentKey: "dev"], bundleIdentifier: nil) == development)
        #expect(ControlEnvironment.socketPath(in: [ControlEnvironment.socketKey: ""], bundleIdentifier: nil) == release)
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }
}
