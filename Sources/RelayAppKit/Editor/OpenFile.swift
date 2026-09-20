import Foundation
import Observation

/// One file open in a pane.
///
/// The text lives here rather than in the view because a pane is redrawn,
/// moved and split without the file being reopened, and because two things
/// outside the view need it: the save that happens when focus leaves, and the
/// one that happens when the pane closes.
@MainActor
@Observable
final class OpenFile: @preconcurrency Identifiable {
    /// Absolute, and the identity of the file: two panes on the same path are
    /// two views of one buffer rather than two buffers that will overwrite
    /// each other.
    let path: String
    let language: SourceLanguage?
    /// True for a file that belongs to a dependency rather than to the
    /// project. Opened to be read: an edit to it is undone by the next
    /// install, without a word, and whoever made it has no way to find that
    /// out afterwards.
    let isVendored: Bool

    var text: String {
        didSet {
            isModified = text != savedText
            // Every position in the file has just moved; what was marked is
            // no longer where it was.
            occurrences = []
        }
    }

    /// What is on disk, as far as this buffer knows.
    private(set) var savedText: String
    private(set) var isModified = false
    /// Why the last read or write failed, if it did. Shown in the pane: a file
    /// that silently did not save is the worst outcome available.
    private(set) var failure: String?

    /// Where the caret is, so a command from the menu means the same thing as
    /// a ⌘-click does. Nothing on screen reads it, which is the point: a
    /// property a view observed would redraw the pane on every arrow key.
    var caret = 0

    /// Somewhere in the file to go and show.
    ///
    /// Carried as a request rather than as a position because the same jump
    /// can be asked for twice — clicking a name that is already the one being
    /// shown — and a pane that compares positions would take the second one
    /// for "nothing changed".
    struct Reveal: Equatable {
        let id: UUID
        let range: NSRange
    }

    private(set) var reveal: Reveal?

    /// Everywhere the name the caret was sent to is written, within the scope
    /// that declares it. Marked in the text until the caret leaves them.
    var occurrences: [NSRange] = []

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    init?(path: String) {
        let contents: String
        do {
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return nil
        }
        self.path = path
        text = contents
        savedText = contents
        language = SourceLanguage.detect(path: path, contents: contents)
        isVendored = DependencyScan.isDependency(path)
    }

    /// Writes the buffer out, and does nothing at all when it has not changed.
    ///
    /// Silent on success and loud on failure, because saving is something the
    /// editor does on its own — on ⌘S, on losing focus, on closing — and three
    /// notifications for one edit is noise.
    func save() {
        guard isModified else { return }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            savedText = text
            isModified = false
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Asks the pane showing this file to put the caret here and scroll to it.
    func jump(to range: NSRange) {
        reveal = Reveal(id: UUID(), range: range)
        caret = range.location
    }

    /// Goes to a local name's declaration and marks everywhere it is used.
    func show(_ binding: LocalBinding) {
        jump(to: binding.definition)
        occurrences = binding.ranges
    }

    /// Takes what is on disk now, discarding the buffer.
    ///
    /// For the file an agent has just rewritten under us: the pane is showing
    /// a version that no longer exists anywhere else.
    func reload() {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        text = contents
        savedText = contents
        isModified = false
    }
}
