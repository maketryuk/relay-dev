import AppKit
import CChromium
import RelayProtocol
import RelayUI

/// Chromium, started the first time a page is opened and stopped as the app
/// quits.
///
/// Not at launch: it costs a GPU process, a network service and a good
/// hundred megabytes before a page is drawn, and most sessions never open one.
/// Once started it stays, because CEF cannot be started twice in one process.
@MainActor
final class ChromiumEngine {
    static let shared = ChromiumEngine()

    enum State: Equatable {
        case stopped
        case running
        /// This build cannot run it, with the reason in a sentence.
        case unavailable(String)
    }

    private(set) var state: State = .stopped
    private var pages: [ObjectIdentifier: ChromiumPage] = [:]
    private let pump = Pump()

    /// Starts Chromium unless it already runs. Answers whether it does.
    func start() -> Bool {
        switch state {
        case .running: return true
        case .unavailable: return false
        case .stopped: break
        }

        guard let layout = BundleLayout.current else {
            state = .unavailable(relayLocalized("This build of Relay was made without Chromium."))
            return false
        }
        switch relay_chromium_load(layout.library.path) {
        case RELAY_CHROMIUM_LOADED:
            break
        case RELAY_CHROMIUM_INCOMPATIBLE:
            state = .unavailable(relayLocalized("The Chromium in this build is not the version Relay was made for."))
            return false
        default:
            state = .unavailable(relayLocalized("Chromium could not be loaded."))
            return false
        }

        try? RelayPaths.ensureDirectories()
        try? FileManager.default.createDirectory(at: RelayPaths.browserDirectory, withIntermediateDirectories: true)

        let values: [String] = [
            layout.bundle.path,
            layout.framework.path,
            layout.helper.path,
            RelayPaths.browserDirectory.path,
            RelayPaths.chromiumLogURL.path,
            Self.locale,
        ]
        let strings: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        defer { strings.forEach { free($0) } }

        var settings = relay_chromium_settings()
        settings.main_bundle_path = UnsafePointer(strings[0])
        settings.framework_path = UnsafePointer(strings[1])
        settings.helper_path = UnsafePointer(strings[2])
        settings.cache_path = UnsafePointer(strings[3])
        settings.log_path = UnsafePointer(strings[4])
        settings.locale = UnsafePointer(strings[5])
        // Theme.Palette.base, so a page that has not painted yet is the colour
        // of the pane rather than a white flash.
        settings.background_color = 0xFF08_090A
        guard relay_chromium_initialize(&settings, scheduleChromiumWork) == 1 else {
            state = .unavailable(relayLocalized("Chromium could not be started."))
            return false
        }
        state = .running
        pump.schedule(after: 0)
        return true
    }

    func opened(_ page: ChromiumPage) {
        pages[ObjectIdentifier(page)] = page
        pump.isBusy = true
    }

    func closed(_ page: ChromiumPage) {
        pages.removeValue(forKey: ObjectIdentifier(page))
        pump.isBusy = !pages.isEmpty
    }

    /// Closes every page and stops Chromium, as the app quits.
    ///
    /// CEF has to be told before the process ends, and only once every page
    /// has closed: stopping it under a live page is something it does not
    /// survive. Closing a page takes a few turns of the run loop, which are
    /// given here, up to a limit — past it Chromium is left running and the
    /// process ends without it, which costs nothing worse than an unclean
    /// profile.
    func shutdown() {
        guard state == .running else { return }
        for page in pages.values {
            page.close()
        }
        let deadline = Date().addingTimeInterval(2)
        while !pages.isEmpty, Date() < deadline {
            relay_chromium_do_work()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard pages.isEmpty else { return }
        pump.stop()
        relay_chromium_shutdown()
        state = .unavailable(relayLocalized("Chromium has stopped."))
    }

    func scheduleWork(after delay: Int64) {
        guard state == .running else { return }
        pump.schedule(after: delay)
    }

    /// The language Chromium speaks in its own error pages and menus: the one
    /// Relay is shown in, since those are the two it ships.
    private static var locale: String {
        switch Localization.shared.language {
        case .russian: "ru"
        case .english: "en-US"
        case .system: Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en-US"
        }
    }
}

/// How Chromium asks for a turn. It may ask from any thread; the turn is
/// always taken on the main one.
private let scheduleChromiumWork: @convention(c) (Int64) -> Void = { delay in
    DispatchQueue.main.async {
        MainActor.assumeIsolated { ChromiumEngine.shared.scheduleWork(after: delay) }
    }
}

/// Where the parts of Chromium live inside the app bundle.
///
/// Only a bundle built by `Scripts/build-app.sh` has them. `swift run` and
/// the tests run a bare executable, and the browser pane says so rather than
/// failing somewhere less legible.
struct BundleLayout {
    let bundle: URL
    let framework: URL
    let library: URL
    let helper: URL

    static var current: BundleLayout? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let framework = frameworks.appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
        let layout = BundleLayout(
            bundle: bundle,
            framework: framework,
            library: framework.appendingPathComponent("Chromium Embedded Framework"),
            helper: frameworks.appendingPathComponent("Relay Helper.app/Contents/MacOS/Relay Helper")
        )
        let manager = FileManager.default
        guard manager.fileExists(atPath: layout.library.path), manager.fileExists(atPath: layout.helper.path) else {
            return nil
        }
        return layout
    }
}

/// Chromium's turns on the main thread, interleaved with AppKit's.
///
/// The scheme CEF's own sample uses for an application that keeps its run
/// loop (`main_message_loop_external_pump`): Chromium names a delay and gets
/// a turn after it, on a timer in the common modes so that work goes on while
/// a window is resized or a menu is open. A turn that finds itself inside
/// another turn asks for one more instead of running. And not every piece of
/// Chromium's work asks, so a turn comes anyway — thirty a second while a page
/// is open, once a second when none is.
@MainActor
private final class Pump {
    var isBusy = false

    private var timer: Timer?
    private var isWorking = false
    private var workedReentrantly = false
    private var isStopped = false

    private var fallbackDelay: Int64 { isBusy ? 1000 / 30 : 1000 }

    func schedule(after delay: Int64) {
        guard !isStopped else { return }
        timer?.invalidate()
        timer = nil
        guard delay > 0 else {
            work()
            return
        }
        let timer = Timer(timeInterval: Double(min(delay, fallbackDelay)) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = nil
                self?.work()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        isStopped = true
        timer?.invalidate()
        timer = nil
    }

    private func work() {
        guard !isWorking else {
            workedReentrantly = true
            return
        }
        isWorking = true
        workedReentrantly = false
        relay_chromium_do_work()
        isWorking = false

        if workedReentrantly {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.schedule(after: 0) }
            }
        } else if timer == nil {
            schedule(after: fallbackDelay)
        }
    }
}
