import Foundation
import RelayProtocol

/// Lists the Claude conversations belonging to a project.
enum ClaudeConversationReader {
    /// How many transcripts to open. Sorted newest first, so the cut falls on
    /// conversations nobody is looking for.
    static let limit = 30

    static func list(
        forDirectory path: String,
        projects: URL = ClaudeContextReader.projectsDirectory
    ) -> [Conversation] {
        let manager = FileManager.default
        let folders = ClaudeContextReader.directoryNames(for: path)
            .map(projects.appendingPathComponent)
            .filter { manager.fileExists(atPath: $0.path) }

        let transcripts = folders
            .flatMap { (try? manager.contentsOfDirectory(
                at: $0,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? [] }
            .filter { $0.pathExtension == "jsonl" }
            .sorted { (TranscriptTail.modificationDate(of: $0) ?? .distantPast)
                > (TranscriptTail.modificationDate(of: $1) ?? .distantPast) }
            .prefix(limit)

        return transcripts.compactMap(conversation(from:))
    }

    static func conversation(from transcript: URL) -> Conversation? {
        let updatedAt = TranscriptTail.modificationDate(of: transcript) ?? Date()
        let objects = TranscriptTail.objects(in: transcript)
        guard !objects.isEmpty else { return nil }
        return conversation(
            id: transcript.deletingPathExtension().lastPathComponent,
            objects: objects,
            updatedAt: updatedAt
        )
    }

    /// Claude Code writes a generated title and the last prompt repeatedly as a
    /// conversation goes on, so the tail carries both — which is what makes
    /// listing a megabyte-long transcript cheap.
    static func conversation(id: String, objects: [[String: Any]], updatedAt: Date) -> Conversation? {
        let title = objects.last { $0["type"] as? String == "ai-title" }?["aiTitle"] as? String
        let prompt = objects.last { $0["type"] as? String == "last-prompt" }?["lastPrompt"] as? String
        let branch = objects.last { $0["gitBranch"] is String }?["gitBranch"] as? String

        // A transcript with neither a title nor a prompt has nothing to show for
        // itself, and a row that says only "Claude" is a row nobody can choose.
        guard title != nil || prompt != nil else { return nil }

        return Conversation(
            id: id,
            kind: .claude,
            title: title ?? ConversationSorting.summary(of: prompt ?? ""),
            lastPrompt: prompt.map { ConversationSorting.summary(of: $0) },
            branch: (branch?.isEmpty == false && branch != "HEAD") ? branch : nil,
            updatedAt: updatedAt
        )
    }
}
