import AppKit
import SwiftUI
import Testing

@testable import RelayAppKit

@Suite("Diff drawing", .serialized)
@MainActor
struct GitDiffDrawingTests {
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
    }

    @Test("A diff thousands of lines long opens without stopping the window")
    func longDiff() async throws {
        let directory = try TemporaryDirectory()
        let path = directory.url.path
        try Git.run(["init", "-b", "trunk"], in: path)
        try Git.run(["config", "user.email", "tests@relay.local"], in: path)
        try Git.run(["config", "user.name", "Relay Tests"], in: path)
        try directory.write("start\n", to: "README.md")
        try Git.run(["add", "."], in: path)
        try Git.run(["commit", "-q", "-m", "initial"], in: path)
        let lines = (1 ... 7600).map { "const value\($0) = compute(\($0), options.flag) // line \($0)" }
        try directory.write(lines.joined(separator: "\n") + "\n", to: "Generated.ts")

        // Its own workspace file, away from the project, whose tree would
        // otherwise list it.
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)

        model.refreshChanges(for: project.id)
        for _ in 0 ..< 200 where model.changes(in: project.id).changes.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        let change = try #require(model.changes(in: project.id).changes.first { $0.path == "Generated.ts" })
        model.toggleExpansion(of: change, in: project.id)
        for _ in 0 ..< 200 where model.fileDiffs[change.path] == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.fileDiffs[change.path]?.insertions == 7600)

        let hosting = NSHostingView(rootView: GitPane(project: project).environment(model))
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 900)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)

        // Only the drawing is timed, not the reading. Drawn all at once, the
        // diff took three seconds here, and a second and a half more for each
        // change to the model while it was open; drawn as it scrolls into
        // view, a few hundredths. The bound is far from both, so that a busy
        // machine does not fail it and drawing everything cannot pass it.
        let elapsed = ContinuousClock().measure {
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }
        #expect(elapsed < .seconds(1), Comment(rawValue: "took \(elapsed)"))

        // And it was drawn: every line has its height in what scrolls, so a
        // panel that drew none of it cannot pass for a fast one.
        let tallest = scrollViews(in: hosting).map { $0.documentView?.frame.height ?? 0 }.max() ?? 0
        #expect(tallest > 7600 * 10, Comment(rawValue: "scrolls \(tallest) points"))
    }
}
