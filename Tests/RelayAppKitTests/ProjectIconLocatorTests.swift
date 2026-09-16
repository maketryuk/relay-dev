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

    /// A repository that builds a Mac app carries no favicon anywhere, and
    /// used to be drawn with its initials while its own application icon sat
    /// in `Resources`.
    @Test("A native app's icon is found")
    func findsAnAppIcon() {
        let found = ProjectIconLocator.icon(
            forProjectAt: "/p",
            fileExists: locator(["/p/Resources/AppIcon.icns"])
        )
        #expect(found == "/p/Resources/AppIcon.icns")
    }

    @Test("An application icon beats a logo kept for the readme")
    func prefersTheAppIcon() {
        let found = ProjectIconLocator.icon(
            forProjectAt: "/p",
            fileExists: locator(["/p/logo.png", "/p/Resources/AppIcon.icns"])
        )
        #expect(found == "/p/Resources/AppIcon.icns")
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

@Suite("Project icon measurement")
struct ProjectIconCoverageTests {
    /// Row 0 is the bottom, as the bitmap context draws it.
    private func alpha(_ rows: [String]) -> (alpha: [UInt8], width: Int, height: Int) {
        let width = rows.first?.count ?? 0
        let samples = rows.reversed().flatMap { row in
            row.map { $0 == "." ? UInt8(0) : UInt8(255) }
        }
        return (samples, width, rows.count)
    }

    /// The whole point: a mark exported with empty space around it must be
    /// measured by what it draws, not by the canvas it was saved on.
    @Test("The empty margin is not part of the mark")
    func findsTheDrawnBox() {
        let bitmap = alpha([
            "......",
            "..##..",
            "..##..",
            "......",
        ])
        let coverage = try! #require(
            ProjectIconLoader.coverage(alpha: bitmap.alpha, width: bitmap.width, height: bitmap.height)
        )
        #expect(coverage.left == 2)
        #expect(coverage.right == 3)
        #expect(coverage.width == 2)
        #expect(coverage.height == 2)
    }

    @Test("An image with nothing drawn in it measures as nothing")
    func emptyImage() {
        let bitmap = alpha(["....", "....", "....", "...."])
        #expect(
            ProjectIconLoader.coverage(alpha: bitmap.alpha, width: bitmap.width, height: bitmap.height) == nil
        )
    }

    /// An application icon brings its own shape and background, and drawing a
    /// plate under it puts a rounded square inside a rounded square.
    @Test("A solid square mark stands as a tile on its own")
    func solidSquareIsATile() {
        let bitmap = alpha([
            ".####.",
            "######",
            "######",
            "######",
            "######",
            ".####.",
        ])
        let coverage = try! #require(
            ProjectIconLoader.coverage(alpha: bitmap.alpha, width: bitmap.width, height: bitmap.height)
        )
        #expect(coverage.isFullBleed)
    }

    @Test("A mark drawn in strokes does not")
    func outlineIsNotATile() {
        let bitmap = alpha([
            "######",
            "#....#",
            "#....#",
            "#....#",
            "#....#",
            "######",
        ])
        let coverage = try! #require(
            ProjectIconLoader.coverage(alpha: bitmap.alpha, width: bitmap.width, height: bitmap.height)
        )
        #expect(!coverage.isFullBleed)
    }

    @Test("A wordmark is too wide to be a tile whatever it covers")
    func wordmarkIsNotATile() {
        let bitmap = alpha([
            "########",
            "########",
        ])
        let coverage = try! #require(
            ProjectIconLoader.coverage(alpha: bitmap.alpha, width: bitmap.width, height: bitmap.height)
        )
        #expect(!coverage.isFullBleed)
    }

    /// The box is read off a buffer whose rows run bottom to top, and cropping
    /// counts from the top — the one place an off-by-one would put every icon
    /// a pixel out.
    @Test("Rows are counted from the bottom")
    func rowsCountFromTheBottom() {
        let bitmap = alpha([
            "..",
            "..",
            "#.",
        ])
        let coverage = try! #require(
            ProjectIconLoader.coverage(alpha: bitmap.alpha, width: bitmap.width, height: bitmap.height)
        )
        #expect(coverage.bottom == 0)
        #expect(coverage.top == 0)
    }
}
