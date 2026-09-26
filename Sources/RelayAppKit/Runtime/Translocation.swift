import AppKit
import Foundation
import RelayUI

/// Gets Relay out of App Translocation before anything else starts.
///
/// macOS runs a quarantined application that Finder never moved from a
/// read-only copy of itself under `AppTranslocation`, and takes that copy away
/// when it sees fit — a volume being unmounted elsewhere is enough. The code
/// still to be paged in goes with it, so every process running from the copy
/// dies of SIGBUS at once, and the daemon ships inside the same bundle: the one
/// process that must outlive the app ended with it, and every terminal with
/// the daemon. Leaving the copy before the daemon is looked for means a
/// translocated launch never starts one.
enum Translocation {
    static let quarantineAttribute = "com.apple.quarantine"

    /// Passed to the copy started in place of this one. A launch that carries
    /// it and is still translocated does not try the same thing again, so a
    /// macOS that translocates for some other reason is asked about rather
    /// than reopened forever.
    static let reopenedArgument = "--reopened-out-of-translocation"

    /// Where the bundle really is, when macOS is running it from a copy.
    ///
    /// Security answers this with two functions it exports without a header.
    /// They have kept these signatures since macOS 10.12 and are what Sparkle
    /// and LetsMove ask; looked up rather than linked, so a macOS without them
    /// runs Relay as before instead of refusing to load it.
    static func originalLocation(of bundle: URL) -> URL? {
        typealias IsTranslocated = @convention(c) (
            CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> DarwinBoolean
        typealias OriginalPath = @convention(c) (
            CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFURL>?

        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isTranslocatedSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalPathSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
        else { return nil }
        let isTranslocated = unsafeBitCast(isTranslocatedSymbol, to: IsTranslocated.self)
        let originalPath = unsafeBitCast(originalPathSymbol, to: OriginalPath.self)

        var translocated = false
        guard isTranslocated(bundle as CFURL, &translocated, nil).boolValue, translocated,
              let original = originalPath(bundle as CFURL, nil)?.takeRetainedValue()
        else { return nil }
        return original as URL
    }

    /// Starts Relay from `original` instead of the copy, and ends this process.
    ///
    /// Without its quarantine flag the original is run where it is, which is
    /// what moving it in Finder would have achieved. A disk image cannot be
    /// changed, and ejecting one would do what the translocation did, so an
    /// original that keeps its flag is offered a copy in Applications instead.
    @MainActor
    static func leave(for original: URL) -> Never {
        if !CommandLine.arguments.contains(reopenedArgument), clearQuarantine(of: original) {
            reopen(original)
        }
        offerMove(of: original)
    }

    /// Removes the flag from the bundle and everything in it, as
    /// `Scripts/install.sh` does for a development build, and says whether the
    /// bundle itself is free of it — which is all translocation looks at.
    @discardableResult
    static func clearQuarantine(of bundle: URL) -> Bool {
        var paths = [bundle.path]
        if let contents = FileManager.default.enumerator(atPath: bundle.path) {
            for case let relative as String in contents {
                paths.append(bundle.appendingPathComponent(relative).path)
            }
        }
        for path in paths {
            removexattr(path, quarantineAttribute, XATTR_NOFOLLOW)
        }
        return getxattr(bundle.path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) < 0 && errno == ENOATTR
    }

    enum InstallFailure: Error, Equatable {
        /// Something that is not Relay already has the name.
        case occupied(String)
    }

    /// Copies the bundle to `destination` without its quarantine flag,
    /// replacing an earlier copy of the same application.
    static func install(_ bundle: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        let replacing = fileManager.fileExists(atPath: destination.path)
        if replacing, bundleIdentifier(of: destination) != bundleIdentifier(of: bundle) {
            throw InstallFailure.occupied(destination.path)
        }

        // Copied beside the destination first, so a copy that fails halfway
        // leaves the earlier one where it was.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: bundle, to: staging)
            clearQuarantine(of: staging)
            if replacing {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// `/Applications` for someone who can write to it, `~/Applications`
    /// otherwise.
    static func applicationsDirectory(fileManager: FileManager = .default) -> URL {
        let shared = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fileManager.isWritableFile(atPath: shared.path) { return shared }
        let personal = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        try? fileManager.createDirectory(at: personal, withIntermediateDirectories: true)
        return personal
    }

    // MARK: - Pieces

    /// Read from the file rather than through `Bundle`, which caches by path
    /// and would describe whatever was there first.
    private static func bundleIdentifier(of bundle: URL) -> String? {
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        return NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String
    }

    /// Returns only when the new copy could not be started.
    ///
    /// Waits for this process to be gone first: while it runs, `open` may
    /// bring it forward instead of starting the bundle again.
    private static func reopen(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open "$2" --args "$3""#,
            "sh", String(getpid()), bundle.path, reopenedArgument,
        ]
        guard (try? process.run()) != nil else { return }
        exit(0)
    }

    @MainActor
    private static func offerMove(of original: URL) -> Never {
        let destination = applicationsDirectory().appendingPathComponent(original.lastPathComponent)
        guard destination.standardizedFileURL != original.standardizedFileURL else {
            refuse(detail: nil)
        }

        var explanation = temporaryCopyExplanation
        if FileManager.default.fileExists(atPath: destination.path) {
            explanation += " " + relayLocalized("The copy already in Applications will be replaced.")
        }
        let alert = NSAlert()
        alert.messageText = relayLocalized("Move Relay to Applications?")
        alert.informativeText = explanation
        alert.addButton(withTitle: relayLocalized("Move to Applications"))
        alert.addButton(withTitle: relayLocalized("Quit"))
        guard present(alert) == .alertFirstButtonReturn else { exit(0) }

        do {
            try install(original, at: destination)
        } catch InstallFailure.occupied(let path) {
            refuse(detail: String(format: relayLocalized("%@ is another application."), path))
        } catch {
            refuse(detail: error.localizedDescription)
        }
        reopen(destination)
        refuse(detail: nil)
    }

    @MainActor
    private static func refuse(detail: String?) -> Never {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = relayLocalized("Relay cannot run from here")
        alert.informativeText = [
            temporaryCopyExplanation,
            relayLocalized("Move Relay into Applications in Finder and open it from there."),
            detail,
        ].compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: relayLocalized("Quit"))
        _ = present(alert)
        exit(0)
    }

    /// Nothing has read the workspace yet, so this is in the system's language
    /// rather than the one chosen in Settings.
    @MainActor
    private static var temporaryCopyExplanation: String {
        relayLocalized("macOS is running Relay from a temporary copy, as it does with an application opened straight from a download or a disk image. It can take that copy away at any moment, and every session would end with it.")
    }

    /// Nothing has started the application yet: the alert is all there is.
    @MainActor
    private static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
