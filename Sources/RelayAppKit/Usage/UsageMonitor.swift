import Foundation
import Observation

/// Keeps the status bar's figures current.
///
/// Both agents cache their own limits on disk, so this reads files rather than
/// asking anyone: no credentials, no requests, and no chance of disagreeing with
/// what the CLI itself would tell you. It also means the numbers are as fresh as
/// the last time that CLI ran, which is why each carries the moment it was
/// fetched.
@MainActor
@Observable
final class UsageMonitor {
    /// Often enough to follow a session that is burning through a window, rare
    /// enough to be free: the figures only move when an agent is running.
    static let refreshInterval: TimeInterval = 60

    private(set) var agents: [AgentUsage] = []
    private(set) var isRefreshing = false

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        agents = []
    }

    func refresh() async {
        isRefreshing = true
        // Reading a 150 KB file and the tail of a log is not main-thread work,
        // however quick it is.
        let found = await Task.detached(priority: .utility) { () -> [AgentUsage] in
            [ClaudeUsageReader.read(), CodexUsageReader.read()].compactMap { $0 }
        }.value
        agents = found
        isRefreshing = false
    }
}
