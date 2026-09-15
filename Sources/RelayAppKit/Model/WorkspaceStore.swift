import Foundation
import RelayProtocol

/// Atomic JSON persistence for workspace configuration.
///
/// A plain file is deliberate: the persisted set is small, entirely
/// user-owned configuration, and the daemon is the source of truth for
/// everything that actually changes at runtime. It also keeps the format
/// inspectable and trivially migratable to SQLite/SwiftData later.
final class WorkspaceStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.maketryuk.relay.store", qos: .utility)
    private var saveWorkItem: DispatchWorkItem?

    init(url: URL = RelayPaths.workspaceFileURL) {
        self.url = url
    }

    func load() -> WorkspaceState {
        guard let data = try? Data(contentsOf: url) else { return WorkspaceState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(WorkspaceState.self, from: data) else {
            // A corrupt file must never block startup; keep a copy for forensics.
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            return WorkspaceState()
        }
        return state
    }

    /// Coalesces bursts of UI changes into a single write.
    func scheduleSave(_ state: WorkspaceState) {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow(state)
        }
        saveWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func saveNow(_ state: WorkspaceState) {
        do {
            try RelayPaths.ensureDirectories()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            let temporary = url.appendingPathExtension("tmp")
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            NSLog("Relay: failed to persist workspace: \(error)")
        }
    }
}
