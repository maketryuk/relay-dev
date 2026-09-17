import AppKit
import Foundation
import Observation
import RelayProtocol
import RelayUI

/// Watches for a published release and, when the user asks, installs it.
///
/// The check is the only request Relay ever makes of the network, and it carries
/// nothing but a user agent — no identifier, no project names, nothing about the
/// machine. It can be turned off, and turning it off stops it entirely rather
/// than merely hiding the result.
@MainActor
@Observable
final class UpdateController {
    enum State: Equatable {
        case idle
        case checking
        case available(Release)
        /// Fraction complete, or nil while the server has not said how large the
        /// download is.
        case downloading(Release, Double?)
        case installing(Release)
        case upToDate
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheckedAt: Date?

    private let session: URLSession
    private let running: SemanticVersion
    private var work: Task<Void, Never>?

    init(session: URLSession = .shared, running: String = RelayVersion.current) {
        self.session = session
        self.running = SemanticVersion(running) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }

    /// The release waiting to be installed, if any.
    var pending: Release? {
        switch state {
        case let .available(release), let .downloading(release, _), let .installing(release): release
        case .idle, .checking, .upToDate, .failed: nil
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        case .idle, .available, .upToDate, .failed: false
        }
    }

    // MARK: - Checking

    /// Called on launch and on a slow timer. Does nothing if a check is already
    /// running, if one happened recently, or if an update is already waiting —
    /// re-asking cannot improve any of those.
    func checkPeriodically(now: Date = Date()) {
        guard case .idle = state else { return }
        guard UpdateDecision.shouldCheckNow(lastCheckedAt: lastCheckedAt, now: now) else { return }
        check()
    }

    func check() {
        // A development build sits beside the released one and is replaced by
        // rebuilding it, not by downloading the thing it is meant to become.
        guard RelayFlavour.current.allowsUpdates else { return }
        guard !isBusy else { return }
        work?.cancel()
        state = .checking

        work = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: ReleaseFeed.endpoint)
                request.setValue("Relay/\(RelayVersion.current)", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

                let (data, response) = try await self.session.data(for: request)
                guard !Task.isCancelled else { return }
                self.lastCheckedAt = Date()

                // A refusal is not an answer. Letting a 404 fall through to the
                // parser turns "Relay cannot see the releases" into "you are up
                // to date", which is the more comforting of the two and the
                // wrong one — a private repository reads exactly like a repo
                // with nothing published.
                if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                    self.state = .failed(UpdateDecision.message(forStatus: http.statusCode))
                    return
                }

                guard let release = ReleaseFeed.latest(from: data),
                      UpdateDecision.isWorthOffering(release, running: self.running)
                else {
                    self.state = .upToDate
                    return
                }
                self.state = .available(release)
            } catch {
                guard !Task.isCancelled else { return }
                self.lastCheckedAt = Date()
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Installing

    /// Downloads the waiting release and hands over to it.
    ///
    /// Relay quits at the end, on purpose: the replacement cannot happen while
    /// the old bundle is running, and the script that does it starts the new
    /// one. Sessions are unaffected — they belong to the daemon, which is the
    /// whole reason that separation exists.
    func install() {
        guard case let .available(release) = state else { return }
        work?.cancel()
        state = .downloading(release, nil)

        work = Task { [weak self] in
            guard let self else { return }
            do {
                let staged = try await UpdateInstaller.stage(release, session: self.session) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(release, fraction)
                    }
                }
                guard !Task.isCancelled else { return }

                self.state = .installing(release)
                try UpdateInstaller.install(staged, replacing: Bundle.main.bundleURL)
                NSApp.terminate(nil)
            } catch let failure as UpdateInstaller.Failure {
                self.state = .failed(failure.message)
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func dismiss() {
        work?.cancel()
        state = .idle
    }

    func openReleasePage() {
        guard let release = pending else { return }
        NSWorkspace.shared.open(release.pageURL)
    }
}
