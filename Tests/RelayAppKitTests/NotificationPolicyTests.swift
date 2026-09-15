import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

@Suite("Notification policy")
struct NotificationPolicyTests {
    private let projectID = ProjectID(rawValue: "proj")

    private func session(
        kind: SessionKind = .claude,
        status: RuntimeStatus = .waiting,
        exitCode: Int32? = nil,
        role: SessionRole = .interactive
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: SessionID(rawValue: "s1"),
            projectID: projectID,
            kind: kind,
            name: "Claude",
            workingDirectory: "/tmp",
            command: ["claude"],
            status: status,
            pid: 1,
            exitCode: exitCode,
            startedAt: Date(),
            lastActivityAt: Date(),
            columns: 80,
            rows: 24,
            role: role
        )
    }

    private func context(
        previous: RuntimeStatus = .working,
        current: RuntimeStatus = .waiting,
        kind: SessionKind = .claude,
        exitCode: Int32? = nil,
        role: SessionRole = .interactive,
        isVisible: Bool = false,
        settings: NotificationSettings = NotificationSettings()
    ) -> NotificationPolicy.Context {
        NotificationPolicy.Context(
            previous: previous,
            current: current,
            session: session(kind: kind, status: current, exitCode: exitCode, role: role),
            projectName: "Storefront",
            isVisibleToUser: isVisible,
            settings: settings
        )
    }

    // MARK: - What deserves an interruption

    @Test("An agent that starts waiting is worth interrupting for")
    func notifiesOnWaiting() {
        let event = NotificationPolicy.event(for: context())
        #expect(event?.kind == .waitingForInput)
        #expect(event?.title == "Claude needs you")
        #expect(event?.body.contains("Storefront") == true)
    }

    @Test("A failure is reported with its exit code")
    func notifiesOnFailure() {
        let event = NotificationPolicy.event(for: context(current: .error, exitCode: 127))
        #expect(event?.kind == .failed)
        #expect(event?.body.contains("127") == true)
    }

    @Test("An agent finishing real work is announced")
    func notifiesOnAgentCompletion() {
        let event = NotificationPolicy.event(for: context(previous: .working, current: .finished))
        #expect(event?.kind == .finished)
    }

    @Test("A service that stops is announced")
    func notifiesOnServiceCompletion() {
        let event = NotificationPolicy.event(
            for: context(previous: .working, current: .finished, kind: .custom, role: .service(id: "svc"))
        )
        #expect(event?.kind == .finished)
    }

    // MARK: - What must stay quiet

    @Test("A shell returning to its prompt is not an event")
    func shellCompletionIsSilent() {
        // Every `ls` would otherwise fire a notification.
        #expect(NotificationPolicy.event(for: context(previous: .working, current: .finished, kind: .shell)) == nil)
        #expect(NotificationPolicy.event(for: context(previous: .working, current: .finished, kind: .ssh)) == nil)
    }

    @Test("Completion without preceding work is not announced")
    func completionRequiresWork() {
        #expect(NotificationPolicy.event(for: context(previous: .idle, current: .finished)) == nil)
    }

    @Test("A status that has not changed is not news")
    func repeatedStatusIsSilent() {
        #expect(NotificationPolicy.event(for: context(previous: .waiting, current: .waiting)) == nil)
    }

    @Test("The session the user is looking at never notifies")
    func visibleSessionIsSilent() {
        #expect(NotificationPolicy.event(for: context(isVisible: true)) == nil)
    }

    @Test("Ordinary progress is never announced")
    func transientStatesAreSilent() {
        for status in [RuntimeStatus.working, .starting, .idle, .offline] {
            #expect(NotificationPolicy.event(for: context(previous: .idle, current: status)) == nil)
        }
    }

    // MARK: - Opting out

    @Test("The global switch silences everything")
    func globalOptOut() {
        var settings = NotificationSettings()
        settings.isEnabled = false
        #expect(NotificationPolicy.event(for: context(settings: settings)) == nil)
        #expect(NotificationPolicy.event(for: context(current: .error, settings: settings)) == nil)
    }

    @Test("A muted project silences only that project")
    func perProjectOptOut() {
        var settings = NotificationSettings()
        settings.toggleMute(projectID)
        #expect(NotificationPolicy.event(for: context(settings: settings)) == nil)

        settings.toggleMute(ProjectID(rawValue: "other"))
        #expect(NotificationPolicy.event(for: context(settings: settings)) == nil)

        settings.toggleMute(projectID)
        #expect(NotificationPolicy.event(for: context(settings: settings)) != nil)
    }

    @Test("Each event type can be switched off on its own")
    func perTypeOptOut() {
        var settings = NotificationSettings()

        settings.waitingForInput = false
        #expect(NotificationPolicy.event(for: context(current: .waiting, settings: settings)) == nil)
        #expect(NotificationPolicy.event(for: context(current: .error, settings: settings)) != nil)

        settings = NotificationSettings()
        settings.failures = false
        #expect(NotificationPolicy.event(for: context(current: .error, settings: settings)) == nil)

        settings = NotificationSettings()
        settings.completions = false
        #expect(
            NotificationPolicy.event(for: context(previous: .working, current: .finished, settings: settings)) == nil
        )
    }

    @Test("Muting toggles rather than accumulating duplicates")
    func muteToggles() {
        var settings = NotificationSettings()
        settings.toggleMute(projectID)
        settings.toggleMute(projectID)
        settings.toggleMute(projectID)
        #expect(settings.mutedProjectIDs == [projectID.rawValue])
    }

    @Test("Notification settings survive persistence and default on for old files")
    func settingsPersist() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")

        var settings = NotificationSettings()
        settings.completions = false
        settings.toggleMute(projectID)
        WorkspaceStore(url: url).saveNow(WorkspaceState(notifications: settings))

        let loaded = WorkspaceStore(url: url).load()
        #expect(!loaded.notifications.completions)
        #expect(loaded.notifications.isMuted(projectID))

        try #"{"projects":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(WorkspaceStore(url: url).load().notifications.isEnabled)
    }
}
