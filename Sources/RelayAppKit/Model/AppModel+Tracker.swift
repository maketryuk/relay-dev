import AppKit
import Foundation
import RelayProtocol
import RelayTracker
import RelayUI

/// The New Worktree panel filled in ahead of time.
struct WorktreeDraft: Equatable {
    var name: String
    var prompt: String
}

/// A timer to start once the one before it has been dealt with.
struct PendingTimerStart: Equatable {
    var key: String
    var summary: String
    var project: TrackerProject?
}

extension AppModel {
    // MARK: - Panels

    /// The board of the project in front, or where to connect one when there
    /// is no tracker yet: the shortcut is the same either way, and a shortcut
    /// that does nothing teaches nobody where the feature is.
    func openBoard() {
        guard let projectID = selectedProjectID ?? projects.first?.id else { return }
        guard tracker.isEnabled else {
            openSettings(on: .issues)
            return
        }
        toggleModal(.board(projectID))
    }

    func openSettings(on tab: SettingsView.Tab) {
        requestedSettingsTab = tab
        if activeModal != .settings { toggleModal(.settings) }
    }

    func openIssue(_ key: String, in projectID: ProjectID) {
        tracker.open(key)
        presentModal(.issue(projectID: projectID, key: key))
    }

    func beginNewIssue(on boardID: String, in columnID: String?, projectID: ProjectID) {
        presentModal(.newIssue(projectID: projectID, boardID: boardID, columnID: columnID))
    }

    /// The key and the summary, the key a link to the issue.
    func copyIssueReference(_ key: String, summary: String) {
        IssueReference.copy(key: key, summary: summary, link: tracker.webURL(for: key))
    }

    func arrangeColumns(of boardID: String) {
        presentModal(.boardColumns(boardID: boardID))
    }

    func beginLoggingWork(on key: String) {
        presentModal(.logWork(key: key, fromTimer: false))
    }

    // MARK: - Handing an issue to an agent

    /// The issue as the agent is to read it: in full when it has been read in
    /// full, as its card when only the board has been.
    func issueTranscript(for key: String) -> String? {
        let link = tracker.webURL(for: key)
        if let issue = tracker.issues[key] {
            return IssueTranscript.compose(issue, comments: tracker.comments[key] ?? [], link: link)
        }
        return tracker.card(key).map { IssueTranscript.compose($0, link: link) }
    }

    /// The issue in full, read first when only its card is known. A card that
    /// cannot be read in full is still handed over as a card — the key and the
    /// summary are a brief of sorts — and the failure is said.
    private func briefing(for key: String) async -> String? {
        if tracker.issues[key] == nil {
            await tracker.read(key, reportingFailure: true)
        }
        return issueTranscript(for: key)
    }

    /// The projects an issue can be handed to, the likeliest first: the one
    /// its tracker project's issues went to last time, then the one whose
    /// board it is on, then the rest in the rail's order.
    func handoverProjects(for key: String, from boardProjectID: ProjectID) -> [Project] {
        Self.handoverOrder(
            of: projects,
            remembered: trackerProject(of: key).flatMap(tracker.destination(for:)),
            board: boardProjectID
        )
    }

    /// A remembered project that has since been removed is simply not first.
    nonisolated static func handoverOrder(of projects: [Project], remembered: ProjectID?, board: ProjectID) -> [Project] {
        let preferred = [remembered, board].compactMap { id in id.flatMap { id in projects.first { $0.id == id } } }
        var ordered: [Project] = []
        for candidate in preferred + projects where !ordered.contains(where: { $0.id == candidate.id }) {
            ordered.append(candidate)
        }
        return ordered
    }

    private func trackerProject(of key: String) -> TrackerProject? {
        tracker.issues[key]?.project ?? tracker.card(key)?.project
    }

    /// Everything a handover does before the issue is typed anywhere: the
    /// panels go, the project it goes to is remembered for next time, and the
    /// window turns to that project — an agent started in a project nobody is
    /// looking at is an agent nobody sees start.
    private func turn(to projectID: ProjectID, handing key: String) {
        dismissAllModals()
        if let trackerProject = trackerProject(of: key) {
            tracker.remember(projectID, for: trackerProject)
        }
        selectProject(projectID)
    }

    /// Typed into the agent's prompt and not sent, the way a review is: it is
    /// the brief, and the person may want to add a sentence of their own.
    func sendIssue(_ key: String, to sessionID: SessionID) {
        guard let projectID = sessions[sessionID]?.projectID else { return }
        turn(to: projectID, handing: key)
        Task {
            guard let text = await briefing(for: key) else { return }
            deliver(PendingInput(text: text), to: sessionID)
        }
    }

    func sendIssue(_ key: String, toNewSessionFrom preset: SessionPreset, in projectID: ProjectID) {
        turn(to: projectID, handing: key)
        Task {
            guard let text = await briefing(for: key) else { return }
            createSession(from: preset, in: projectID, thenType: PendingInput(text: text))
        }
    }

    /// A worktree of its own for the issue, named after it, with the issue as
    /// its first prompt — the New Worktree panel, filled in, so the branch and
    /// the agent can still be changed before anything is made.
    func startWork(on key: String, in projectID: ProjectID) {
        turn(to: projectID, handing: key)
        Task {
            guard let text = await briefing(for: key) else { return }
            let summary = tracker.issues[key]?.summary ?? tracker.card(key)?.summary ?? ""
            worktreeDraft = WorktreeDraft(name: IssueTranscript.branchName(for: key, summary: summary), prompt: text)
            beginNewWorktree(in: projectID)
        }
    }

    // MARK: - Attachments

    /// Opens a file from an issue in the app it belongs to — a screenshot in
    /// Preview — by way of a copy on disk, since the tracker's address for it
    /// wants the token a browser does not have.
    func openAttachment(_ attachment: TrackerAttachment) {
        guard let url = tracker.resolve(attachment.url) else { return }
        Task {
            guard let data = await tracker.contents(of: url) else {
                present(ToastContent(
                    kind: .error,
                    title: String(format: relayLocalized("Could not open %@"), attachment.name),
                    message: nil
                ))
                return
            }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Relay Attachments", isDirectory: true)
                .appendingPathComponent(attachment.id, isDirectory: true)
            let file = folder.appendingPathComponent((attachment.name as NSString).lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                NSWorkspace.shared.open(file)
            } catch {
                present(ToastContent(
                    kind: .error,
                    title: String(format: relayLocalized("Could not open %@"), attachment.name),
                    message: error.localizedDescription
                ))
            }
        }
    }

    // MARK: - Timer

    /// Starts timing an issue. Time still on the timer for another issue is
    /// put to the person first — logged or let go — rather than thrown away
    /// by a click on the wrong card.
    func startTimer(for key: String, summary: String, project: TrackerProject?) {
        if let current = tracker.timer, current.key != key, current.elapsed(at: Date()) >= 60 {
            tracker.pauseTimer()
            pendingTimerStart = PendingTimerStart(key: key, summary: summary, project: project)
            presentModal(.logWork(key: current.key, fromTimer: true))
            return
        }
        tracker.startTimer(for: key, summary: summary, project: project)
    }

    /// Stops the clock and asks where the time goes.
    func stopTimer() {
        guard let timer = tracker.timer else { return }
        tracker.pauseTimer()
        presentModal(.logWork(key: timer.key, fromTimer: true))
    }

    /// The timer asked for while the last one was being dealt with.
    func startPendingTimer() {
        guard let pending = pendingTimerStart else { return }
        pendingTimerStart = nil
        tracker.startTimer(for: pending.key, summary: pending.summary, project: pending.project)
    }

    /// Consumed by the panel it fills, so the next New Worktree starts empty.
    func takeWorktreeDraft() -> WorktreeDraft? {
        defer { worktreeDraft = nil }
        return worktreeDraft
    }

    func takeRequestedSettingsTab() -> SettingsView.Tab? {
        defer { requestedSettingsTab = nil }
        return requestedSettingsTab
    }
}
