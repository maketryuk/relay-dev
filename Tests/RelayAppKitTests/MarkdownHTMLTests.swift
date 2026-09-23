import Foundation
import Testing

@testable import RelayAppKit

@Suite("Markdown as its preview draws it")
@MainActor
struct MarkdownHTMLTests {
    @Test("GitHub's extensions are read: tables, task lists, strikethrough, bare links")
    func githubFlavour() {
        let html = MarkdownHTML.body("""
        | Key | Does |
        | --- | ---- |
        | ⌘P  | Palette |

        - [x] shipped
        - [ ] next

        ~~gone~~ and https://example.com
        """)

        #expect(html.contains("<th>Key</th>"))
        #expect(html.contains("<td>Palette</td>"))
        #expect(html.contains(#"<input type="checkbox" checked="" disabled="" />"#))
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains(#"<a href="https://example.com">"#))
    }

    @Test("Headings carry the anchors GitHub gives them")
    func headingAnchors() {
        // So a table of contents written against GitHub goes where it says.
        let html = MarkdownHTML.body("""
        # Getting Started
        ## The `open` call
        ## Usage
        ## Usage
        """)

        #expect(html.contains(#"<h1><a id="getting-started" class="anchor"></a>Getting Started</h1>"#))
        #expect(html.contains(#"id="the-open-call""#))
        #expect(html.contains(#"id="usage""#))
        #expect(html.contains(#"id="usage-1""#))
    }

    @Test("An anchor is made the way github-slugger makes it", arguments: [
        ("What's new in 0.5?", "whats-new-in-05"),
        ("Привет, мир", "привет-мир"),
        ("snake_case and kebab-case", "snake_case-and-kebab-case"),
        ("  Two  spaces ", "--two--spaces-"),
    ])
    func slugs(heading: String, slug: String) {
        var slugs = HeadingSlugs()
        #expect(slugs.slug(for: heading) == slug)
    }

    @Test("A heading repeated after its numbered twin still gets a name of its own")
    func slugCollisions() {
        var slugs = HeadingSlugs()
        #expect(slugs.slug(for: "a") == "a")
        #expect(slugs.slug(for: "a-1") == "a-1")
        #expect(slugs.slug(for: "a") == "a-2")
    }

    @Test("Fenced code is coloured by the editor's grammar")
    func highlightedCode() {
        let html = MarkdownHTML.body("""
        ```swift
        let answer = 42 // why
        ```
        """)

        #expect(html.contains(#"<pre><code class="language-swift">"#))
        #expect(html.contains("<span style=\"color:#"))
        #expect(html.contains("font-style:italic"))
        #expect(html.contains("answer"))
    }

    @Test("Code in a language nobody knows is escaped and left plain")
    func plainCode() {
        let html = MarkdownHTML.body("""
        ```nonsense
        <b>&</b>
        ```
        """)

        #expect(html.contains("&lt;b&gt;&amp;&lt;/b&gt;"))
        #expect(!html.contains("<span"))
    }

    @Test("A fence names its language the way people write it", arguments: [
        ("swift", "swift"),
        ("ts", "typescript"),
        ("py", "python"),
        ("sh", "bash"),
    ])
    func fenceLanguages(fence: String, grammar: String) {
        #expect(MarkdownHTML.language(named: fence)?.code.tsName == grammar)
    }

    @Test("A fence that names nothing known is no language")
    func unknownFence() {
        #expect(MarkdownHTML.language(named: "") == nil)
        #expect(MarkdownHTML.language(named: "nonsense") == nil)
    }

    @Test("A README's raw HTML is kept, and its scripts are not")
    func rawHTML() {
        let html = MarkdownHTML.body("""
        <p align="center"><img src="Resources/logo.svg" width="96"></p>

        <script>alert(1)</script>
        """)

        #expect(html.contains(#"<p align="center"><img src="Resources/logo.svg" width="96"></p>"#))
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script>"))
    }

    @Test("The page runs nothing and fetches nothing it was not meant to")
    func pagePolicy() {
        let page = MarkdownHTML.page("# Title", fontSize: 13)

        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("form-action 'none'"))
        // No source is named for scripts, so `default-src` refuses them.
        #expect(!page.contains("script-src"))
        #expect(page.contains("img-src relay-file: https: data:"))
    }

    @Test("Markdown is recognised by its extension", arguments: [
        ("README.md", true),
        ("notes.MARKDOWN", true),
        ("page.mdx", false),
        ("main.swift", false),
    ])
    func recognised(name: String, isMarkdown: Bool) {
        #expect(MarkdownHTML.isMarkdown(path: "/p/\(name)") == isMarkdown)
    }
}

@Suite("Where a preview's links go")
struct MarkdownLinkTests {
    private let document = "/Users/me/My Project/README.md"

    private func resolved(_ href: String) throws -> URL {
        let base = try #require(PreviewAddress.url(for: document))
        return try #require(URL(string: href, relativeTo: base)?.absoluteURL)
    }

    @Test("An address stands for its path, spaces and all")
    func roundTrip() throws {
        let url = try #require(PreviewAddress.url(for: document))
        #expect(url.absoluteString == "relay-file:///Users/me/My%20Project/README.md")
        #expect(PreviewAddress.path(of: url) == document)
        #expect(PreviewAddress.path(of: URL(fileURLWithPath: document)) == nil)
    }

    @Test("A relative link resolves beside the document, as it would on disk")
    func relativeLinks() throws {
        #expect(PreviewAddress.path(of: try resolved("docs/shot.png")) == "/Users/me/My Project/docs/shot.png")
        #expect(PreviewAddress.path(of: try resolved("../other.md")) == "/Users/me/other.md")
    }

    @Test("A heading of the document scrolls; the document itself goes nowhere")
    func withinThePage() throws {
        #expect(MarkdownLink.destination(of: try resolved("#usage"), from: document) == .withinPage)
        #expect(MarkdownLink.destination(of: try resolved("README.md"), from: document) == nil)
    }

    @Test("Another file opens in Relay")
    func otherFiles() throws {
        #expect(MarkdownLink.destination(of: try resolved("docs/SPEC.md"), from: document)
            == .file("/Users/me/My Project/docs/SPEC.md"))
        #expect(MarkdownLink.destination(of: try #require(URL(string: "file:///etc/hosts")), from: document)
            == .file("/etc/hosts"))
    }

    @Test("The web and mail go to the apps for them, and nothing else goes anywhere")
    func externalLinks() throws {
        let web = try #require(URL(string: "https://example.com/page"))
        let mail = try #require(URL(string: "mailto:someone@example.com"))
        #expect(MarkdownLink.destination(of: web, from: document) == .external(web))
        #expect(MarkdownLink.destination(of: mail, from: document) == .external(mail))

        for href in ["javascript:alert(1)", "x-apple.systempreferences:com.apple.preference.security", "vscode://file/x"] {
            let url = try #require(URL(string: href))
            #expect(MarkdownLink.destination(of: url, from: document) == nil, "\(href)")
        }
    }

    @Test("The page is handed pictures beside it, and nothing that is not a file")
    func servedFiles() throws {
        let directory = try TemporaryDirectory()
        try directory.write("<svg xmlns=\"http://www.w3.org/2000/svg\"/>", to: "logo.svg")
        let logo = try #require(PreviewAddress.url(for: directory.url.appendingPathComponent("logo.svg").path))

        let served = try #require(PreviewAddress.contents(of: logo))
        #expect(served.mimeType == "image/svg+xml")
        #expect(!served.data.isEmpty)

        #expect(PreviewAddress.contents(of: try #require(PreviewAddress.url(for: directory.url.path))) == nil)
        #expect(PreviewAddress.contents(of: directory.url.appendingPathComponent("logo.svg")) == nil)
    }
}
