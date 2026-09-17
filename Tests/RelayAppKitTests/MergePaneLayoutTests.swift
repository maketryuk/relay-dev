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

    /// How much light there is in a vertical slice of what was drawn.
    ///
    /// Text on this palette is the only light thing in it, so "was anything
    /// painted here" is a question about brightness. Read in device RGB
    /// deliberately: components taken in the bitmap's own space came back as
    /// zeroes and made a broken panel look fine.
    private func lightPixels(in view: NSView, slice: Range<Double>) -> Int {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: image)

        let from = Int(Double(image.pixelsWide) * slice.lowerBound)
        let upTo = Int(Double(image.pixelsWide) * slice.upperBound)
        var count = 0
        for x in stride(from: from, to: upTo, by: 3) {
            for y in stride(from: 0, to: image.pixelsHigh, by: 3) {
                guard let colour = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let brightness = (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3
                if brightness > 0.4 { count += 1 }
            }
        }
        return count
    }

    private func conflictedProject() throws -> (model: AppModel, project: Project, directory: TemporaryDirectory) {
        let fixture = [
            "one",
            "<<<<<<< HEAD",
            "theirs line",
            "=======",
            "my line",
            ">>>>>>> abc1234 (mine)",
            "three",
        ].joined(separator: "\n")

        let directory = try TemporaryDirectory()
        let repository = directory.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try fixture.write(
            to: repository.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Its own workspace file: a test must not write to the one the app the
        // developer is running keeps its projects in.
        let model = AppModel(store: WorkspaceStore(url: directory.url.appendingPathComponent("workspace.json")))
        model.addProject(at: repository)
        let project = try #require(model.projects.first)
        return (model, project, directory)
    }

    private func loaded(_ model: AppModel, _ project: Project) async throws {
        model.loadConflict("notes.txt", in: project.id)
        for _ in 0 ..< 40 where model.conflictText("notes.txt", in: project.id) == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.conflictText("notes.txt", in: project.id)?.contains("<<<<<<<") == true)
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
        #expect(texts.first?.string.contains("<<<<<<<") == true)
        #expect(texts.first?.string.contains("my line") == true)
        _ = directory
    }

    @Test("Presented the way the app presents it, every third of it is drawn")
    func throughTheModalHost() async throws {
        let (model, project, directory) = try conflictedProject()
        try await loaded(model, project)

        let hosted = await host(
            ModalHost(modal: .merge(projectID: project.id, path: "notes.txt")).environment(model),
            size: CGSize(width: 1_200, height: 800)
        )

        // The three faults behind three blank panels would all have shown up
        // here: a pane covered by another view, a panel that never settled,
        // and text laid out into nothing.
        let left = lightPixels(in: hosted, slice: 0.10 ..< 0.30)
        let middle = lightPixels(in: hosted, slice: 0.40 ..< 0.60)
        let right = lightPixels(in: hosted, slice: 0.70 ..< 0.90)

        #expect(left > 10, Comment(rawValue: "the left revision is blank (\(left) light pixels)"))
        #expect(middle > 10, Comment(rawValue: "the result is blank (\(middle) light pixels)"))
        #expect(right > 10, Comment(rawValue: "the right revision is blank (\(right) light pixels)"))
        _ = directory
    }
}
