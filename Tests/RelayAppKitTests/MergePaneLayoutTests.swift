import AppKit
import RelayUI
import SwiftUI
import Testing

@testable import RelayAppKit

/// Whether the three panes of a merge actually get any of the panel.
///
/// Hosted for real rather than reasoned about: the panes came up black twice,
/// and reading the view code told me nothing either time. An `NSHostingView`
/// lays SwiftUI out exactly as the app does, including the AppKit views inside
/// it, and then the sizes can simply be asked for.
@Suite("Merge pane layout")
@MainActor
struct MergePaneLayoutTests {
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for subview in view.subviews { found.append(contentsOf: scrollViews(in: subview)) }
        return found
    }

    /// Hosts a view the way the app does, and lets it settle.
    ///
    /// `async`, and the settling is `await`: a test that spins the run loop
    /// keeps hold of the main actor, so nothing the view starts — its `task`,
    /// anything the model reads — can run at all. That is what made the panes
    /// look empty in here while the app filled them.
    private func host<Content: View>(_ content: Content, size: CGSize) async -> NSView {
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        for _ in 0 ..< 20 {
            // Releases the actor, which is the point, and gives AppKit a turn.
            try? await Task.sleep(for: .milliseconds(25))
            hosting.layoutSubtreeIfNeeded()
        }
        return hosting
    }

    @Test("Three panes share the width of the panel and take its height")
    func panesFillThePanel() async {
        let panes = HStack(spacing: 0) {
            ForEach(0 ..< 3, id: \.self) { _ in
                CodeTextView(text: .constant("one\ntwo\nthree"), isEditable: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        let hosted = await host(panes, size: CGSize(width: 900, height: 600))
        let found = scrollViews(in: hosted)

        #expect(found.count == 3)
        for scroll in found {
            #expect(scroll.frame.width > 250, "a pane is \(scroll.frame.width) wide")
            #expect(scroll.frame.height > 500, "a pane is \(scroll.frame.height) tall")
        }
        // The text given at the outset, which is the other half of the
        // question: are these the views the representable made?
        let texts = found.compactMap { $0.documentView as? NSTextView }
        #expect(texts.allSatisfy { $0.string.contains("two") }, "strings: \(texts.map(\.string))")
    }

    @Test("Text that arrives after the view reaches it")
    func lateTextArrives() async throws {
        // Driven by replacing the hosted view rather than by `task`, which is
        // SwiftUI's own appearance machinery and does not run in a window
        // nobody is looking at. What is under test is the update: a value that
        // was not there when the view was made has to reach it.
        let hosting = NSHostingView(rootView: AnyView(pane(text: "first")))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))

        let text = try #require(scrollViews(in: hosting).first?.documentView as? NSTextView)
        #expect(text.string == "first")

        hosting.rootView = AnyView(pane(text: "second"))
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(text.string == "second", Comment(rawValue: "the view still says \(text.string)"))
    }

    private func pane(text: String) -> some View {
        CodeTextView(text: .constant(text), isEditable: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The panel itself, with a model and a file on disk, which is the thing
    /// that came up blank twice. Everything the previous two tests assert is
    /// also true of a structure that never appears in the app.
    @Test("The real panel shows the file and both revisions")
    func theRealPanel() async throws {
        let directory = try TemporaryDirectory()
        let repository = directory.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try """
        one
        <<<<<<< HEAD
        theirs line
        =======
        my line
        >>>>>>> abc1234 (mine)
        three
        """.write(to: repository.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        // Its own workspace file: a test must not write to the one the app the
        // developer is running keeps its projects in.
        let model = AppModel(store: WorkspaceStore(url: directory.url.appendingPathComponent("workspace.json")))
        model.addProject(at: repository)
        let project = try #require(model.projects.first)

        // Facts the panel depends on, asserted before it is blamed.
        let root = try #require(model.project(project.id)?.rootPath, "the model lost the project")
        let onDisk = try String(
            contentsOf: URL(fileURLWithPath: root).appendingPathComponent("notes.txt"),
            encoding: .utf8
        )
        #expect(onDisk.contains("<<<<<<<"))

        // Loaded the way the app loads it — by the model, when the panel is
        // asked for — so the panel has its subject before it draws.
        model.loadConflict("notes.txt", in: project.id)
        for _ in 0 ..< 40 where model.conflictText("notes.txt", in: project.id) == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.conflictText("notes.txt", in: project.id)?.contains("<<<<<<<") == true)

        let hosted = await host(
            GitMergePane(project: project, path: "notes.txt").environment(model),
            size: CGSize(width: 1_000, height: 700)
        )
        let found = scrollViews(in: hosted)
        let texts = found.compactMap { $0.documentView as? NSTextView }

        #expect(found.count == 3, "expected three panes, found \(found.count)")
        for scroll in found {
            #expect(scroll.frame.width > 200, "a pane is \(scroll.frame.width) wide")
            #expect(scroll.frame.height > 300, "a pane is \(scroll.frame.height) tall")
        }

        // Left is one side in full, right is the other, and the middle is what
        // git actually left in the file.
        #expect(texts.first?.string.contains("theirs line") == true)
        #expect(texts.first?.string.contains("<<<<<<<") == false)
        #expect(texts.last?.string.contains("my line") == true)
        #expect(texts.count == 3)
        if texts.count == 3 {
            #expect(texts[1].string.contains("<<<<<<<"))
            #expect(texts[1].string.contains("my line"))
        }
    }

    @Test("The same three inside a modal surface, which is where they go")
    func panesInsideTheSurface() async {
        let surface = ModalSurface("notes.txt", onDismiss: {}) {
            VStack(spacing: 0) {
                Text(verbatim: "toolbar")
                RelayDivider()
                HStack(spacing: 0) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        CodeTextView(text: .constant("one\ntwo\nthree"), isEditable: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } footer: {
            Text(verbatim: "footer")
        }

        let hosted = await host(surface, size: CGSize(width: 900, height: 600))
        let found = scrollViews(in: hosted)

        #expect(found.count == 3)
        for scroll in found {
            #expect(scroll.frame.width > 250, "a pane is \(scroll.frame.width) wide")
            #expect(scroll.frame.height > 300, "a pane is \(scroll.frame.height) tall")
        }
    }
}
