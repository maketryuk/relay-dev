import Foundation
import Testing

@testable import RelayAppKit

@Suite("Project icon discovery")
struct ProjectIconLocatorTests {
    private func locator(_ present: [String]) -> (String) -> Bool {
        let existing = Set(present)
        return { existing.contains($0) }
    }

    @Test("A favicon in the web root is found")
    func findsAFavicon() {
        let found = ProjectIconLocator.icon(
            forProjectAt: "/p",
            fileExists: locator(["/p/public/favicon.ico"])
        )
        #expect(found == "/p/public/favicon.ico")
    }

    @Test("A file meant to be the icon beats one that merely looks like it")
    func prefersTheDeliberateFile() {
        // `app/icon.png` exists to be the site's icon; a `logo.png` sitting at
        // the root might be a readme banner or anything else.
        let found = ProjectIconLocator.icon(
            forProjectAt: "/p",
            fileExists: locator(["/p/logo.png", "/p/app/icon.png"])
        )
        #expect(found == "/p/app/icon.png")
    }

    @Test("A project with no artwork reports none")
    func reportsNothingWhenThereIsNothing() {
        #expect(ProjectIconLocator.icon(forProjectAt: "/p", fileExists: locator([])) == nil)
    }

    @Test("The search does not wander into the tree")
    func staysShallow() {
        // A dependency's artwork is not this project's mark, and using it would
        // be worse than showing initials.
        let deep = locator([
            "/p/node_modules/thing/public/favicon.ico",
            "/p/vendor/pkg/logo.png",
        ])
        #expect(ProjectIconLocator.icon(forProjectAt: "/p", fileExists: deep) == nil)
    }

    @Test("Only formats the system can draw are offered")
    func rejectsUnreadableFormats() {
        #expect(ProjectIconLocator.isReadable("/p/public/favicon.ICO"))
        #expect(ProjectIconLocator.isReadable("/p/logo.svg"))
        #expect(!ProjectIconLocator.isReadable("/p/logo.psd"))
        #expect(!ProjectIconLocator.isReadable("/p/logo"))
    }

    @Test("Every candidate is a format the system can draw")
    func candidatesAreAllReadable() {
        // A candidate the renderer cannot open would silently mean "this
        // project has no icon" while a perfectly good file sat next to it.
        #expect(ProjectIconLocator.candidates.allSatisfy(ProjectIconLocator.isReadable))
    }
}

@Suite("Project icon resolution")
struct ProjectIconLoaderTests {
    private func project(icon: String? = nil) -> Project {
        var project = Project(name: "Shop", rootPath: "/p")
        project.iconPath = icon
        return project
    }

    private func locator(_ present: [String]) -> (String) -> Bool {
        let existing = Set(present)
        return { existing.contains($0) }
    }

    @Test("A chosen icon wins over the one the project carries")
    func chosenIconWins() {
        let path = ProjectIconLoader.path(
            for: project(icon: "/elsewhere/mark.png"),
            fileExists: locator(["/elsewhere/mark.png", "/p/public/favicon.ico"])
        )
        #expect(path == "/elsewhere/mark.png")
    }

    @Test("With nothing chosen, the project's own artwork is used")
    func fallsBackToDiscovery() {
        let path = ProjectIconLoader.path(
            for: project(),
            fileExists: locator(["/p/public/favicon.ico"])
        )
        #expect(path == "/p/public/favicon.ico")
    }

    @Test("A chosen icon that has been deleted falls back rather than blanking")
    func missingChosenIconFallsBack() {
        // The path points outside the project, so it can disappear without the
        // project changing at all.
        let path = ProjectIconLoader.path(
            for: project(icon: "/elsewhere/gone.png"),
            fileExists: locator(["/p/public/favicon.ico"])
        )
        #expect(path == "/p/public/favicon.ico")
    }

    @Test("A chosen file the system cannot draw is ignored")
    func unreadableChosenIconIsIgnored() {
        let path = ProjectIconLoader.path(
            for: project(icon: "/elsewhere/mark.psd"),
            fileExists: locator(["/elsewhere/mark.psd"])
        )
        #expect(path == nil)
    }

    @Test("A project with nothing to draw reports nothing")
    func nothingToDraw() {
        #expect(ProjectIconLoader.path(for: project(), fileExists: locator([])) == nil)
    }
}
