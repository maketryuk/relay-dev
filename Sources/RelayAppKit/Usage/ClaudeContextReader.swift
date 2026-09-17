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
        conversationID: String? = nil,
        declaredWindow: Int? = nil,
        projects: URL = projectsDirectory
    ) -> SessionContext? {
        guard let transcript = transcript(
            forDirectory: workingDirectory,
            startedAt: startedAt,
            conversationID: conversationID,
            projects: projects
        ) else { return nil }
        return parse(
            TranscriptTail.objects(in: transcript),
            measuredAt: TranscriptTail.modificationDate(of: transcript),
            declaredWindow: declaredWindow
        )
    }

    /// The session's own transcript.
    ///
    /// Several conversations can share a directory, so the one Relay started is
    /// the one that began when it did. Deliberately no fallback: with nothing
    /// that started alongside this session, the honest answer is that Relay does
    /// not know — the alternative was picking the most recently written
    /// transcript, which for a freshly opened pane meant showing a long-running
    /// conversation's 93% as if it were its own.
    ///
    /// A resumed conversation is named outright by the command that resumed it,
    /// and Claude Code names the file after the conversation — so there the
    /// question of which transcript this is does not arise.
    static func transcript(
        forDirectory path: String,
        startedAt: Date,
        conversationID: String? = nil,
        projects: URL = projectsDirectory
    ) -> URL? {
        let manager = FileManager.default
        let folders = directoryNames(for: path)
            .map(projects.appendingPathComponent)
            .filter { manager.fileExists(atPath: $0.path) }

        if let conversationID {
            let named = folders
                .map { $0.appendingPathComponent("\(conversationID).jsonl") }
                .first { manager.fileExists(atPath: $0.path) }
            if let named { return named }
        }

        let keys: [URLResourceKey] = [.creationDateKey]
        let candidates = folders.flatMap { folder in
            (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        }
        .filter { $0.pathExtension == "jsonl" }
        .map { url in
            (url: url, createdAt: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }

        return choose(from: candidates, startedAt: startedAt)
    }

    /// The transcript that began alongside the session.
    ///
    /// `grace` covers the gap between Relay spawning the CLI and the CLI opening
    /// its transcript, which is a moment rather than an instant.
    static func choose(
        from candidates: [(url: URL, createdAt: Date)],
        startedAt: Date,
        grace: TimeInterval = 60
    ) -> URL? {
        candidates
            .filter { $0.createdAt >= startedAt.addingTimeInterval(-grace) }
            .min { abs($0.createdAt.timeIntervalSince(startedAt)) < abs($1.createdAt.timeIntervalSince(startedAt)) }?
            .url
    }

    /// The last assistant turn is the only one that matters: it records what was
    /// in the window when it was sent, which is what is in the window now.
    static func parse(
        _ objects: [[String: Any]],
        measuredAt: Date?,
        declaredWindow: Int? = nil
    ) -> SessionContext? {
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
            window: ContextWindow.resolve(observed: tokens, declared: declaredWindow),
            isWindowDeclared: declaredWindow != nil,
            model: last.message["model"] as? String,
            slices: slices,
            measuredAt: measuredAt
        )
    }
}
