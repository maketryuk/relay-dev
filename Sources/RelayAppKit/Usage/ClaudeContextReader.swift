import Foundation
import RelayProtocol

/// How much of a Claude session's context window is in use.
///
/// Read from the transcript Claude Code writes as it goes. Nothing is asked of
/// Anthropic, and the figure cannot disagree with the CLI's own, because it is
/// the CLI's own: the last assistant turn records exactly what it sent.
enum ClaudeContextReader {
    static var projectsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// Claude Code names a project's folder after its path with the separators
    /// flattened. Both spellings are tried because a path containing a dot is
    /// flattened too, and guessing wrong means finding nothing at all.
    static func directoryNames(for path: String) -> [String] {
        let slashes = path.replacingOccurrences(of: "/", with: "-")
        let dots = slashes.replacingOccurrences(of: ".", with: "-")
        return slashes == dots ? [slashes] : [slashes, dots]
    }

    static func read(
        workingDirectory: String,
        startedAt: Date,
        projects: URL = projectsDirectory
    ) -> SessionContext? {
        guard let transcript = transcript(
            forDirectory: workingDirectory,
            startedAt: startedAt,
            projects: projects
        ) else { return nil }
        return parse(TranscriptTail.objects(in: transcript), measuredAt: TranscriptTail.modificationDate(of: transcript))
    }

    /// The session's own transcript.
    ///
    /// Several conversations can share a directory, so the one Relay started is
    /// identified by having begun after it did. Falling back to the most
    /// recently touched keeps the panel useful when the match is not certain —
    /// the alternative is showing nothing for a session plainly in front of the
    /// user.
    static func transcript(
        forDirectory path: String,
        startedAt: Date,
        projects: URL = projectsDirectory
    ) -> URL? {
        let manager = FileManager.default
        let folders = directoryNames(for: path)
            .map(projects.appendingPathComponent)
            .filter { manager.fileExists(atPath: $0.path) }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        let candidates = folders.flatMap { folder in
            (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        }.filter { $0.pathExtension == "jsonl" }

        // A minute of slack: the transcript is created once the CLI is up, which
        // is a moment after Relay spawned it.
        let threshold = startedAt.addingTimeInterval(-60)
        let started = candidates.filter { url in
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return created >= threshold
        }

        return newestByModification(in: started.isEmpty ? candidates : started)
    }

    private static func newestByModification(in urls: [URL]) -> URL? {
        urls.max { left, right in
            (TranscriptTail.modificationDate(of: left) ?? .distantPast)
                < (TranscriptTail.modificationDate(of: right) ?? .distantPast)
        }
    }

    /// The last assistant turn is the only one that matters: it records what was
    /// in the window when it was sent, which is what is in the window now.
    static func parse(_ objects: [[String: Any]], measuredAt: Date?) -> SessionContext? {
        let turns = objects.compactMap { object -> (message: [String: Any], usage: [String: Any])? in
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { return nil }
            return (message, usage)
        }
        guard let last = turns.last else { return nil }

        let cached = last.usage["cache_read_input_tokens"] as? Int ?? 0
        let newlyCached = last.usage["cache_creation_input_tokens"] as? Int ?? 0
        let fresh = last.usage["input_tokens"] as? Int ?? 0
        let output = last.usage["output_tokens"] as? Int ?? 0

        let tokens = cached + newlyCached + fresh
        guard tokens > 0 else { return nil }

        let slices = [
            ContextSlice(kind: .cached, tokens: cached),
            ContextSlice(kind: .newlyCached, tokens: newlyCached),
            ContextSlice(kind: .fresh, tokens: fresh),
            ContextSlice(kind: .output, tokens: output),
        ].filter { $0.tokens > 0 }

        return SessionContext(
            tokens: tokens,
            window: ContextWindow.resolve(observed: tokens, declared: nil),
            isWindowDeclared: false,
            model: last.message["model"] as? String,
            slices: slices,
            measuredAt: measuredAt
        )
    }
}
