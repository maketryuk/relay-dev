import Foundation
import Testing

@testable import RelayProtocol

@Suite("Compose file discovery")
struct ComposeLocatorTests {
    private func locator(_ present: [String]) -> (String) -> Bool {
        let existing = Set(present)
        return { existing.contains($0) }
    }

    @Test("A compose file at the root wins")
    func rootFileIsFound() {
        let found = ComposeLocator.file(
            forProjectAt: "/p",
            fileExists: locator(["/p/compose.yaml", "/p/docker/docker-compose.yml"])
        )
        #expect(found == "/p/compose.yaml")
    }

    @Test("A stack kept in a subdirectory is found")
    func subdirectoryFileIsFound() {
        // The case that produced "no configuration file provided": Compose was
        // being run from the project root while the file lived in docker/.
        let found = ComposeLocator.file(
            forProjectAt: "/p",
            fileExists: locator(["/p/docker/docker-compose.yml"])
        )
        #expect(found == "/p/docker/docker-compose.yml")
        #expect(ComposeLocator.directory(forProjectAt: "/p", fileExists: locator(["/p/docker/docker-compose.yml"])) == "/p/docker")
    }

    @Test("Compose's own precedence decides between two files in one directory")
    func precedenceMatchesCompose() {
        let found = ComposeLocator.file(
            forProjectAt: "/p",
            fileExists: locator(["/p/compose.yml", "/p/docker-compose.yml", "/p/compose.yaml"])
        )
        #expect(found == "/p/compose.yaml")
    }

    @Test("A file named after its environment is found")
    func environmentSuffixedFileIsFound() {
        // The case that produced "no configuration file provided" in a project
        // whose containers were visibly running: nothing is named any of the
        // four Compose looks for, so Compose found nothing and Relay agreed.
        let present = locator([
            "/p/docker/docker-compose.local.yml",
            "/p/docker/docker-compose.stage.yml",
            "/p/docker/docker-compose.prod.yml",
        ])
        #expect(ComposeLocator.file(forProjectAt: "/p", fileExists: present) == "/p/docker/docker-compose.local.yml")
    }

    @Test("A file Compose would find itself beats one named after an environment")
    func plainNamesWinOverSuffixedOnes() {
        let present = locator(["/p/docker-compose.local.yml", "/p/compose.yaml"])
        #expect(ComposeLocator.file(forProjectAt: "/p", fileExists: present) == "/p/compose.yaml")
    }

    @Test("A stack that only has stage and production files is left alone")
    func productionIsNeverGuessedAt() {
        // The file this picks is the one an Up button starts. Guessing that a
        // laptop wants the production stack is not a mistake to make once.
        let present = locator([
            "/p/docker/docker-compose.prod.yml",
            "/p/docker/docker-compose.stage.yml",
        ])
        #expect(ComposeLocator.file(forProjectAt: "/p", fileExists: present) == nil)
    }

    @Test("A project with no compose file reports none, and runs from its root")
    func missingFileFallsBackToTheRoot() {
        let none = locator([])
        #expect(ComposeLocator.file(forProjectAt: "/p", fileExists: none) == nil)
        #expect(ComposeLocator.directory(forProjectAt: "/p", fileExists: none) == "/p")
    }

    @Test("The search does not wander into the tree")
    func searchStaysShallow() {
        // A compose file belonging to a dependency is not this project's stack,
        // and starting it would be worse than finding nothing.
        let deep = locator(["/p/node_modules/thing/docker-compose.yml", "/p/src/a/b/compose.yaml"])
        #expect(ComposeLocator.file(forProjectAt: "/p", fileExists: deep) == nil)
    }
}
