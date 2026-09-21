import Foundation
import RelayProtocol
import RelayUI
import Testing

@testable import RelayAppKit

@Suite("The chat")
@MainActor
struct ChatProjectTests {
    /// Its own workspace file: a test must not write to the one the app the
    /// developer is running keeps its projects in.
    private func model(_ directory: TemporaryDirectory) -> AppModel {
        AppModel(store: WorkspaceStore(url: directory.url.appendingPathComponent("workspace.json")))
    }

    private func project(_ directory: TemporaryDirectory, named name: String) throws -> URL {
        let url = directory.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("It is first in the rail, and stays first")
    func leadsTheRail() throws {
        let directory = try TemporaryDirectory()
        let model = model(directory)
        model.addProject(at: try project(directory, named: "one"))
        model.addProject(at: try project(directory, named: "two"))

        #expect(model.railProjects.first?.id == .chat)
        #expect(model.railProjects.count == model.projects.count + 1)
    }

    @Test("Dragging a project cannot move it")
    func cannotBeReordered() throws {
        let directory = try TemporaryDirectory()
        let model = model(directory)
        model.addProject(at: try project(directory, named: "one"))
        let first = try #require(model.projects.first)

        model.moveProject(first.id, beside: .chat, side: .before)

        #expect(model.railProjects.first?.id == .chat)
        #expect(model.projects.map(\.id) == [first.id])
    }

    @Test("It is not in the workspace, so it cannot be removed from it")
    func cannotBeRemoved() throws {
        let directory = try TemporaryDirectory()
        let model = model(directory)

        model.selectProject(.chat)
        model.removeProject(.chat)

        #expect(model.project(.chat) != nil)
        #expect(model.selectedProjectID == .chat)
    }

    @Test("Nothing about it is written to the workspace file")
    func staysOutOfTheFile() throws {
        // The identifier is fixed precisely so that the sessions and layouts
        // keyed by it survive a relaunch; the project itself is code.
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        let model = AppModel(store: WorkspaceStore(url: url))

        model.selectProject(.chat)
        model.persistImmediately()

        #expect(WorkspaceStore(url: url).load().projects.isEmpty)
        #expect(WorkspaceStore(url: url).load().lastActiveProjectID == ProjectID.chat.rawValue)
    }

    @Test("Cycling through the rail passes through it")
    func cyclesWithTheProjects() throws {
        let directory = try TemporaryDirectory()
        let model = model(directory)
        model.addProject(at: try project(directory, named: "one"))
        let only = try #require(model.projects.first)

        model.selectProject(.chat)
        model.selectNextProject(offset: 1)
        #expect(model.selectedProjectID == only.id)

        model.selectNextProject(offset: 1)
        #expect(model.selectedProjectID == .chat)
    }

    @Test("The panel offers conversations and nothing else")
    func onlyHistory() throws {
        // A repository it has none of, services it cannot run and containers it
        // never starts would be four tabs that are permanently empty.
        let directory = try TemporaryDirectory()
        let model = model(directory)
        model.addProject(at: try project(directory, named: "one"))
        let ordinary = try #require(model.projects.first)

        #expect(model.tabs(for: .chat) == [.history])
        #expect(model.tabs(for: ordinary) == RightSidebarTab.allCases)
    }

    @Test("Selecting it leaves the panel on a tab it shows")
    func movesThePanelToHistory() throws {
        let directory = try TemporaryDirectory()
        let model = model(directory)
        model.addProject(at: try project(directory, named: "one"))
        let ordinary = try #require(model.projects.first)

        model.selectProject(ordinary.id)
        model.selectRightSidebarTab(.services)
        model.selectProject(.chat)

        #expect(model.rightSidebarTab == .history)
        // And the tabs it does not show cannot be reached by the shortcut
        // either.
        model.selectRightSidebarTab(.git)
        #expect(model.rightSidebarTab == .history)
    }

    @Test("It has no settings panel, however the shortcut is pressed")
    func hasNoSettings() throws {
        let directory = try TemporaryDirectory()
        let model = model(directory)

        model.selectProject(.chat)
        model.openProjectSettings()

        #expect(model.activeModal == nil)
    }

    @Test("It runs in Relay's own directory, not in a project")
    func livesBesideTheWorkspace() {
        #expect(Project.chat.rootPath == RelayPaths.chatDirectory.path)
        #expect(Project.chat.isChat)
        #expect(Project.chat.name == relayLocalized("Chat"))
    }
}
