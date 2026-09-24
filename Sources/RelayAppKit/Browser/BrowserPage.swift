import AppKit
import Foundation
import Observation
import RelayProtocol
import RelayUI

enum BrowserSubject: Sendable {}

/// Which browser tab. Made by Relay rather than the daemon: a page lives in
/// the app's own process, and ends with it.
typealias BrowserID = Identifier<BrowserSubject>

/// A browser tab as the workspace file keeps it, so the tabs a project had
/// come back with their pages and their names.
struct BrowserTab: Codable, Equatable, Sendable {
    var id: BrowserID
    var projectID: ProjectID
    var address: String
    var title: String
}

/// One browser tab: the page, what it is doing, and design mode.
///
/// A tab is listed with the project's sessions and opened the same way, from
/// the "+" beside them, because it is used the same way: it is where the work
/// shows, next to the agent doing it.
@MainActor
@Observable
final class BrowserPage {
    enum Problem: Equatable {
        /// Chromium cannot run in this build.
        case unavailable(String)
        case loadFailed(ChromiumPage.Failure)
        /// The page's renderer died.
        case crashed
    }

    /// Where design mode is.
    enum Design: Equatable {
        case off
        /// The overlay is up, waiting for a click.
        case picking
        /// A click landed and its picture is being taken.
        case capturing
        /// Something was picked, and waits to be sent or let go.
        case picked(DesignSelection)
    }

    let id: BrowserID
    let projectID: ProjectID
    private(set) var address: String
    private(set) var title: String
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var problem: Problem?
    private(set) var design: Design = .off
    /// What the person wants done about the picked element. Kept here rather
    /// than in the card, so a half-written request survives the pane being
    /// rebuilt.
    var note = ""

    var isDesignModeOn: Bool { design != .off }

    /// What the tab is called in the sidebar: the page's own title, or where
    /// it is when it has none yet.
    var name: String {
        if !title.isEmpty { return title }
        if let host = URL(string: address)?.host, !host.isEmpty {
            return URL(string: address)?.port.map { "\(host):\($0)" } ?? host
        }
        return relayLocalized("New Tab")
    }

    var record: BrowserTab {
        BrowserTab(id: id, projectID: projectID, address: address, title: title)
    }

    /// Called when the page takes the keyboard, so the pane it is in can
    /// count as the one being worked in.
    @ObservationIgnored var onFocus: (() -> Void)?
    /// Called for a link that asked for a new tab.
    @ObservationIgnored var onNewTab: ((URL) -> Void)?
    /// Called when the address or the title changes, which is what the
    /// workspace file keeps of a tab.
    @ObservationIgnored var onRecordChange: (() -> Void)?

    @ObservationIgnored let chromium: ChromiumPage
    @ObservationIgnored private var designTask: Task<Void, Never>?

    init(id: BrowserID = .generate(), projectID: ProjectID, address: String, title: String = "") {
        self.id = id
        self.projectID = projectID
        self.address = address
        self.title = title
        chromium = ChromiumPage(address: address.isEmpty ? "about:blank" : address)
        chromium.onAddress = { [weak self] url in
            self?.address = url
            self?.onRecordChange?()
        }
        chromium.onTitle = { [weak self] title in
            self?.title = title
            self?.onRecordChange?()
        }
        chromium.onLoading = { [weak self] loading in self?.loadingChanged(loading) }
        chromium.onFailure = { [weak self] failure in self?.problem = .loadFailed(failure) }
        chromium.onCrash = { [weak self] in self?.crashed() }
        chromium.onFocus = { [weak self] in self?.onFocus?() }
        chromium.onUnavailable = { [weak self] reason in self?.problem = .unavailable(reason) }
        chromium.onNewTab = { [weak self] url in
            guard let url = URL(string: url) else { return }
            self?.onNewTab?(url)
        }
    }

    // MARK: - Going places

    /// Goes to whatever was typed into the address field.
    func go(to typed: String) {
        guard let url = BrowserAddress.url(from: typed) else { return }
        open(url)
    }

    func open(_ url: URL) {
        if case .unavailable = problem { return }
        problem = nil
        address = url.absoluteString
        chromium.load(url.absoluteString)
        chromium.focus()
    }

    func goBack() { chromium.goBack() }
    func goForward() { chromium.goForward() }
    func showDevTools() { chromium.showDevTools() }
    func focus() { chromium.focus() }

    func reload() {
        if case .unavailable = problem { return }
        problem = nil
        chromium.reload()
    }

    func stop() { chromium.stop() }

    func close() {
        designTask?.cancel()
        design = .off
        chromium.close()
    }

    private func loadingChanged(_ loading: ChromiumPage.Loading) {
        let finished = isLoading && !loading.isLoading
        isLoading = loading.isLoading
        canGoBack = loading.canGoBack
        canGoForward = loading.canGoForward
        if loading.isLoading, case .loadFailed = problem { problem = nil }
        if loading.isLoading, problem == .crashed { problem = nil }
        // A new document has no overlay in it. The one that was up went with
        // the page it was in, so it is put back once there is a page again.
        if finished, design == .picking || design == .capturing {
            startPicking()
        }
    }

    private func crashed() {
        problem = .crashed
        if isDesignModeOn, !isPicked { design = .picking }
    }

    // MARK: - Design mode

    private var isPicked: Bool {
        if case .picked = design { return true }
        return false
    }

    func toggleDesignMode() {
        isDesignModeOn ? stopDesignMode() : startDesignMode()
    }

    func startDesignMode() {
        guard !isDesignModeOn else { return }
        design = .picking
        chromium.focus()
        startPicking()
    }

    func stopDesignMode() {
        guard isDesignModeOn else { return }
        if case let .picked(selection) = design { selection.discardScreenshot() }
        design = .off
        note = ""
        designTask?.cancel()
        designTask = Task { [chromium] in
            _ = try? await chromium.devTools.evaluate(DesignModeScript.teardown, as: Bool.self)
        }
    }

    /// Lets go of what was picked and waits for the next click.
    func dismissPick() {
        guard case let .picked(selection) = design else { return }
        selection.discardScreenshot()
        resumePicking()
    }

    /// The pick has been handed on; the overlay comes back for the next one,
    /// which is how a change is checked after the agent has made it.
    func resumePicking() {
        guard isPicked else { return }
        note = ""
        design = .picking
        startPicking()
    }

    /// One round: put the overlay up, wait for a click, describe and
    /// photograph what was clicked. Anything that interrupts it — a
    /// navigation, a reload, the page crashing — simply ends the round, and
    /// the next finished load starts another.
    private func startPicking() {
        designTask?.cancel()
        designTask = Task { [weak self] in
            await self?.pickOnce()
        }
    }

    private func pickOnce() async {
        let devTools = chromium.devTools
        do {
            guard try await devTools.evaluate(DesignModeScript.arm, as: Bool.self) == true, design == .picking else {
                return
            }
            let reply = try await devTools.evaluate(DesignModeScript.pick, awaitingPromise: true, as: DesignPickReply.self)
            guard design == .picking, !Task.isCancelled else { return }
            switch reply {
            case let .picked(pick):
                design = .capturing
                let screenshot = await photograph(pick)
                guard design == .capturing else { return }
                design = .picked(DesignSelection(pick: pick, screenshot: screenshot))
            case .cancelled("escape"):
                stopDesignMode()
            case .cancelled, .failed, .none:
                break
            }
        } catch {
            // The document it was waiting in went away. The next load that
            // finishes starts a new round.
        }
    }

    private func photograph(_ pick: DesignPick) async -> URL? {
        guard let clip = pick.visibleRectInDocument else { return nil }
        let devTools = chromium.devTools
        _ = try? await devTools.evaluate(DesignModeScript.hide, as: Bool.self)
        let png = try? await devTools.screenshot(of: clip)
        _ = try? await devTools.evaluate(DesignModeScript.show, as: Bool.self)
        guard let png else { return nil }
        return try? DesignScreenshots.save(png, of: pick)
    }
}

/// A picked element and its picture.
struct DesignSelection: Equatable {
    let pick: DesignPick
    let screenshot: URL?

    /// The picture of a pick nobody sent is nobody's.
    func discardScreenshot() {
        guard let screenshot else { return }
        try? FileManager.default.removeItem(at: screenshot)
    }
}
