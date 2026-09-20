import CodeEditLanguages
import Foundation
import SwiftTreeSitter

/// What language a file is written in, as far as highlighting is concerned.
///
/// A wrapper rather than `CodeLanguage` itself: which grammar set Relay uses is
/// a decision that has already been changed once, and everything outside this
/// directory should not have to be edited when it changes again.
struct SourceLanguage: Equatable {
    let code: CodeLanguage
    /// The template tags this file adds to the language it is written in, when
    /// it is a kind of file that does that.
    let markup: TemplateMarkup?

    init(code: CodeLanguage, markup: TemplateMarkup? = nil) {
        self.code = code
        self.markup = markup
    }

    static func == (lhs: SourceLanguage, rhs: SourceLanguage) -> Bool {
        lhs.code.id == rhs.code.id && lhs.markup == rhs.markup
    }

    /// A parser set to this grammar, or nil when the grammar is not there.
    ///
    /// Made fresh each time rather than kept: a parser owns the last tree it
    /// produced, so one shared between the colouring and the symbol index
    /// would be one mutable object with two users — and building one costs
    /// nothing beside the parse it is for.
    func parser() -> Parser? {
        guard let tsLanguage = code.language else { return nil }
        let parser = Parser()
        do {
            try parser.setLanguage(tsLanguage)
        } catch {
            return nil
        }
        return parser
    }

    /// The language a grammar's injection names, if there is one.
    ///
    /// Injections name languages the way tree-sitter does — `html`, `css`,
    /// `javascript` — and a few of the names in use are aliases the grammar
    /// set does not carry.
    init?(tsName: String) {
        let wanted = switch tsName.lowercased() {
        case "js", "jsx": "javascript"
        case "ts": "typescript"
        case "sh", "shell", "zsh": "bash"
        case "yml": "yaml"
        case "md": "markdown"
        default: tsName.lowercased()
        }
        guard let match = CodeLanguage.allLanguages.first(where: { $0.tsName == wanted }) else { return nil }
        code = match
        markup = nil
    }

    /// The language of the file at this path, or nil when nothing recognises it.
    ///
    /// The first lines are read as well as the name, because a file called
    /// `release` with `#!/usr/bin/env bash` at the top is a shell script and a
    /// file with no extension is otherwise nothing at all.
    static func detect(path: String, contents: String) -> SourceLanguage? {
        let url = URL(fileURLWithPath: path)
        let prefix = contents.prefix(512)
        let name = url.lastPathComponent
        let markup = TemplateMarkup.forFile(named: name)
        let language = CodeLanguage.detectLanguageFrom(
            url: url,
            prefixBuffer: String(prefix),
            suffixBuffer: nil
        )
        guard language.id != CodeLanguage.default.id else {
            guard let host = template(named: name) ?? dotfile(named: name) else { return nil }
            return SourceLanguage(code: host.code, markup: markup)
        }
        return SourceLanguage(code: language, markup: markup)
    }

    /// The files whose name *is* their type. `.env` and its variants have no
    /// grammar of their own; the shell's reads them correctly — `# comment`,
    /// `KEY=value`, `${expansion}` — which is the whole of the format.
    private static func dotfile(named name: String) -> SourceLanguage? {
        let lowered = name.lowercased()
        if lowered == ".env" || lowered.hasPrefix(".env.") {
            return SourceLanguage(code: .bash)
        }
        switch lowered {
        case ".bashrc", ".bash_profile", ".zshrc", ".profile":
            return SourceLanguage(code: .bash)
        default:
            return nil
        }
    }

    /// Template languages, read as the language they are mostly made of.
    ///
    /// None of these has a grammar here, and each is a host language with tags
    /// sprinkled through it: a Vue single-file component is HTML with `script`
    /// and `style` in it, a Twig or ERB template is HTML with statements, a
    /// Blade template is HTML with directives. Read as their host they come out
    /// almost entirely right — the markup, the embedded script and the styles
    /// are all coloured — and the handful of template tags stay plain. Read as
    /// nothing, which is what happened before, the whole file is white.
    ///
    /// `.blade.php` is not here: it ends in `.php`, so it is already found, and
    /// PHP injects HTML into itself.
    private static func template(named name: String) -> SourceLanguage? {
        guard templateExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
        return SourceLanguage(code: .html)
    }

    /// The template extensions, every one of which is mostly HTML. Read by the
    /// symbol index too: a project of `.vue` files has all of its names inside
    /// them, and a scan that does not know the extension never opens one.
    static let templateExtensions: Set<String> = [
        "vue", "svelte", "twig", "erb", "hbs", "handlebars", "mustache", "ejs", "liquid", "njk", "astro",
    ]
}
