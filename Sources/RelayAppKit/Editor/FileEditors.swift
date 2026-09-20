import Foundation
import Observation

/// Every file open in the window, and when each one is written out.
///
/// Saving is not a command a person should have to remember here. ⌘S is
/// honoured, but so is leaving the pane and closing it — an agent reading the
/// file in the terminal beside it must not be reading a version that only
/// exists in the editor.
@MainActor
@Observable
final class FileEditors {
    private(set) var files: [String: OpenFile] = [:]

    /// Called with a file that was just written out.
    ///
    /// A hook rather than a call, because the three places a file is saved
    /// from are here and what wants to know — the symbol index — is not.
    @ObservationIgnored var onSave: ((OpenFile) -> Void)?

    /// Which file the keyboard is in. Changing it writes out the one being
    /// left, which is the whole of the "save on losing focus" rule.
    var focused: String? {
        didSet {
            guard oldValue != focused else { return }
            if let focused { recent = focused }
            guard let leaving = oldValue else { return }
            write(files[leaving])
        }
    }

    /// The file the tree points at.
    ///
    /// Kept when focus moves to a terminal — which sets `focused` to nil —
    /// because what reads this is the file tree, and blanking what the tree
    /// points at because the caret went to a terminal states something untrue
    /// about which file is being worked on.
    private(set) var recent: String?

    var openPaths: Set<String> { Set(files.keys) }

    subscript(path: String) -> OpenFile? { files[path] }

    /// The file open at the moment, if there is one.
    var openPath: String? { files.keys.first }

    /// Opens the file, or hands back the buffer already open on it.
    ///
    /// One at a time: opening another writes this one out and forgets it. The
    /// pane is somewhere to read and correct the file an agent is working on,
    /// beside the agent — not a desk to stack documents on, which is what the
    /// editor in the other window is for.
    @discardableResult
    func open(_ path: String) -> OpenFile? {
        if let existing = files[path] { return existing }
        guard let file = OpenFile(path: path) else { return nil }
        for other in files.keys where other != path { close(other) }
        files[path] = file
        return file
    }

    /// Writes the file out and forgets it.
    func close(_ path: String) {
        write(files[path])
        files[path] = nil
        if recent == path { recent = nil }
        if focused == path { focused = nil }
    }

    func save(_ path: String) {
        write(files[path])
    }

    /// For quitting, where every unsaved buffer is about to stop existing.
    func saveAll() {
        for file in files.values { write(file) }
    }

    /// The one place a file is written. The `isModified` check is what keeps
    /// the hook honest: `save()` is a no-op on an untouched buffer, and
    /// announcing a save that did not happen would re-read the file on every
    /// click into a pane.
    private func write(_ file: OpenFile?) {
        guard let file, file.isModified else { return }
        file.save()
        onSave?(file)
    }

    var modifiedPaths: [String] {
        files.values.filter(\.isModified).map(\.path).sorted()
    }
}
