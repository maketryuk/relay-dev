import AppKit
import RelayUI
import SwiftUI
import Testing

@testable import RelayAppKit

/// Whether the merge panel is on screen, and not merely in the view tree.
///
/// Hosted for real rather than reasoned about. The panel came up blank three
/// times over, and each time the code read correctly: the views existed, at
/// the right sizes, with the right text in them — and nothing was painted.
/// Only pixels answer that question, so these tests ask about pixels.
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
    /// anything the model reads — can run at all. That alone made the panes
    /// look empty in here for a completely different reason than in the app.
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
            try? await Task.sleep(for: .milliseconds(25))
            hosting.layoutSubtreeIfNeeded()
        }
        return hosting
    }

    /// How much light there is inside one rectangle of what was drawn.
    ///
    /// Text on this palette is the only light thing in it, so "was anything
    /// painted here" is a question about brightness. Read in device RGB
    /// deliberately: components taken in the bitmap's own space came back as
    /// zeroes and made a broken panel look fine.
    private func lightPixels(in view: NSView, rect: NSRect) -> Int {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: image)

        let scale = CGFloat(image.pixelsWide) / view.bounds.width
        // The bitmap counts rows from the top and the view from the bottom.
        let top = (view.bounds.height - rect.maxY) * scale
        let bottom = (view.bounds.height - rect.minY) * scale

        var count = 0
        for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 3) {
            for y in stride(from: Int(top), to: Int(bottom), by: 3) {
                guard x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh else { continue }
                guard let colour = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let brightness = (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3
                if brightness > 0.4 { count += 1 }
            }
        }
        return count
    }

    /// A real repository stopped on a real conflict.
    ///
    /// Not a file with markers typed into it: what the panel shows for an
    /// unanswered passage is the ancestor of the two sides, and the ancestor
    /// comes from the index — which only a repository that actually tried the
    /// merge has. So the merge is actually tried.
    private func conflictedProject() throws -> (model: AppModel, project: Project, directory: TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let repository = directory.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        func git(_ arguments: [String]) throws {
            // An identity and no signing, given here rather than taken from
            // the machine: a clean runner has neither, and one that signs
            // commits would stop to ask for a key.
            let result = try #require(Shell.capture(
                "/usr/bin/git",
                arguments: [
                    "-C", repository.path,
                    "-c", "user.email=relay@example.invalid",
                    "-c", "user.name=Relay Tests",
                    "-c", "commit.gpgsign=false",
                ] + arguments,
                timeout: 20
            ))
            // A merge that conflicts exits non-zero and has still done its
            // job, so only the setting-up commands are checked.
            if arguments.first != "merge" {
                #expect(result.succeeded, Comment(rawValue: "git \(arguments.joined(separator: " ")): \(result.error)"))
            }
        }

        func write(_ contents: String) throws {
            try contents.write(
                to: repository.appendingPathComponent("notes.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        try git(["init", "-q"])
        try write("one\ntwo\nthree\n")
        try git(["add", "notes.txt"])
        try git(["commit", "-q", "-m", "base"])

        try git(["checkout", "-q", "-b", "side"])
        try write("one\nmy line\nthree\n")
        try git(["commit", "-q", "-am", "mine"])

        try git(["checkout", "-q", "-"])
        try write("one\ntheirs line\nthree\n")
        try git(["commit", "-q", "-am", "theirs"])
        try git(["merge", "side"])

        // Its own workspace file: a test must not write to the one the app the
        // developer is running keeps its projects in.
        let model = AppModel(store: WorkspaceStore(url: directory.url.appendingPathComponent("workspace.json")))
        model.addProject(at: repository)
        let project = try #require(model.projects.first)
        return (model, project, directory)
    }

    private func loaded(_ model: AppModel, _ project: Project) async throws {
        model.loadConflict("notes.txt", in: project.id)
        for _ in 0 ..< 60 where model.conflict("notes.txt", in: project.id) == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        let file = try #require(model.conflict("notes.txt", in: project.id))
        #expect(file.hunks.count == 1)
        // Read from the index, so the ancestor came with it — which is what
        // the result pane stands on before a side is taken.
        #expect(file.hunks.first?.base == ["two"], Comment(rawValue: "\(file.hunks)"))
    }

    @Test("An editor given the room takes it, and shows what is in it")
    func editorFillsItsSlot() async {
        let pane = CodeTextView(text: .constant("one\ntwo\nthree"), isEditable: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        let hosted = await host(pane, size: CGSize(width: 900, height: 600))
        let found = scrollViews(in: hosted)

        #expect(found.count == 1)
        #expect(found.first?.frame.width ?? 0 > 800)
        #expect(found.first?.frame.height ?? 0 > 500)
        #expect((found.first?.documentView as? NSTextView)?.string.contains("two") == true)
    }

    @Test("Text that arrives after the view reaches it")
    func lateTextArrives() async throws {
        // Driven by replacing the hosted view rather than by `task`, which is
        // SwiftUI's own appearance machinery: what is under test is the
        // update, that a value which was not there when the view was made
        // reaches it.
        let hosting = NSHostingView(rootView: AnyView(editor(text: "first")))
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

        hosting.rootView = AnyView(editor(text: "second"))
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(text.string == "second", Comment(rawValue: "the view still says \(text.string)"))
    }

    private func editor(text: String) -> some View {
        CodeTextView(text: .constant(text), isEditable: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @Test("The panel carries the file and one editor for it")
    func theRealPanel() async throws {
        let (model, project, directory) = try conflictedProject()
        try await loaded(model, project)

        let hosted = await host(
            GitMergePane(project: project, path: "notes.txt").environment(model),
            size: CGSize(width: 1_000, height: 700)
        )
        let found = scrollViews(in: hosted)
        let texts = found.compactMap { $0.documentView as? NSTextView }

        // One *text* view: the editable middle. The other scroll views in
        // here are SwiftUI's own, one per revision — SwiftUI scrolls with an
        // `NSScrollView` too — and those two panes are SwiftUI text
        // deliberately, since three AppKit views in one layout is what covered
        // the panel over.
        #expect(texts.count == 1, Comment(rawValue: "expected one editor, found \(texts.count)"))
        #expect(found.count == 3, Comment(rawValue: "expected three scrolling panes, found \(found.count)"))

        let result = try #require(texts.first?.string)
        // The result is the file, not git's hand-over notation.
        #expect(!result.contains("<<<<<<<"), Comment(rawValue: result))
        #expect(!result.contains("======="), Comment(rawValue: result))
        // An unanswered passage stands as what both sides started from.
        #expect(result.contains("two"), Comment(rawValue: result))
        #expect(!result.contains("my line"), Comment(rawValue: result))
        _ = directory
    }

    @Test("Presented the way the app presents it, every pane of it is drawn")
    func throughTheModalHost() async throws {
        let (model, project, directory) = try conflictedProject()
        try await loaded(model, project)

        let hosted = await host(
            ModalHost(modal: .merge(projectID: project.id, path: "notes.txt")).environment(model),
            size: CGSize(width: 1_200, height: 800)
        )

        // Each pane where it actually ended up, rather than a third of the
        // window: the result holds three short lines now, and a slice of the
        // window wide enough to be a third of it missed them entirely while
        // the panel was perfectly fine.
        let panes = scrollViews(in: hosted)
            .map { $0.convert($0.bounds, to: hosted) }
            .sorted { $0.minX < $1.minX }
        #expect(panes.count == 3, Comment(rawValue: "expected three panes, found \(panes.count)"))

        // The three faults behind three blank panels would all have shown up
        // here: a pane covered by another view, a panel that never settled,
        // and text laid out into nothing.
        for (index, pane) in panes.enumerated() {
            let light = lightPixels(in: hosted, rect: pane)
            #expect(light > 10, Comment(rawValue: "pane \(index) at \(pane) is blank (\(light) light pixels)"))
        }
        _ = directory
    }
}
