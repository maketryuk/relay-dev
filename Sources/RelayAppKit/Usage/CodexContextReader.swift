import Foundation
import RelayProtocol

/// How much of a Codex session's context window is in use.
///
/// Codex is the easier of the two: its rollout log records the window size
/// outright, so nothing has to be inferred.
enum CodexContextReader {
    static var sessionsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    /// How many recent logs to look through before giving up. A session started
    /// minutes ago is among the newest; reading further is reading someone
    /// else's afternoon.
    static let searchDepth = 25

    static func read(
        workingDirectory: String,
        startedAt: Date,
        sessions: URL = sessionsDirectory
    ) -> SessionContext? {
        guard let log = rollout(
            forDirectory: workingDirectory,
            startedAt: startedAt,
            sessions: sessions
        ) else { return nil }
        return parse(TranscriptTail.objects(in: log), measuredAt: TranscriptTail.modificationDate(of: log))
    }

    /// The rollout belonging to this session.
    ///
    /// Codex records the working directory and its own start time in the log's
    /// first line, so the match is on what the session *is* rather than on when
    /// a file happened to be touched.
    static func rollout(
        forDirectory path: String,
        startedAt: Date,
        sessions: URL = sessionsDirectory
    ) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let logs = (walker.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { (TranscriptTail.modificationDate(of: $0) ?? .distantPast)
                > (TranscriptTail.modificationDate(of: $1) ?? .distantPast) }
            .prefix(searchDepth)

        // Codex records its own start time, so the match is on the session
        // rather than on which file was touched last. No fallback: attributing
        // another conversation's window to this pane is worse than admitting
        // Relay cannot tell.
        let threshold = startedAt.addingTimeInterval(-60)
        return logs.first { log in
            guard let meta = sessionMeta(of: log), meta.directory == path else { return false }
            guard let began = meta.startedAt else { return false }
            return began >= threshold
        }
    }

    /// Enough of the head to be sure of holding the whole first line.
    ///
    /// `session_meta` carries the environment Codex was started with and runs to
    /// tens of kilobytes; a smaller read returns half a record, which parses as
    /// nothing and silently matches no session at all.
    static let headBytes = 256 * 1024

    static func sessionMeta(of url: URL) -> (directory: String, startedAt: Date?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The first line only: `session_meta` is written before anything else.
        guard let data = try? handle.read(upToCount: headBytes) else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        // Only a line that was terminated is a whole line.
        guard let newline = text.firstIndex(of: "\n") else { return nil }
        let first = text[text.startIndex ..< newline]
        guard let object = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let directory = payload["cwd"] as? String
        else { return nil }

        let started = (payload["timestamp"] as? String).flatMap(ClaudeUsageReader.date(fromISO8601:))
        return (directory, started)
    }

    /// The newest `info` record, which carries both what has been sent and how
    /// much room there was for it.
    static func parse(_ objects: [[String: Any]], measuredAt: Date?) -> SessionContext? {
        let infos = objects.compactMap { object -> [String: Any]? in
            guard let payload = object["payload"] as? [String: Any] else { return object["info"] as? [String: Any] }
            return payload["info"] as? [String: Any] ?? object["info"] as? [String: Any]
        }
        guard let info = infos.last(where: { $0["last_token_usage"] != nil || $0["total_token_usage"] != nil })
        else { return nil }

        let usage = (info["last_token_usage"] as? [String: Any])
            ?? (info["total_token_usage"] as? [String: Any]) ?? [:]

        let cached = usage["cached_input_tokens"] as? Int ?? 0
        let input = usage["input_tokens"] as? Int ?? 0
        let newlyCached = usage["cache_write_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let reasoning = usage["reasoning_output_tokens"] as? Int ?? 0

        // Codex counts the cached part inside `input_tokens`, so the fresh share
        // is what remains rather than another addend.
        let fresh = max(input - cached, 0)
        let tokens = input + newlyCached
        guard tokens > 0 else { return nil }

        let slices = [
            ContextSlice(kind: .cached, tokens: cached),
            ContextSlice(kind: .newlyCached, tokens: newlyCached),
            ContextSlice(kind: .fresh, tokens: fresh),
            ContextSlice(kind: .output, tokens: max(output - reasoning, 0)),
            ContextSlice(kind: .reasoning, tokens: reasoning),
        ].filter { $0.tokens > 0 }

        let declared = info["model_context_window"] as? Int
        return SessionContext(
            tokens: tokens,
            window: ContextWindow.resolve(observed: tokens, declared: declared),
            isWindowDeclared: declared != nil,
            model: info["model"] as? String,
            slices: slices,
            measuredAt: measuredAt
        )
    }
}
