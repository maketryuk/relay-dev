import Foundation

/// YouTrack, through its REST API and a permanent token.
public struct YouTrackTracker: IssueTracker {
    public let connection: YouTrackConnection
    private let transport: any TrackerTransport

    /// Long enough for a board of a few hundred cards on a slow connection;
    /// short enough that a dead one says so before the person gives up on it.
    static let timeout: TimeInterval = 20

    /// A read is asked again this many times when the failure could pass.
    /// A write never is: see `TrackerError.Kind.uncertain`.
    static let readRetries = 2

    public init(connection: YouTrackConnection, transport: any TrackerTransport = URLSessionTransport()) {
        self.connection = connection
        self.transport = transport
    }

    public func currentUser() async throws -> TrackerUser {
        let wire: YouTrackWire.User = try await perform(YouTrackAPI.currentUser())
        guard let user = YouTrackMapping.user(wire) else { throw TrackerError(.notTheAPI) }
        return user
    }

    public func boards() async throws -> [TrackerBoard] {
        let wire: [YouTrackWire.Board] = try await perform(YouTrackAPI.boards())
        return wire.map(YouTrackMapping.board).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func snapshot(of board: TrackerBoard, sprint: String?) async throws -> BoardSnapshot {
        // The columns are read again with the cards rather than taken from the
        // list of boards: that list may be an hour old, and a column added
        // since would leave its cards nowhere.
        let fresh: YouTrackWire.Board = try await perform(YouTrackAPI.board(board.id))
        let current = YouTrackMapping.board(fresh)
        guard let sprintID = sprint ?? Self.sprintToShow(on: current) else {
            return BoardSnapshot(
                board: current,
                columnField: fresh.columnSettings?.field?.name,
                columns: YouTrackMapping.columns(fresh.columnSettings)
            )
        }
        let wire: YouTrackWire.Sprint = try await perform(YouTrackAPI.sprint(sprintID, of: board.id))
        return YouTrackMapping.snapshot(of: current, settings: fresh.columnSettings, sprint: wire)
    }

    /// The current sprint, or on a board that has not named one, the newest
    /// that is still open. A board without sprints has exactly one, hidden.
    static func sprintToShow(on board: TrackerBoard) -> String? {
        if let current = board.currentSprintID { return current }
        let open = board.sprints.filter { !$0.isArchived }
        let newest = open.max { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        return newest?.id ?? board.sprints.last?.id
    }

    public func issue(_ key: String) async throws -> TrackerIssue {
        let wire: YouTrackWire.Issue = try await perform(YouTrackAPI.issue(key))
        return YouTrackMapping.issue(wire)
    }

    public func comments(on key: String) async throws -> [TrackerComment] {
        let wire: [YouTrackWire.Comment] = try await perform(YouTrackAPI.comments(on: key))
        // A comment deleted in YouTrack is still listed, marked, so it can be
        // restored there; it is not part of the conversation.
        return wire.filter { $0.deleted != true }.map(YouTrackMapping.comment).sorted { $0.created < $1.created }
    }

    public func updateComment(_ commentID: String, text: String, on key: String) async throws -> TrackerComment {
        let wire: YouTrackWire.Comment = try await perform(YouTrackAPI.updateComment(commentID, text: text, on: key))
        return YouTrackMapping.comment(wire)
    }

    public func deleteComment(_ commentID: String, on key: String) async throws {
        _ = try await send(YouTrackAPI.deleteComment(commentID, on: key))
    }

    public func addComment(_ text: String, on key: String) async throws -> TrackerComment {
        let wire: YouTrackWire.Comment = try await perform(YouTrackAPI.addComment(text, on: key))
        return YouTrackMapping.comment(wire)
    }

    public func workItems(on key: String) async throws -> [TrackerWorkItem] {
        let wire: [YouTrackWire.WorkItem] = try await perform(YouTrackAPI.workItems(on: key))
        return wire.map(YouTrackMapping.workItem).sorted { $0.date > $1.date }
    }

    public func workTypes(in project: TrackerProject) async throws -> [TrackerWorkType] {
        do {
            let wire: YouTrackWire.TimeTrackingSettings = try await perform(YouTrackAPI.workTypes(in: project.id))
            return YouTrackMapping.workTypes(wire)
        } catch let error as TrackerError where error.kind == .forbidden || error.kind == .notFound {
            // The settings are an administrator's page, and an account that
            // may log time need not be allowed to read it. Time is still
            // logged, just without a kind.
            return []
        }
    }

    public func logWork(_ entry: WorkEntry, on key: String) async throws -> TrackerWorkItem {
        let wire: YouTrackWire.WorkItem = try await perform(YouTrackAPI.logWork(entry, on: key))
        return YouTrackMapping.workItem(wire)
    }

    public func updateWork(_ itemID: String, with entry: WorkEntry, on key: String) async throws -> TrackerWorkItem {
        let wire: YouTrackWire.WorkItem = try await perform(YouTrackAPI.updateWork(itemID, with: entry, on: key))
        return YouTrackMapping.workItem(wire)
    }

    public func deleteWork(_ itemID: String, on key: String) async throws {
        _ = try await send(YouTrackAPI.deleteWork(itemID, on: key))
    }

    public func move(_ card: TrackerCard, to column: BoardColumn, on snapshot: BoardSnapshot) async throws -> TrackerCard {
        guard let field = snapshot.columnField, let value = column.values.first,
              let wireType = card.field(named: field)?.wireType ?? snapshot.columnFieldWireType()
        else { throw TrackerError(.rejected) }
        if wireType == YouTrackAPI.stateMachine {
            let query = YouTrackAPI.commandQuery(field: field, value: value)
            // The answer says nothing the card read after it does not.
            _ = try await send(YouTrackAPI.command(query, on: card.key))
            let wire: YouTrackWire.Issue = try await perform(YouTrackAPI.card(card.key))
            return YouTrackMapping.card(wire)
        }
        let request = YouTrackAPI.setColumn(of: card.key, field: field, wireType: wireType, value: value)
        let wire: YouTrackWire.Issue = try await perform(request)
        return YouTrackMapping.card(wire)
    }

    public func update(_ key: String, with change: IssueChange) async throws -> TrackerIssue {
        // A state a state machine governs is moved by command, one field at a
        // time; everything else goes in one write.
        var direct = change
        direct.fields = change.fields.filter { $0.field.wireType != YouTrackAPI.stateMachine }
        if !direct.isEmpty {
            _ = try await perform(YouTrackAPI.update(key, with: direct)) as YouTrackWire.Issue
        }
        for transition in change.fields where transition.field.wireType == YouTrackAPI.stateMachine {
            guard let value = transition.values.first else { continue }
            let query = YouTrackAPI.commandQuery(field: transition.field.name, value: value.name)
            _ = try await send(YouTrackAPI.command(query, on: key))
        }
        // Read again in full: the answer to a write carries the fields but not
        // the values each could take, and the issue pane edits with those.
        return try await issue(key)
    }

    public func create(_ draft: IssueDraft, in column: BoardColumn?, on snapshot: BoardSnapshot) async throws -> CreatedIssue {
        let created: YouTrackWire.Issue = try await perform(YouTrackAPI.create(draft))
        var card = YouTrackMapping.card(created)

        // From here on the issue exists, so nothing that goes wrong may be
        // reported as it not having been made. Onto the board first, since a
        // card on the board in the wrong column is found, and one off it is not.
        do {
            if snapshot.board.addsCardsByHand, let sprint = snapshot.sprint {
                let request = YouTrackAPI.addToSprint(issueID: card.id, sprintID: sprint.id, boardID: snapshot.board.id)
                _ = try await send(request)
            }
            // The new issue carries the project's default, which is rarely the
            // column it was made in; its own kind of field is known now, which
            // it could not be before the issue existed.
            if let column, snapshot.column(of: card)?.id != column.id {
                card = try await move(card, to: column, on: snapshot)
            }
        } catch {
            return CreatedIssue(card: card, misplaced: error as? TrackerError ?? TrackerError(.uncertain))
        }
        return CreatedIssue(card: card)
    }

    public func webURL(for key: String) -> URL {
        connection.baseURL.appendingPathComponent("issue").appendingPathComponent(key)
    }

    public func resolve(_ link: String) -> URL? {
        Self.resolve(link, against: connection.baseURL)
    }

    /// YouTrack writes an attachment as `/api/files/…` and an avatar as
    /// `/hub/api/rest/avatar/…`: from the host's root, and already including
    /// the path an instance under one lives at. So a leading slash is the
    /// host's; anything else is below the instance.
    static func resolve(_ link: String, against base: URL) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil { return absolute }
        let directory = base.absoluteString.hasSuffix("/") ? base : base.appendingPathComponent("")
        // Escaped only when it has to be, so a link written escaped already
        // is not escaped twice.
        let written = URL(string: trimmed) != nil
            ? trimmed
            : trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? trimmed
        return URL(string: written, relativeTo: directory)?.absoluteURL
    }

    public func contents(of url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        // The token goes only where it came from: an avatar hosted elsewhere
        // is fetched as anybody would fetch it.
        if Self.isOwn(url, base: connection.baseURL) {
            request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as TrackerError {
            throw error
        } catch {
            throw TrackerError(.unreachable)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw YouTrackMapping.failure(status: response.statusCode, body: data, location: nil, isWrite: false)
        }
        return data
    }

    static func isOwn(_ url: URL, base: URL) -> Bool {
        url.scheme?.lowercased() == base.scheme?.lowercased()
            && url.host?.lowercased() == base.host?.lowercased()
            && url.port == base.port
    }

    // MARK: - Transport

    private func perform<Answer: Decodable>(_ request: YouTrackRequest) async throws -> Answer {
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw TrackerError(.notTheAPI)
        }
    }

    private func send(_ request: YouTrackRequest) async throws -> Data {
        let attempts = request.isWrite ? 1 : Self.readRetries + 1
        var attempt = 1
        while true {
            do {
                return try await sendOnce(request)
            } catch let error as TrackerError where error.isTransient && attempt < attempts {
                try await Task.sleep(for: .milliseconds(300 << (attempt - 1)))
                attempt += 1
            }
        }
    }

    private func sendOnce(_ request: YouTrackRequest) async throws -> Data {
        let urlRequest = request.urlRequest(for: connection, timeout: Self.timeout)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch let error as TrackerError {
            throw error
        } catch let error as URLError {
            // A write that went out and heard nothing back may have been made;
            // one that never found the server certainly was not.
            if request.isWrite, !Self.neverSent.contains(error.code) { throw TrackerError(.uncertain) }
            throw TrackerError(error.code == .timedOut ? .timedOut : .unreachable)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw YouTrackMapping.failure(
                status: response.statusCode,
                body: data,
                location: response.value(forHTTPHeaderField: "Location"),
                isWrite: request.isWrite
            )
        }
        return data
    }

    /// Failures that happen before a request leaves the machine.
    private static let neverSent: Set<URLError.Code> = [
        .badURL, .unsupportedURL, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
        .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
        .appTransportSecurityRequiresSecureConnection,
    ]
}
