import AppKit
import CChromium
import RelayUI

/// One Chromium page: the browser, the view it draws in, and the DevTools
/// channel to it.
///
/// The view outlives any SwiftUI view that shows it, the way a terminal's
/// renderer does: the page is created once, when its view first reaches a
/// window with room in it, and a pane that is rebuilt re-parents the same view
/// rather than loading the page again.
///
/// This file and `ChromiumEngine` are the only ones that know what renders
/// the page.
@MainActor
final class ChromiumPage {
    struct Loading: Equatable {
        var isLoading: Bool
        var canGoBack: Bool
        var canGoForward: Bool
    }

    struct Failure: Equatable {
        var code: Int
        var description: String
        var url: String
    }

    var onCreated: (() -> Void)?
    var onAddress: ((String) -> Void)?
    var onTitle: ((String) -> Void)?
    var onLoading: ((Loading) -> Void)?
    var onFailure: ((Failure) -> Void)?
    /// A link that asked for a tab of its own.
    var onNewTab: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCrash: (() -> Void)?
    /// Chromium could not be started for this page, and why.
    var onUnavailable: ((String) -> Void)?

    /// The view Relay owns; Chromium's own view goes inside it.
    let view = PageHostView()
    private(set) lazy var devTools = DevToolsSession { [weak self] message in
        self?.send(message) ?? false
    }

    private var handle: OpaquePointer?
    private var address: String
    private var isClosed = false
    private var isCreationScheduled = false

    init(address: String) {
        self.address = address
        view.onRoom = { [weak self] in self?.scheduleCreation() }
    }

    var isReady: Bool { handle != nil && !isClosed && relay_chromium_browser_view(handle) != nil }

    func load(_ url: String) {
        address = url
        guard let handle else { return }
        relay_chromium_browser_load(handle, url)
    }

    func goBack() { handle.map { relay_chromium_browser_go_back($0) } }
    func goForward() { handle.map { relay_chromium_browser_go_forward($0) } }
    func stop() { handle.map { relay_chromium_browser_stop($0) } }
    func showDevTools() { handle.map { relay_chromium_browser_show_devtools($0) } }

    func reload(ignoringCache: Bool = false) {
        handle.map { relay_chromium_browser_reload($0, ignoringCache ? 1 : 0) }
    }

    func focus() {
        handle.map { relay_chromium_browser_set_focus($0, 1) }
    }

    /// Takes the page down. Its view is emptied, and the page reports back
    /// through `ChromiumEngine` once Chromium has let it go.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        devTools.abandonAll()
        guard let handle else { return }
        relay_chromium_browser_close(handle)
    }

    // MARK: - Chromium's side

    /// On the next turn rather than now: the view learns it has room in the
    /// middle of a layout pass, and starting Chromium means starting threads
    /// and processes, which is no thing to do inside one.
    private func scheduleCreation() {
        guard handle == nil, !isClosed, !isCreationScheduled else { return }
        isCreationScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isCreationScheduled = false
                self?.createIfPossible()
            }
        }
    }

    private func createIfPossible() {
        guard handle == nil, !isClosed, view.window != nil, view.bounds.width >= 1, view.bounds.height >= 1 else {
            return
        }
        let engine = ChromiumEngine.shared
        guard engine.start() else {
            if case let .unavailable(reason) = engine.state { onUnavailable?(reason) }
            return
        }
        // Held by Chromium until it reports the page closed, so that no
        // callback can arrive at a page that has already gone.
        let context = Unmanaged.passRetained(self).toOpaque()
        handle = relay_chromium_browser_create(
            Unmanaged.passUnretained(view).toOpaque(),
            Int32(view.bounds.width),
            Int32(view.bounds.height),
            address,
            Self.callbacks(context: context)
        )
        if handle == nil {
            Unmanaged<ChromiumPage>.fromOpaque(context).release()
            onUnavailable?(relayLocalized("Chromium could not open the page."))
            return
        }
        engine.opened(self)
    }

    private func send(_ message: Data) -> Bool {
        guard let handle, !isClosed else { return false }
        return message.withUnsafeBytes { bytes in
            relay_chromium_browser_send_devtools_message(
                handle,
                bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                bytes.count
            ) == 1
        }
    }

    fileprivate func didCreate() {
        if let pointer = relay_chromium_browser_view(handle) {
            // Not kept: a reference held here would keep the view alive past
            // the close, and the view going away is how the page is closed.
            let pageView = Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
            pageView.frame = view.bounds
            pageView.autoresizingMask = [.width, .height]
        }
        onCreated?()
    }

    fileprivate func didClose() {
        devTools.abandonAll()
        if let handle {
            relay_chromium_browser_release(handle)
        }
        handle = nil
        isClosed = true
        ChromiumEngine.shared.closed(self)
    }

    fileprivate func receive(_ message: Data) {
        devTools.receive(message)
    }

    /// Every callback arrives on the main thread, inside a turn of Chromium's
    /// work. Replies from the DevTools agent are handed on a turn later:
    /// answering one usually means sending the next question, and Chromium
    /// does not allow a message to be sent from inside the delivery of another.
    private static func callbacks(context: UnsafeMutableRawPointer) -> relay_chromium_callbacks {
        relay_chromium_callbacks(
            context: context,
            created: { context in
                MainActor.assumeIsolated { chromiumPage(context).didCreate() }
            },
            address_changed: { context, url in
                let url = cefText(url)
                MainActor.assumeIsolated { chromiumPage(context).onAddress?(url) }
            },
            title_changed: { context, title in
                let title = cefText(title)
                MainActor.assumeIsolated { chromiumPage(context).onTitle?(title) }
            },
            loading_changed: { context, isLoading, canGoBack, canGoForward in
                let loading = ChromiumPage.Loading(isLoading: isLoading != 0, canGoBack: canGoBack != 0, canGoForward: canGoForward != 0)
                MainActor.assumeIsolated { chromiumPage(context).onLoading?(loading) }
            },
            load_failed: { context, code, description, url in
                let failure = ChromiumPage.Failure(code: Int(code), description: cefText(description), url: cefText(url))
                MainActor.assumeIsolated { chromiumPage(context).onFailure?(failure) }
            },
            devtools_message: { context, json, length in
                guard let json else { return }
                let message = Data(bytes: json, count: length)
                MainActor.assumeIsolated {
                    let target = chromiumPage(context)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { target.receive(message) }
                    }
                }
            },
            opens_in_new_tab: { context, url in
                let url = cefText(url)
                MainActor.assumeIsolated { chromiumPage(context).onNewTab?(url) }
            },
            focused: { context in
                MainActor.assumeIsolated { chromiumPage(context).onFocus?() }
            },
            renderer_gone: { context, _ in
                MainActor.assumeIsolated {
                    let target = chromiumPage(context)
                    target.devTools.abandonAll()
                    target.onCrash?()
                }
            },
            closed: { context in
                MainActor.assumeIsolated { chromiumPage(context).didClose() }
                Unmanaged<ChromiumPage>.fromOpaque(context!).release()
            }
        )
    }
}

// Free functions rather than static members: a C function pointer cannot be
// formed from a closure that reaches the class, even through `Self`.

private func chromiumPage(_ context: UnsafeMutableRawPointer?) -> ChromiumPage {
    Unmanaged<ChromiumPage>.fromOpaque(context!).takeUnretainedValue()
}

private func cefText(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

/// The view a page lives in, and the one SwiftUI re-parents.
///
/// It says when it first has somewhere to draw — a window, and a size — which
/// is when Chromium can be asked for a page of the right size.
final class PageHostView: NSView {
    var onRoom: (() -> Void)?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onRoom?() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if window != nil { onRoom?() }
    }
}
