import Foundation
import Observation

/// Keeps the status bar's figures current.
///
/// Claude is asked directly, with the token its own CLI holds: the figure a
/// terminal shows comes from response headers that are never written down, so a
/// client that only reads files shows whatever was true the last time the CLI
/// happened to write one — days ago, as often as not. Codex writes every figure
/// it is given into its rollout log, so for it the file is the live answer and
/// no request is made.
///
/// The endpoint is polled sparingly. It is the same one the CLI uses and it
/// answers a status bar's appetite with a 429, so it is asked at most every few
/// minutes, never while a refusal is still in force, and the file cache stands
/// in whenever it cannot be reached at all.
@MainActor
@Observable
final class UsageMonitor {
    /// Often enough to follow a session that is burning through a window, rare
    /// enough to be free: the figures only move when an agent is running.
    static let refreshInterval: TimeInterval = 60

    /// How often the endpoint itself is asked, as against how often the files
    /// beside it are read.
    static let endpointInterval: TimeInterval = 5 * 60

    private(set) var agents: [AgentUsage] = []
    private(set) var isRefreshing = false

    private var task: Task<Void, Never>?

    /// The last answer the endpoint gave, kept between polls so the bar does not
    /// drop back to the cache in the minutes between them.
    private var live: AgentUsage?
    private var askedAt: Date?
    private var silentUntil: Date?

    /// Set when the keychain refuses. Nothing automatic asks again after that,
    /// because asking is what raises the system's permission sheet, and a sheet
    /// every five minutes is worse than a bar on the cache. The refresh button
    /// clears it: pressing it is asking for the sheet.
    private var keychainRefused = false

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

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
        live = nil
        askedAt = nil
    }

    func refresh(force: Bool = false) async {
        isRefreshing = true
        let now = Date()

        if force { keychainRefused = false }

        if !keychainRefused,
           Self.shouldAsk(at: now, askedAt: askedAt, silentUntil: silentUntil, force: force) {
            askedAt = now
            live = await ask(at: now) ?? live
        }

        // Reading a 150 KB file and the tail of a log is not main-thread work,
        // however quick it is.
        let onDisk = await Task.detached(priority: .utility) { () -> [AgentUsage] in
            [ClaudeUsageReader.read(now: now), CodexUsageReader.read(now: now)].compactMap { $0 }
        }.value

        agents = Self.merge(live, into: onDisk)
        isRefreshing = false
    }

    /// The live figure replaces the cached one it contradicts, and stands on its
    /// own when the CLI has never written a cache at all.
    static func merge(_ live: AgentUsage?, into found: [AgentUsage]) -> [AgentUsage] {
        guard let live else { return found }
        guard found.contains(where: { $0.kind == live.kind }) else { return [live] + found }
        return found.map { $0.kind == live.kind ? live : $0 }
    }

    static func shouldAsk(at now: Date, askedAt: Date?, silentUntil: Date?, force: Bool) -> Bool {
        // A refusal is honoured even when the refresh was asked for by hand:
        // the button is for a figure that is late, and a request the endpoint
        // has already turned down does not make it any earlier.
        if let silentUntil, now < silentUntil { return false }
        guard let askedAt else { return true }
        return force || now.timeIntervalSince(askedAt) >= endpointInterval
    }

    private func ask(at now: Date) async -> AgentUsage? {
        let credentials = await Task.detached(priority: .utility, operation: {
            ClaudeCredentials.read()
        }).value

        guard case let .token(token) = credentials else {
            keychainRefused = credentials == .refused
            return nil
        }

        do {
            let (data, response) = try await session.data(for: ClaudeUsageEndpoint.request(token: token))
            if let http = response as? HTTPURLResponse,
               let retry = ClaudeUsageEndpoint.retryDate(for: http, from: now) {
                silentUntil = retry
                return nil
            }
            silentUntil = nil
            return ClaudeUsageEndpoint.parse(data, fetchedAt: now)
        } catch {
            // A network that is down is not a refusal: nothing is owed a wait,
            // and the next tick is a minute away.
            return nil
        }
    }
}
