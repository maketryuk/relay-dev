import Foundation
import UniformTypeIdentifiers

/// How a Markdown preview reaches the files beside it.
///
/// The page is given an address of its own scheme — the document's path, under
/// `relay-file:` — rather than a `file:` one, because a web view shown HTML it
/// was handed as a string does not read `file:` addresses at all. With it, a
/// relative `docs/screenshot.png` resolves against the document the way it
/// would on disk, and Relay answers the request.
enum PreviewAddress {
    static let scheme = "relay-file"

    /// Larger than any picture a README embeds, smaller than the video that
    /// would otherwise be read whole into memory on the main thread.
    static let largestServed = 32 * 1024 * 1024

    static func url(for path: String) -> URL? {
        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url
    }

    /// The path an address of this scheme stands for; nil for any other.
    static func path(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    /// What the page asked for, if it is a file this is willing to hand over.
    static func contents(of url: URL) -> (data: Data, mimeType: String)? {
        guard let path = path(of: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= largestServed,
              let data = FileManager.default.contents(atPath: path)
        else { return nil }
        let mimeType = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType
        return (data, mimeType ?? "application/octet-stream")
    }
}

/// Where a link clicked in a preview goes.
enum MarkdownLink: Equatable {
    /// A heading of the document being shown, which the page scrolls to.
    case withinPage
    /// Another file, opened the way the tree opens it: in the pane, as text or
    /// as a preview.
    case file(String)
    /// Somewhere a browser or a mail client is for.
    case external(URL)

    /// Nil for a link that goes nowhere Relay is willing to send it. A README
    /// can link to any scheme there is, and one of them launching an
    /// application on a click is not what a preview is for.
    static func destination(of url: URL, from documentPath: String) -> MarkdownLink? {
        if let path = PreviewAddress.path(of: url) {
            guard path == documentPath else { return .file(path) }
            // The document itself with no heading named is the page already
            // on screen; letting the web view load it would fetch the
            // Markdown as the page's replacement.
            return url.fragment?.isEmpty == false ? .withinPage : nil
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": return .external(url)
        case "file" where !url.path.isEmpty: return .file(url.path)
        default: return nil
        }
    }
}
