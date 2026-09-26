import AppKit
import Foundation

/// An issue as it is pasted into a chat: its key and its summary on one line,
/// with the key a link to the issue — what the tracker's own copy button puts
/// on the clipboard, and what a message about an issue is written as.
///
/// Three forms, because what is pasted into takes the richest it can read: a
/// chat or a mail reads the HTML or the RTF and gets the link, a terminal
/// reads the plain text and gets the words.
enum IssueReference {
    static func text(key: String, summary: String) -> String {
        summary.isEmpty ? key : "\(key) \(summary)"
    }

    static func html(key: String, summary: String, link: URL) -> String {
        let anchor = "<a href=\"\(escaped(link.absoluteString))\">\(escaped(key))</a>"
        return summary.isEmpty ? anchor : "\(anchor) \(escaped(summary))"
    }

    static func rtf(key: String, summary: String, link: URL) -> Data? {
        let text = NSMutableAttributedString(string: self.text(key: key, summary: summary))
        text.addAttribute(.link, value: link, range: NSRange(location: 0, length: (key as NSString).length))
        return try? text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// Puts all three on the clipboard at once, in place of what was there.
    /// Without a link — no tracker to make one — it is the plain text alone.
    @MainActor
    static func copy(key: String, summary: String, link: URL?, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text(key: key, summary: summary), forType: .string)
        guard let link else { return }
        pasteboard.setString(html(key: key, summary: summary, link: link), forType: .html)
        if let rtf = rtf(key: key, summary: summary, link: link) {
            pasteboard.setData(rtf, forType: .rtf)
        }
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
