import CoreGraphics
import Foundation
import RelayProtocol

/// An element picked in design mode: what the page said about it.
///
/// Decoded from what `DesignModeScript` returns, and clamped again on the way
/// in. The script runs in the page's own world, where the page can replace
/// anything it calls, so every length it promises is enforced here as well —
/// this is text that will be typed into an agent's prompt.
struct DesignPick: Equatable, Sendable {
    struct Page: Equatable, Sendable {
        var url: String
        var title: String
        var viewport: CGSize
        var scroll: CGPoint
    }

    struct Source: Equatable, Sendable {
        var file: String
        var line: Int?
        var column: Int?
        /// False when the line is read off the dev server's own copy of the
        /// file, which transpiling may have moved.
        var isExact: Bool
    }

    struct Style: Equatable, Sendable {
        var name: String
        var value: String
    }

    var page: Page
    var tag: String
    var selector: String
    /// Where the element is, by its landmarks.
    var path: String
    var text: String
    var accessibleName: String?
    var role: String?
    var html: String
    /// Viewport coordinates, in CSS pixels.
    var rect: CGRect
    /// The computed styles worth reading, in the order the script lists them.
    var styles: [Style]
    var framework: String?
    /// Outermost first.
    var components: [String]
    var source: Source?
    var nearby: [String]

    /// The component nearest the element, which is usually the one to edit.
    var component: String? { components.last }

    /// How the element is named in a sentence: its tag and what it says.
    var label: String {
        let words = accessibleName ?? (text.isEmpty ? nil : text)
        guard let words else { return tag }
        return "\(tag) \"\(DesignPick.clamp(words, to: 60))\""
    }

    /// The part of the element that is on screen, from the top of the
    /// document: what a picture of it can show.
    var visibleRectInDocument: CGRect? {
        let viewport = CGRect(origin: .zero, size: page.viewport)
        let visible = rect.intersection(viewport)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
        return visible.offsetBy(dx: page.scroll.x, dy: page.scroll.y)
    }

    static func clamp(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

/// What waiting for a click came back with.
enum DesignPickReply: Decodable, Equatable, Sendable {
    case picked(DesignPick)
    /// Nothing was picked: Escape, design mode turned off, the overlay gone.
    case cancelled(String)
    /// The page threw while describing the element.
    case failed(String)

    private enum Keys: String, CodingKey {
        case cancelled, failed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let reason = try container.decodeIfPresent(String.self, forKey: .cancelled) {
            self = .cancelled(reason)
        } else if let failure = try container.decodeIfPresent(String.self, forKey: .failed) {
            self = .failed(failure)
        } else {
            self = .picked(try DesignPick(from: decoder))
        }
    }
}

extension DesignPick: Decodable {
    private enum Keys: String, CodingKey {
        case page, element, nearby
    }

    private struct Wire: Decodable {
        struct Size: Decodable { var width: Double; var height: Double }
        struct Point: Decodable { var x: Double; var y: Double }
        struct Rect: Decodable { var x: Double; var y: Double; var width: Double; var height: Double }

        struct Page: Decodable {
            var url: String?
            var title: String?
            var viewport: Size?
            var scroll: Point?
        }

        struct Source: Decodable {
            var file: String?
            var line: Int?
            var column: Int?
            var exact: Bool?
        }

        struct Element: Decodable {
            var tag: String?
            var selector: String?
            var path: String?
            var text: String?
            var html: String?
            var role: String?
            var name: String?
            var rect: Rect?
            var styles: [String: String]?
            var framework: String?
            var components: [String]?
            var source: Source?
        }
    }

    /// The styles in the order the script asks for them, which is the order
    /// a person reads a box in: what it is, how big, its colours, its type.
    static let styleOrder = [
        "display", "position", "width", "height", "margin", "padding", "gap",
        "color", "background-color", "border", "border-radius", "box-shadow",
        "font-family", "font-size", "font-weight", "line-height", "text-align",
        "opacity", "z-index",
    ]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let page = try container.decodeIfPresent(Wire.Page.self, forKey: .page)
        let element = try container.decode(Wire.Element.self, forKey: .element)
        let nearby = try container.decodeIfPresent([String].self, forKey: .nearby) ?? []

        func finite(_ value: Double?) -> Double {
            guard let value, value.isFinite else { return 0 }
            return value
        }

        self.page = Page(
            url: Self.clamp(Self.withoutQuery(page?.url ?? ""), to: 500),
            title: Self.clamp(page?.title ?? "", to: 200),
            viewport: CGSize(width: max(0, finite(page?.viewport?.width)), height: max(0, finite(page?.viewport?.height))),
            scroll: CGPoint(x: finite(page?.scroll?.x), y: finite(page?.scroll?.y))
        )
        tag = Self.clamp(element.tag ?? "element", to: 40)
        selector = Self.clamp(element.selector ?? "", to: 700)
        path = Self.clamp(element.path ?? "", to: 900)
        text = Self.clamp(element.text ?? "", to: 200)
        html = Self.clamp(element.html ?? "", to: 3000)
        role = element.role.map { Self.clamp($0, to: 40) }
        accessibleName = element.name.flatMap { $0.isEmpty ? nil : Self.clamp($0, to: 120) }
        rect = CGRect(
            x: finite(element.rect?.x),
            y: finite(element.rect?.y),
            width: max(0, finite(element.rect?.width)),
            height: max(0, finite(element.rect?.height))
        )
        let styles = element.styles ?? [:]
        self.styles = Self.styleOrder.compactMap { name in
            styles[name].map { Style(name: name, value: Self.clamp($0, to: 200)) }
        }
        framework = element.framework.map { Self.clamp($0, to: 20) }
        components = (element.components ?? []).prefix(6).map { Self.clamp($0, to: 80) }
        source = element.source.flatMap { source in
            guard let file = source.file, !file.isEmpty else { return nil }
            return Source(
                file: Self.clamp(file, to: 500),
                line: source.line.flatMap { $0 > 0 ? $0 : nil },
                column: source.column.flatMap { $0 > 0 ? $0 : nil },
                isExact: source.exact ?? false
            )
        }
        self.nearby = nearby.prefix(8).map { Self.clamp($0, to: 160) }
    }

    /// The script already drops queries and fragments; this is the same rule
    /// kept by the side that does not trust the script.
    private static func withoutQuery(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return "" }
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }
}

/// A pick as it is handed to an agent: the element, what the person wants done
/// about it, and where its picture is.
///
/// Flush left and labelled line by line, the way review notes are, so any one
/// line can be read without the rest. The markup goes last, fenced, because it
/// is the one part that runs to many lines.
enum DesignNoteTranscript {
    static func compose(_ pick: DesignPick, note: String, screenshot: URL?) -> String {
        var lines: [String] = []
        let heading = pick.page.title.isEmpty ? pick.page.url : "\(pick.page.url) (\(pick.page.title))"
        lines.append("Design feedback on \(heading)")
        lines.append("Viewport: \(Int(pick.page.viewport.width))×\(Int(pick.page.viewport.height))")

        let component = pick.component.map { "<\($0)> " } ?? ""
        lines.append("Element: \(component)\(pick.label)")
        if let source = pick.source {
            lines.append(sourceLine(source))
        }
        if pick.components.count > 1 {
            let chain = pick.components.map { "<\($0)>" }.joined(separator: " ")
            lines.append("Components (\(pick.framework ?? "UI")): \(chain)")
        }
        if !pick.selector.isEmpty {
            lines.append("Selector: \(pick.selector)")
        }
        if !pick.path.isEmpty, pick.path != pick.selector {
            lines.append("Location: \(pick.path)")
        }
        lines.append(
            "Size: \(Int(pick.rect.width.rounded()))×\(Int(pick.rect.height.rounded())) at \(Int(pick.rect.minX.rounded())), \(Int(pick.rect.minY.rounded()))"
        )
        let styles = telling(pick.styles)
        if !styles.isEmpty {
            lines.append("Styles: " + styles.map { "\($0.name): \($0.value)" }.joined(separator: "; "))
        }
        if !pick.text.isEmpty, pick.text != pick.accessibleName {
            lines.append("Text: \"\(pick.text)\"")
        }
        if !pick.nearby.isEmpty {
            lines.append("Nearby: " + pick.nearby.joined(separator: " · "))
        }
        if let screenshot {
            lines.append("Screenshot: \(screenshot.path)")
        }
        if !pick.html.isEmpty {
            let fence = fence(for: pick.html)
            lines.append("HTML:")
            lines.append(fence + "html")
            lines.append(pick.html)
            lines.append(fence)
        }
        let request = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !request.isEmpty {
            lines.append("User comment: \"\(request)\"")
        }
        return lines.joined(separator: "\n")
    }

    private static func sourceLine(_ source: DesignPick.Source) -> String {
        var place = source.file
        if let line = source.line {
            place += ":\(line)"
            if source.isExact, let column = source.column { place += ":\(column)" }
        }
        return source.isExact || source.line == nil
            ? "Source: \(place)"
            : "Source (line as the dev server serves it): \(place)"
    }

    /// The styles that say something. A value every element has unless told
    /// otherwise is noise, and so are width and height, which Size already
    /// gives rounded.
    static func telling(_ styles: [DesignPick.Style]) -> [DesignPick.Style] {
        styles.filter { style in
            let value = style.value.trimmingCharacters(in: .whitespaces)
            switch style.name {
            case "width", "height": return false
            case "position": return value != "static"
            case "opacity": return value != "1"
            case "background-color": return value != "rgba(0, 0, 0, 0)"
            case "border": return !value.hasPrefix("0px none") && !value.hasPrefix("none")
            default: return !["", "auto", "normal", "none", "0px"].contains(value)
            }
        }
    }

    /// One backtick more than the longest run in the markup, so nothing in it
    /// can close the fence early.
    private static func fence(for text: String) -> String {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}

/// Pictures of picked elements, on disk where an agent can read them.
///
/// A path in the prompt rather than the picture itself: a terminal carries
/// text, and both Claude Code and Codex open an image named by its path. A
/// week's worth is kept; nobody goes back further than that for a picture of a
/// button.
enum DesignScreenshots {
    static let keptFor: TimeInterval = 7 * 24 * 60 * 60

    static func save(
        _ png: Data,
        of pick: DesignPick,
        at date: Date = Date(),
        in directory: URL = RelayPaths.designDirectory
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prune(in: directory, now: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let name = "\(formatter.string(from: date))-\(slug(pick.component ?? pick.tag)).png"
        let url = directory.appendingPathComponent(name)
        try png.write(to: url, options: .atomic)
        return url
    }

    static func prune(in directory: URL, now: Date = Date()) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in names where url.pathExtension == "png" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > keptFor {
                try? manager.removeItem(at: url)
            }
        }
    }

    private static func slug(_ text: String) -> String {
        let allowed = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(allowed).split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "element" : String(slug.prefix(40))
    }
}
