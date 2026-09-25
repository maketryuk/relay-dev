import Foundation
import RelayProtocol

/// Lists the Codex conversations belonging to a project.
///
/// Codex keeps no generated title, so the first thing the user actually said is
/// the name — which is what its own picker shows too.
enum CodexConversationReader {
    /// How far back to look. Rollouts are one directory per day, and a project's
    /// conversations are not spread across hundreds of them.
    static let limit = 60

    /// Which directory each recent log was started in, and the conversations
    /// of the ones listed last time, as they were read.
    static let rememberedDirectories = TranscriptReadings<String>()
    static let remembered = TranscriptReadings<Conversation>()

    static func list(
        forDirectory path: String,
        sessions: URL = CodexContextReader.sessionsDirectory,
        directories: TranscriptReadings<String> = rememberedDirectories,
        readings: TranscriptReadings<Conversation> = remembered
    ) -> [Conversation] {
        guard let walker = FileManager.default.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let logs = Array((walker.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { (TranscriptTail.modificationDate(of: $0) ?? .distantPast)
                > (TranscriptTail.modificationDate(of: $1) ?? .distantPast) }
            .prefix(limit))

        directories.keep(only: logs)
        let own = logs.filter { log in
            directories.value(of: log) { CodexContextReader.sessionMeta(of: $0)?.directory } == path
        }
        readings.keep(only: own)
        return own.compactMap { log in
            readings.value(of: log) { conversation(from: $0, updatedAt: TranscriptTail.modificationDate(of: $0) ?? Date()) }
        }
    }

    static func conversation(from log: URL, updatedAt: Date) -> Conversation? {
        guard let identifier = sessionIdentifier(of: log) else { return nil }
        let objects = TranscriptTail.objects(in: log, bytes: TranscriptTail.defaultBytes)
        guard let opening = firstUserMessage(in: objects) else { return nil }

        return Conversation(
            id: identifier,
            kind: .codex,
            title: ConversationSorting.summary(of: opening),
            lastPrompt: nil,
            branch: nil,
            updatedAt: updatedAt
        )
    }

    /// The session's own id, which is what `codex resume` takes.
    static func sessionIdentifier(of log: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: CodexContextReader.headBytes) else { return nil }

        let text = String(decoding: data, as: UTF8.self)
        guard let newline = text.firstIndex(of: "\n"),
              let object = try? JSONSerialization.jsonObject(
                  with: Data(text[text.startIndex ..< newline].utf8)
              ) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        return (payload["session_id"] ?? payload["id"]) as? String
    }

    /// The first thing the person said.
    ///
    /// Skips the `developer` turns the desktop app injects — those describe the
    /// environment, not the task, and naming a conversation after one would name
    /// every conversation the same.
    static func firstUserMessage(in objects: [[String: Any]]) -> String? {
        for object in objects {
            guard let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "user",
                  let content = payload["content"] as? [[String: Any]]
            else { continue }

            let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
