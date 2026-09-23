import AppKit
import cmark_gfm
import cmark_gfm_extensions
import RelayUI
import SwiftUI

/// Markdown made into the page its preview shows.
///
/// Parsed by cmark-gfm, which is what GitHub renders with, so a README reads
/// here the way it will read there: tables, task lists, strikethrough,
/// footnotes, bare links. Two things are done to the tree before it is
/// written out, and both are things GitHub does after cmark has finished:
/// headings get the anchors a table of contents links to, and fenced code is
/// coloured by the grammars the editor colours it with.
///
/// On the main actor because the colouring is.
@MainActor
enum MarkdownHTML {
    static func isMarkdown(path: String) -> Bool {
        ["md", "markdown", "mdown", "mkd", "mkdn"].contains((path as NSString).pathExtension.lowercased())
    }

    /// A whole page: the document, the styles, and the policy that keeps it
    /// a document.
    ///
    /// Raw HTML in the Markdown is let through, because a README's centred
    /// logo and its badges are raw HTML and a preview without them is not the
    /// file. What it cannot do is run: no script, no frame, no form and no
    /// request to anywhere but the disk and HTTPS images. The web view refuses
    /// scripts as well; this is the second lock rather than the only one.
    static func page(_ markdown: String, fontSize: CGFloat) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; \
        img-src \(PreviewAddress.scheme): https: data:; media-src \(PreviewAddress.scheme): https:; \
        style-src 'unsafe-inline'; form-action 'none'">
        <style>\(stylesheet(fontSize: fontSize))</style>
        </head>
        <body>
        \(body(markdown))
        </body>
        </html>
        """
    }

    /// The document alone, as cmark writes it out once the tree is done with.
    static func body(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()

        let options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }

        // `tagfilter` is GitHub's: the raw HTML it lets through still cannot
        // open a `script`, `style`, `iframe` or `textarea`.
        for name in ["table", "strikethrough", "autolink", "tasklist", "tagfilter"] {
            guard let extensionNode = cmark_find_syntax_extension(name) else { continue }
            cmark_parser_attach_syntax_extension(parser, extensionNode)
        }

        markdown.withCString { cmark_parser_feed(parser, $0, strlen($0)) }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }

        rewrite(document)

        guard let rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser))
        else { return "" }
        defer { free(rendered) }
        return String(cString: rendered)
    }

    /// Anchors on the headings and colour in the code, collected first and
    /// changed after: an iterator walking a tree that is being rearranged
    /// under it walks off the end of it.
    private static func rewrite(_ document: UnsafeMutablePointer<cmark_node>) {
        var headings: [UnsafeMutablePointer<cmark_node>] = []
        var codeBlocks: [UnsafeMutablePointer<cmark_node>] = []

        let iterator = cmark_iter_new(document)
        defer { cmark_iter_free(iterator) }
        while case let event = cmark_iter_next(iterator), event != CMARK_EVENT_DONE {
            guard event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else { continue }
            switch cmark_node_get_type(node) {
            case CMARK_NODE_HEADING: headings.append(node)
            case CMARK_NODE_CODE_BLOCK: codeBlocks.append(node)
            default: break
            }
        }

        var slugs = HeadingSlugs()
        for heading in headings {
            let slug = slugs.slug(for: plainText(of: heading))
            guard let anchor = cmark_node_new(CMARK_NODE_HTML_INLINE) else { continue }
            cmark_node_set_literal(anchor, "<a id=\"\(escaped(slug))\" class=\"anchor\"></a>")
            cmark_node_prepend_child(heading, anchor)
        }

        for block in codeBlocks {
            let info = cmark_node_get_fence_info(block).map { String(cString: $0) } ?? ""
            let code = cmark_node_get_literal(block).map { String(cString: $0) } ?? ""
            guard let replacement = cmark_node_new(CMARK_NODE_HTML_BLOCK) else { continue }
            cmark_node_set_literal(replacement, codeBlock(code, info: info))
            cmark_node_replace(block, replacement)
            cmark_node_free(block)
        }
    }

    /// What a heading says, which is what its anchor is made from. Text and
    /// code only: the emphasis and the link around a word are not part of it.
    private static func plainText(of heading: UnsafeMutablePointer<cmark_node>) -> String {
        var text = ""
        let iterator = cmark_iter_new(heading)
        defer { cmark_iter_free(iterator) }
        while case let event = cmark_iter_next(iterator), event != CMARK_EVENT_DONE {
            guard event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else { continue }
            switch cmark_node_get_type(node) {
            case CMARK_NODE_TEXT, CMARK_NODE_CODE:
                text += cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
            case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK:
                text += " "
            default:
                break
            }
        }
        return text
    }

    // MARK: - Code

    /// A fenced block, coloured when its fence names a language the editor
    /// knows and left plain when it does not.
    static func codeBlock(_ code: String, info: String) -> String {
        let name = info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let language = self.language(named: name)
        let classAttribute = name.isEmpty ? "" : " class=\"language-\(escaped(name))\""
        return "<pre><code\(classAttribute)>\(highlighted(code, language: language))</code></pre>\n"
    }

    /// The language a fence names, by the grammar's own name — `swift`,
    /// `typescript`, `bash` — and failing that by the extension a file of it
    /// would have, which is how most people write the short ones: `py`, `rb`,
    /// `rs`.
    static func language(named name: String) -> SourceLanguage? {
        guard !name.isEmpty else { return nil }
        return SourceLanguage(tsName: name)
            ?? SourceLanguage.detect(path: "fence.\(name.lowercased())", contents: "")
    }

    private static func highlighted(_ code: String, language: SourceLanguage?) -> String {
        guard let language else { return escaped(code) }
        let source = code as NSString
        let spans = SourceHighlighter.spans(in: code, language: language)
        guard !spans.isEmpty else { return escaped(code) }

        // One role per UTF-16 unit, later spans winning — the order the editor
        // paints them in — and then the runs of one role written out as one
        // element each. Spans overlap, and HTML elements cannot.
        var roles = [SourceHighlighter.Role?](repeating: nil, count: source.length)
        for span in spans where NSMaxRange(span.range) <= source.length {
            for index in span.range.location ..< NSMaxRange(span.range) {
                roles[index] = span.role
            }
        }

        var html = ""
        var start = 0
        while start < source.length {
            var end = start + 1
            while end < source.length, roles[end] == roles[start] { end += 1 }
            let run = escaped(source.substring(with: NSRange(location: start, length: end - start)))
            if let role = roles[start], role != .plain {
                let italic = role == .comment ? ";font-style:italic" : ""
                html += "<span style=\"color:\(hex(role.colour))\(italic)\">\(run)</span>"
            } else {
                html += run
            }
            start = end
        }
        return html
    }

    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: - Styles

    /// The window's own colours, read from the theme rather than copied out of
    /// it, so the preview cannot drift from the panes around it.
    private static func stylesheet(fontSize: CGFloat) -> String {
        let palette = Theme.Palette.self
        return """
        :root { color-scheme: dark; }
        html { background: \(hex(palette.base)); }
        body {
          margin: 0 auto; max-width: 880px; padding: 20px 28px 56px;
          font: \(Int(fontSize.rounded()) + 1)px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
          color: \(hex(palette.textPrimary)); -webkit-font-smoothing: antialiased; overflow-wrap: break-word;
        }
        body > :first-child { margin-top: 0; }
        ::selection { background: \(hex(palette.accentMuted)); }
        h1, h2, h3, h4, h5, h6 { margin: 1.6em 0 0.6em; font-weight: 600; line-height: 1.25; }
        h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid \(hex(palette.border)); }
        h1 { font-size: 1.9em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }
        h4 { font-size: 1em; } h5 { font-size: 0.9em; }
        h6 { font-size: 0.85em; color: \(hex(palette.textSecondary)); }
        p, ul, ol, dl, blockquote, pre, table { margin: 0 0 1em; }
        ul, ol { padding-left: 2em; }
        li + li { margin-top: 0.25em; }
        li > ul, li > ol { margin-bottom: 0; }
        li:has(> input[type=checkbox]) { list-style: none; }
        li > input[type=checkbox] { margin: 0 0.45em 0 -1.35em; vertical-align: middle; }
        a { color: \(hex(palette.accent)); text-decoration: none; }
        a:hover { text-decoration: underline; }
        strong { font-weight: 600; }
        del { color: \(hex(palette.textSecondary)); }
        hr { height: 1px; margin: 1.6em 0; border: 0; background: \(hex(palette.borderStrong)); }
        blockquote {
          margin-left: 0; padding: 0 1em;
          color: \(hex(palette.textSecondary)); border-left: 3px solid \(hex(palette.borderStrong));
        }
        code, pre, kbd { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.86em; }
        :not(pre) > code {
          padding: 0.15em 0.4em; border-radius: 4px; background: \(hex(palette.surfaceRaised));
        }
        pre {
          padding: 12px 14px; overflow: auto; line-height: 1.45; border-radius: 6px;
          background: \(hex(palette.surface)); border: 1px solid \(hex(palette.border));
          color: \(hex(Theme.Code.plain));
        }
        pre code { font-size: 1em; }
        kbd {
          padding: 0.1em 0.4em; border-radius: 4px;
          border: 1px solid \(hex(palette.borderStrong)); background: \(hex(palette.surfaceRaised));
        }
        table { display: block; width: max-content; max-width: 100%; overflow: auto; border-collapse: collapse; }
        th, td { padding: 6px 13px; border: 1px solid \(hex(palette.borderStrong)); }
        th { font-weight: 600; background: \(hex(palette.surface)); }
        tr:nth-child(2n) td { background: \(hex(palette.sidebar)); }
        img, video { max-width: 100%; }
        .footnotes { font-size: 0.9em; color: \(hex(palette.textSecondary)); }
        """
    }

    private static func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "inherit" }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }
}

/// The anchors GitHub gives headings, so a table of contents written against
/// GitHub still goes where it says here.
///
/// GitHub's rule, from its `github-slugger`: lower-cased, everything but
/// letters, digits, spaces, hyphens and underscores dropped, spaces made into
/// hyphens, and a heading that repeats an earlier one numbered from `-1`.
struct HeadingSlugs {
    private var occurrences: [String: Int] = [:]

    mutating func slug(for text: String) -> String {
        let kept = text.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-" || scalar == "_"
        }
        let original = String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")

        var slug = original
        while occurrences[slug] != nil {
            let count = (occurrences[original] ?? 0) + 1
            occurrences[original] = count
            slug = "\(original)-\(count)"
        }
        occurrences[slug] = 0
        return slug
    }
}
