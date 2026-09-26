import AppKit
import Foundation
import Observation
import RelayProtocol
import RelayTracker
import RelayUI

/// The issue tracker as the window sees it: whether it is connected, the
/// boards, what has been read of them, and the timer.
///
/// Nothing here asks the tracker anything until something on screen needs the
/// answer. A board is read when it is opened and while it stays open; an issue
/// when it is. With the tracker switched off this is an empty object that never
/// touches the network.
@MainActor
@Observable
final class TrackerController {
    enum Connection: Equatable {
        /// No tracker chosen.
        case off
        /// A tracker is chosen, and there is no token for it in the keychain.
        case needsToken
        case checking
        case connected(TrackerUser)
        /// The last request was refused in a way only a new token mends.
        case failed(TrackerError)
    }

    private(set) var settings = TrackerSettings()
    private(set) var connection: Connection = .off
    private(set) var boards: [TrackerBoard] = []
    private(set) var isReadingBoards = false
    private(set) var boardsFailure: TrackerError?
    /// What each board was last read as, by board.
    private(set) var snapshots: [String: BoardSnapshot] = [:]
    private(set) var boardsBeingRead: Set<String> = []
    private(set) var boardFailures: [String: TrackerError] = [:]
    /// The sprint each board is being looked at in. Absent is its current one,
    /// which is what a board is opened on.
    private(set) var chosenSprints: [String: String] = [:]
    /// Cards dropped in a column whose move the tracker has not answered yet.
    private(set) var cardsMoving: Set<String> = []
    /// Issues read in full, by key.
    private(set) var issues: [String: TrackerIssue] = [:]
    private(set) var issuesBeingRead: Set<String> = []
    private(set) var issueFailures: [String: TrackerError] = [:]
    private(set) var comments: [String: [TrackerComment]] = [:]
    private(set) var workItems: [String: [TrackerWorkItem]] = [:]
    /// The kinds of work each project records time as, by the tracker's
    /// project identifier.
    private(set) var workTypes: [String: [TrackerWorkType]] = [:]
    /// Writes in flight, so the control that sent one can say it is waiting
    /// and cannot send it twice.
    private(set) var writesInFlight: Set<Write> = []
    /// Pictures read off the tracker — avatars, attachments — by address.
    private(set) var images: [URL: NSImage] = [:]
    @ObservationIgnored private var imagesBeingRead: Set<URL> = []
    /// Addresses that answered with something that is not a picture, so a
    /// board of cards does not ask for the same broken avatar forty times.
    @ObservationIgnored private var unreadableImages: Set<URL> = []

    /// How many pictures are kept. A board's avatars are a handful; the rest
    /// are screenshots in the issues opened today, and a day of those is not
    /// worth holding on to.
    private static let imageLimit = 120

    enum Write: Hashable {
        case comment(String)
        case work(String)
        case edit(String)
        case create
        /// A change to one comment or one entry of time, by its identifier.
        case changeComment(String)
        case changeWork(String)
    }

    @ObservationIgnored private var tracker: (any IssueTracker)?
    /// Reads of an issue in flight, so a second caller waits on the first
    /// rather than going without.
    @ObservationIgnored private var reads: [String: Task<Bool, Never>] = [:]
    /// A count of the changes made here, and the count at which each card was
    /// last changed. A board read that set off before a card was changed is
    /// older than the change, however late it arrives, and must not undo it —
    /// a move answered before the read that began ahead of it is the usual case.
    @ObservationIgnored private var changeCount = 0
    @ObservationIgnored private var cardChanges: [String: Int] = [:]
    /// Called whenever something the workspace file keeps has changed.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called with what failed and why, for a failure nobody is looking at a
    /// place on screen to learn about.
    @ObservationIgnored var onFailure: ((String, TrackerError) -> Void)?

    var isEnabled: Bool { settings.kind != nil }

    var user: TrackerUser? {
        if case let .connected(user) = connection { return user }
        return nil
    }

    var isConnected: Bool { user != nil }

    // MARK: - Connecting

    /// What the workspace file had. Reads the token, and asks the tracker
    /// nothing: the name it was last seen with stands until a request says
    /// otherwise.
    func restore(_ restored: TrackerSettings) {
        settings = restored
        guard let kind = restored.kind else {
            connection = .off
            return
        }
        guard let token = TrackerKeychain.token(for: restored.address),
              let made = Self.makeTracker(kind, address: restored.address, token: token)
        else {
            connection = .needsToken
            return
        }
        tracker = made
        if let user = restored.user {
            connection = .connected(user)
        } else {
            verify()
        }
    }

    /// Checks a token against the tracker before keeping either: a token that
    /// does not work is not worth a place in the keychain, and an address that
    /// does not answer is not worth remembering. Nil when it worked.
    func connect(_ kind: TrackerKind, address typed: String, token typedToken: String) async -> TrackerError? {
        let token = typedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = Self.address(for: kind, typed: typed),
              let candidate = Self.makeTracker(kind, address: address, token: token)
        else { return TrackerError(.invalidAddress) }
        guard !token.isEmpty else { return TrackerError(.unauthorized) }

        let previous = connection
        connection = .checking
        do {
            let user = try await candidate.currentUser()
            TrackerKeychain.store(token, for: address)
            if settings.address != address {
                // Another instance: its boards are not these, and the old
                // token is no use to anyone left in the keychain.
                if !settings.address.isEmpty { TrackerKeychain.remove(for: settings.address) }
                settings.boards = [:]
                settings.destinations = [:]
                settings.layouts = [:]
                chosenSprints = [:]
                forget(boards: true)
            }
            tracker = candidate
            settings.kind = kind
            settings.address = address
            settings.user = user
            connection = .connected(user)
            onChange?()
            return nil
        } catch {
            // What was there before still works, or still does not.
            connection = previous
            return Self.trackerError(error)
        }
    }

    /// Switches the feature on or off. Off keeps the token and the board each
    /// project was shown, so switching it back on is one click rather than a
    /// token to make again.
    func setKind(_ kind: TrackerKind?) {
        guard settings.kind != kind else { return }
        tracker = nil
        forget(boards: true)
        var changed = settings
        changed.kind = kind
        restore(changed)
        onChange?()
    }

    /// Forgets the token. The tracker stays chosen, waiting for another.
    func signOut() {
        if !settings.address.isEmpty { TrackerKeychain.remove(for: settings.address) }
        tracker = nil
        settings.user = nil
        connection = settings.kind == nil ? .off : .needsToken
        forget(boards: true)
        onChange?()
    }

    private func verify() {
        guard let tracker else { return }
        connection = .checking
        Task { [weak self] in
            do {
                let user = try await tracker.currentUser()
                guard let self else { return }
                self.settings.user = user
                self.connection = .connected(user)
                self.onChange?()
            } catch {
                self?.connection = .failed(Self.trackerError(error))
            }
        }
    }

    private func forget(boards alsoBoards: Bool) {
        if alsoBoards { boards = [] }
        images = [:]
        unreadableImages = []
        snapshots = [:]
        boardFailures = [:]
        issues = [:]
        issueFailures = [:]
        comments = [:]
        workItems = [:]
        workTypes = [:]
    }

    static func address(for kind: TrackerKind, typed: String) -> String? {
        switch kind {
        case .youTrack: YouTrackConnection.address(from: typed)?.absoluteString
        }
    }

    private static func makeTracker(_ kind: TrackerKind, address: String, token: String) -> (any IssueTracker)? {
        switch kind {
        case .youTrack:
            guard let url = URL(string: address) else { return nil }
            return YouTrackTracker(connection: YouTrackConnection(baseURL: url, token: token))
        }
    }

    // MARK: - Boards

    func boardID(for projectID: ProjectID) -> String? {
        settings.boards[projectID.rawValue]
    }

    func board(_ id: String) -> TrackerBoard? {
        snapshots[id]?.board ?? boards.first { $0.id == id }
    }

    /// The Relay project a tracker project's issues were last handed to.
    func destination(for trackerProject: TrackerProject) -> ProjectID? {
        settings.destinations[trackerProject.id].map { ProjectID(rawValue: $0) }
    }

    func remember(_ destination: ProjectID, for trackerProject: TrackerProject) {
        guard settings.destinations[trackerProject.id] != destination.rawValue else { return }
        settings.destinations[trackerProject.id] = destination.rawValue
        onChange?()
    }

    func chooseBoard(_ id: String, for projectID: ProjectID) {
        guard settings.boards[projectID.rawValue] != id else { return }
        settings.boards[projectID.rawValue] = id
        onChange?()
        refreshBoard(id)
    }

    func layout(of boardID: String) -> BoardLayout {
        settings.layouts[boardID] ?? BoardLayout()
    }

    /// Changes how a board is laid out here. Nothing is asked of the tracker:
    /// the columns and the cards on screen already say everything a layout
    /// needs.
    func changeLayout(of boardID: String, _ change: (inout BoardLayout) -> Void) {
        var layout = layout(of: boardID)
        change(&layout)
        guard layout != self.layout(of: boardID) else { return }
        settings.layouts[boardID] = layout.isEmpty ? nil : layout
        onChange?()
    }

    func chooseSprint(_ sprintID: String?, on boardID: String) {
        guard chosenSprints[boardID] != sprintID else { return }
        chosenSprints[boardID] = sprintID
        snapshots[boardID] = nil
        boardFailures[boardID] = nil
        refreshBoard(boardID)
    }

    func refreshBoards() {
        guard let tracker, !isReadingBoards else { return }
        isReadingBoards = true
        Task { [weak self] in
            do {
                let found = try await tracker.boards()
                guard let self else { return }
                self.boards = found
                self.boardsFailure = nil
            } catch {
                self?.boardsFailure = self?.noted(error)
            }
            self?.isReadingBoards = false
        }
    }

    /// Reads the board again. Quiet: what is on screen stays until the answer
    /// replaces it, so a refresh on a timer does not blink.
    func refreshBoard(_ boardID: String) {
        guard let tracker, !boardsBeingRead.contains(boardID) else { return }
        // A board named in the workspace file is asked for by its identifier
        // alone: the answer brings the rest of it.
        let board = board(boardID) ?? TrackerBoard(id: boardID, name: "")
        boardsBeingRead.insert(boardID)
        let sprint = chosenSprints[boardID]
        let setOffAt = changeCount
        Task { [weak self] in
            let result: Result<BoardSnapshot, any Error>
            do {
                result = .success(try await tracker.snapshot(of: board, sprint: sprint))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.boardsBeingRead.remove(boardID)
            // Another sprint was chosen while this one was being read, and its
            // read was turned away because this one was in flight.
            guard self.chosenSprints[boardID] == sprint else {
                self.refreshBoard(boardID)
                return
            }
            switch result {
            case let .success(snapshot):
                self.snapshots[boardID] = self.keepingChanges(since: setOffAt, in: snapshot, over: self.snapshots[boardID])
                self.boardFailures[boardID] = nil
                if let index = self.boards.firstIndex(where: { $0.id == boardID }) {
                    self.boards[index] = snapshot.board
                }
            case let .failure(error):
                self.boardFailures[boardID] = self.noted(error)
            }
        }
    }

    /// The board as read, with every card changed here since the read set off
    /// kept as it is on screen — moved, edited or just made.
    private func keepingChanges(since setOffAt: Int, in fresh: BoardSnapshot, over shown: BoardSnapshot?) -> BoardSnapshot {
        guard let shown else { return fresh }
        var merged = fresh
        for card in shown.cards where (cardChanges[card.id] ?? 0) > setOffAt || cardsMoving.contains(card.id) {
            merged.replace(card)
        }
        return merged
    }

    /// Notes that a card was changed here, so a read already in flight does
    /// not put back what it was.
    private func changed(_ cardID: String) {
        changeCount += 1
        cardChanges[cardID] = changeCount
    }

    /// Moves a card on screen at once, and back if the tracker refuses — a
    /// workflow that will not let an issue be closed without a fix version
    /// says so, and the card goes back where it was.
    func move(_ card: TrackerCard, to column: BoardColumn, on boardID: String) {
        guard let tracker, var snapshot = snapshots[boardID],
              snapshot.column(of: card)?.id != column.id,
              !cardsMoving.contains(card.id)
        else { return }
        let before = snapshot
        snapshot.place(card, in: column)
        snapshots[boardID] = snapshot
        cardsMoving.insert(card.id)
        changed(card.id)
        Task { [weak self] in
            do {
                let moved = try await tracker.move(card, to: column, on: before)
                self?.cardsMoving.remove(card.id)
                self?.putBack(moved)
            } catch {
                guard let self else { return }
                self.cardsMoving.remove(card.id)
                if let original = before.cards.first(where: { $0.id == card.id }) {
                    self.snapshots[boardID]?.replace(original)
                    self.changed(card.id)
                }
                self.report(String(format: relayLocalized("Could not move %@"), card.key), error)
            }
        }
    }

    /// An issue as the tracker now has it, wherever it is shown.
    private func putBack(_ card: TrackerCard) {
        changed(card.id)
        for (boardID, snapshot) in snapshots where snapshot.cards.contains(where: { $0.id == card.id }) {
            snapshots[boardID]?.replace(card)
        }
    }

    // MARK: - Issues

    /// Reads an issue with its comments and its time, for the issue pane.
    func open(_ key: String) {
        Task { await read(key) }
    }

    /// The same, for a caller that needs the answer before it goes on: an
    /// issue handed to an agent from a card is read in full first, since the
    /// card has no description and the description is the brief. A read
    /// already in flight is waited on rather than started again. False when it
    /// could not be read.
    @discardableResult
    func read(_ key: String, reportingFailure: Bool = false) async -> Bool {
        if let running = reads[key] { return await running.value }
        guard tracker != nil else { return false }
        let reading = Task { await self.readOnce(key, reportingFailure: reportingFailure) }
        reads[key] = reading
        issuesBeingRead.insert(key)
        let succeeded = await reading.value
        reads[key] = nil
        issuesBeingRead.remove(key)
        return succeeded
    }

    private func readOnce(_ key: String, reportingFailure: Bool) async -> Bool {
        guard let tracker else { return false }
        async let issue = tracker.issue(key)
        async let comments = tracker.comments(on: key)
        async let work = Self.workItemsIfTracked(on: key, by: tracker)
        do {
            let (read, said, logged) = try await (issue, comments, work)
            issues[key] = read
            self.comments[key] = said
            workItems[key] = logged
            issueFailures[key] = nil
            putBack(read.card)
            loadWorkTypes(for: read.project)
            return true
        } catch {
            let failure = noted(error)
            issueFailures[key] = failure
            if reportingFailure { onFailure?(String(format: relayLocalized("Could not read %@"), key), failure) }
            return false
        }
    }

    /// A project that does not track time answers with a refusal; that is no
    /// reason not to show the issue.
    private nonisolated static func workItemsIfTracked(
        on key: String,
        by tracker: any IssueTracker
    ) async throws -> [TrackerWorkItem] {
        do {
            return try await tracker.workItems(on: key)
        } catch let error as TrackerError where error.kind == .forbidden || error.kind == .notFound
            || error.kind == .rejected {
            return []
        }
    }

    func loadWorkTypes(for project: TrackerProject) {
        guard let tracker, workTypes[project.id] == nil else { return }
        workTypes[project.id] = []
        Task { [weak self] in
            let types = (try? await tracker.workTypes(in: project)) ?? []
            self?.workTypes[project.id] = types
        }
    }

    func webURL(for key: String) -> URL? {
        tracker?.webURL(for: key)
    }

    /// An address for a link the tracker wrote.
    func resolve(_ link: String?) -> URL? {
        guard let link else { return nil }
        return tracker?.resolve(link)
    }

    /// Reads a picture once; `images` has it when it has arrived. Called from
    /// a view's task, never while it draws.
    func loadImage(at url: URL) async {
        guard let tracker, images[url] == nil, !imagesBeingRead.contains(url), !unreadableImages.contains(url)
        else { return }
        imagesBeingRead.insert(url)
        defer { imagesBeingRead.remove(url) }
        guard let data = try? await tracker.contents(of: url), let image = NSImage(data: data) else {
            unreadableImages.insert(url)
            return
        }
        if images.count >= Self.imageLimit { images.removeAll() }
        images[url] = image
    }

    /// The file's contents, for opening it where it belongs.
    func contents(of url: URL) async -> Data? {
        try? await tracker?.contents(of: url)
    }

    /// The card for a key, from whichever board has it.
    func card(_ key: String) -> TrackerCard? {
        if let issue = issues[key] { return issue.card }
        for snapshot in snapshots.values {
            if let card = snapshot.cards.first(where: { $0.key == key }) { return card }
        }
        return nil
    }

    func addComment(_ text: String, on key: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tracker, !trimmed.isEmpty else { return false }
        return await writing(.comment(key), failure: String(format: relayLocalized("Could not comment on %@"), key)) {
            let comment = try await tracker.addComment(trimmed, on: key)
            self.comments[key, default: []].append(comment)
        }
    }

    func updateComment(_ comment: TrackerComment, text: String, on key: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tracker, !trimmed.isEmpty else { return false }
        guard trimmed != comment.text else { return true }
        return await writing(.changeComment(comment.id), failure: String(format: relayLocalized("Could not change the comment on %@"), key)) {
            let updated = try await tracker.updateComment(comment.id, text: trimmed, on: key)
            if let index = self.comments[key]?.firstIndex(where: { $0.id == comment.id }) {
                self.comments[key]?[index] = updated
            }
        }
    }

    func deleteComment(_ comment: TrackerComment, on key: String) async -> Bool {
        guard let tracker else { return false }
        return await writing(.changeComment(comment.id), failure: String(format: relayLocalized("Could not delete the comment on %@"), key)) {
            try await tracker.deleteComment(comment.id, on: key)
            self.comments[key]?.removeAll { $0.id == comment.id }
        }
    }

    func updateWork(_ item: TrackerWorkItem, with entry: WorkEntry, on key: String) async -> Bool {
        guard let tracker, entry.minutes > 0 else { return false }
        return await writing(.changeWork(item.id), failure: String(format: relayLocalized("Could not change the time on %@"), key)) {
            let updated = try await tracker.updateWork(item.id, with: entry, on: key)
            if let index = self.workItems[key]?.firstIndex(where: { $0.id == item.id }) {
                self.workItems[key]?[index] = updated
            }
            // The issue's spent time is the tracker's sum of these.
            if self.issues[key] != nil { self.open(key) }
        }
    }

    func deleteWork(_ item: TrackerWorkItem, on key: String) async -> Bool {
        guard let tracker else { return false }
        return await writing(.changeWork(item.id), failure: String(format: relayLocalized("Could not delete the time on %@"), key)) {
            try await tracker.deleteWork(item.id, on: key)
            self.workItems[key]?.removeAll { $0.id == item.id }
            if self.issues[key] != nil { self.open(key) }
        }
    }

    func update(_ key: String, with change: IssueChange) async -> Bool {
        guard let tracker, !change.isEmpty else { return false }
        return await writing(.edit(key), failure: String(format: relayLocalized("Could not change %@"), key)) {
            let updated = try await tracker.update(key, with: change)
            self.issues[key] = updated
            self.putBack(updated.card)
            if self.settings.timer?.key == key {
                self.settings.timer?.summary = updated.summary
                self.onChange?()
            }
        }
    }

    /// Nil when it could not be made. Made and not put where it was asked for
    /// is made: the card is shown where it is and the reason said, since
    /// another press of Create would make it twice.
    func create(_ draft: IssueDraft, in column: BoardColumn?, on boardID: String) async -> TrackerCard? {
        guard let tracker, let snapshot = snapshots[boardID] else { return nil }
        var made: TrackerCard?
        _ = await writing(.create, failure: relayLocalized("Could not create the issue")) {
            let created = try await tracker.create(draft, in: column, on: snapshot)
            self.changed(created.card.id)
            self.snapshots[boardID]?.replace(created.card)
            made = created.card
            if let misplaced = created.misplaced {
                self.report(
                    String(format: relayLocalized("%@ was made, but not put where it was asked for"), created.card.key),
                    misplaced
                )
            }
        }
        return made
    }

    func logWork(_ entry: WorkEntry, on key: String) async -> Bool {
        guard let tracker, entry.minutes > 0 else { return false }
        return await writing(.work(key), failure: String(format: relayLocalized("Could not log time on %@"), key)) {
            let item = try await tracker.logWork(entry, on: key)
            self.workItems[key, default: []].insert(item, at: 0)
            // The spent-time field is the tracker's sum, and only it knows how
            // the sum is kept; reading the issue again is how to see it.
            if self.issues[key] != nil { self.open(key) }
        }
    }

    private func writing(_ write: Write, failure title: String, _ body: () async throws -> Void) async -> Bool {
        guard !writesInFlight.contains(write) else { return false }
        writesInFlight.insert(write)
        defer { writesInFlight.remove(write) }
        do {
            try await body()
            return true
        } catch {
            report(title, error)
            return false
        }
    }

    // MARK: - Timer

    var timer: TrackerTimer? { settings.timer }

    /// Starts timing an issue, or carries on timing it. A timer on another
    /// issue is replaced, so whoever calls this has dealt with that one's time
    /// first — see `AppModel.startTimer`.
    func startTimer(for key: String, summary: String, project: TrackerProject?, at now: Date = Date()) {
        if settings.timer?.key == key {
            settings.timer?.resume(at: now)
        } else {
            settings.timer = TrackerTimer(key: key, summary: summary, project: project, startedAt: now)
        }
        onChange?()
    }

    func pauseTimer(at now: Date = Date()) {
        settings.timer?.pause(at: now)
        onChange?()
    }

    func resumeTimer(at now: Date = Date()) {
        settings.timer?.resume(at: now)
        onChange?()
    }

    func discardTimer() {
        settings.timer = nil
        onChange?()
    }

    // MARK: - Failures

    /// A refusal of the token is a fact about the connection, not about the
    /// one request: every later one would be refused too.
    private func noted(_ error: any Error) -> TrackerError {
        let failure = Self.trackerError(error)
        if failure.kind == .unauthorized { connection = .failed(failure) }
        return failure
    }

    private func report(_ title: String, _ error: any Error) {
        onFailure?(title, noted(error))
    }

    private static func trackerError(_ error: any Error) -> TrackerError {
        if let error = error as? TrackerError { return error }
        if error is CancellationError { return TrackerError(.unreachable) }
        return TrackerError(.unreachable, message: error.localizedDescription)
    }
}
