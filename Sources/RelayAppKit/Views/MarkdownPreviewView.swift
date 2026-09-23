import AppKit
import RelayUI
import SwiftUI
import WebKit

/// A Markdown file as it reads rather than as it is written.
///
/// A web view, because what Markdown turns into is HTML — tables, nested
/// lists, a README's raw `<p align="center">` — and every native way of
/// drawing that is a web view with fewer features. It is a web view that runs
/// nothing: scripts are off, and the page's own policy refuses them again.
struct MarkdownPreviewView: NSViewRepresentable {
    /// Asked of the page by the find bar. A request rather than a query for
    /// the reason a reveal is one: Return asks for the next match of the same
    /// text, and a view comparing queries would see nothing to do.
    struct Find: Equatable {
        let id = UUID()
        let query: String
        let backwards: Bool
    }

    let text: String
    let path: String
    let fontSize: CGFloat
    var find: Find?
    /// Whether the last find matched anything. The page does not say how many
    /// times, so this is all the find bar has to show.
    var onFound: (Bool) -> Void = { _ in }
    var onFocus: () -> Void = {}
    var onLink: (MarkdownLink) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PreviewWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(PreviewFileScheme(), forURLScheme: PreviewAddress.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Nothing a README loads from the network is kept afterwards.
        configuration.websiteDataStore = .nonPersistent()

        let view = PreviewWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = NSColor(Theme.Palette.base)
        // Hidden until the first page has been drawn: before that a web view
        // is white, and a white flash in a dark window reads as a fault.
        view.alphaValue = 0
        return view
    }

    func updateNSView(_ view: PreviewWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.documentPath = path
        coordinator.onLink = onLink
        view.onFocus = onFocus

        // Compared before rendering rather than after: the pane is redrawn for
        // reasons that have nothing to do with the file — focus, a checker
        // finishing — and parsing and colouring the document for each of them
        // would be most of the work this view ever does.
        let rendered = Coordinator.Rendered(text: text, path: path, fontSize: fontSize)
        if rendered != coordinator.rendered {
            let isSameDocument = coordinator.rendered?.path == path
            coordinator.rendered = rendered
            coordinator.show(
                MarkdownHTML.page(text, fontSize: fontSize),
                of: path,
                keepingPosition: isSameDocument,
                in: view
            )
        }

        if let find, find.id != coordinator.findID {
            coordinator.findID = find.id
            coordinator.run(find, in: view, reporting: onFound)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        struct Rendered: Equatable {
            let text: String
            let path: String
            let fontSize: CGFloat
        }

        var rendered: Rendered?
        var findID: UUID?
        var documentPath = ""
        var onLink: (MarkdownLink) -> Void = { _ in }

        /// Where the page was scrolled to before it was replaced, to put it
        /// back once the new one is drawn. The file re-read from disk, or the
        /// text made larger, is the same document, and being thrown back to
        /// its top is the one thing nobody reading it wants. A link followed
        /// to another document is a different one, and starts at its top.
        private var restoredOffset: Double?
        private var page = ""

        func show(_ page: String, of path: String, keepingPosition: Bool, in view: WKWebView) {
            self.page = page
            restoredOffset = nil
            guard keepingPosition, view.url != nil else {
                load(in: view, path: path)
                return
            }
            // Run in a world of its own, which is allowed although the page's
            // scripts are not; it reads where the page is scrolled and nothing
            // else.
            view.evaluateJavaScript("window.scrollY", in: nil, in: .defaultClient) { [weak self, weak view] result in
                guard let self, let view else { return }
                if case let .success(value) = result { restoredOffset = value as? Double }
                load(in: view, path: path)
            }
        }

        private func load(in view: WKWebView, path: String) {
            view.loadHTMLString(page, baseURL: PreviewAddress.url(for: path))
        }

        func run(_ find: Find, in view: WKWebView, reporting onFound: @escaping (Bool) -> Void) {
            guard !find.query.isEmpty else {
                view.evaluateJavaScript("window.getSelection().removeAllRanges()", in: nil, in: .defaultClient)
                onFound(true)
                return
            }
            let configuration = WKFindConfiguration()
            configuration.backwards = find.backwards
            configuration.caseSensitive = false
            configuration.wraps = true
            view.find(find.query, configuration: configuration) { result in
                onFound(result.matchFound)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }

            // The page being loaded, which is the only navigation that is not
            // somebody clicking: anything else a document starts on its own —
            // a `meta` refresh, a redirect — is refused.
            guard navigationAction.navigationType == .linkActivated else {
                return PreviewAddress.path(of: url) == documentPath ? .allow : .cancel
            }

            switch MarkdownLink.destination(of: url, from: documentPath) {
            case .withinPage:
                return .allow
            case let .some(destination):
                onLink(destination)
                return .cancel
            case nil:
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.alphaValue = 1
            guard let offset = restoredOffset else { return }
            restoredOffset = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(offset))", in: nil, in: .defaultClient)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            webView.alphaValue = 1
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            webView.alphaValue = 1
        }

        /// The page's process can be ended by the system under memory
        /// pressure, which leaves a blank pane that never comes back on its
        /// own.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            load(in: webView, path: documentPath)
        }
    }
}

/// Tells the pane it was clicked into, which a web view has no other way of
/// saying: the click is the web view's, and SwiftUI never sees it.
final class PreviewWebView: WKWebView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }
}

/// Answers the page's requests for the files beside the document.
///
/// Synchronous, because what a Markdown file embeds is pictures and a picture
/// is a read measured in milliseconds; `PreviewAddress` refuses anything
/// large enough for that to stop being true. A task answered on the spot also
/// cannot have been cancelled in between, and answering a cancelled one is an
/// exception rather than an error.
@MainActor
final class PreviewFileScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let file = PreviewAddress.contents(of: url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(URLResponse(
            url: url,
            mimeType: file.mimeType,
            expectedContentLength: file.data.count,
            textEncodingName: nil
        ))
        urlSchemeTask.didReceive(file.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
