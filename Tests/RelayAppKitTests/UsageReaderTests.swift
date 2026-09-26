import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Countdown formatting")
struct UsageFormattingTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func countdown(_ seconds: TimeInterval, in locale: String = "en_US") -> String? {
        UsageFormatting.countdown(to: now.addingTimeInterval(seconds), from: now, locale: Locale(identifier: locale))
    }

    @Test("The two largest units that still say something")
    func picksTwoUnits() {
        #expect(countdown(2 * 3600 + 12 * 60) == "2h 12m")
        #expect(countdown(30 * 3600) == "1d 6h")
        #expect(countdown(59 * 60) == "59m")
    }

    @Test("A unit worth nothing is left out")
    func omitsEmptyUnits() {
        #expect(countdown(2 * 3600) == "2h")
        #expect(countdown(48 * 3600) == "2d")
    }

    @Test("A window about to roll over still reads as time, not as nothing")
    func neverShowsZero() {
        // "0m" looks like a bug; a few seconds left is a minute as far as a
        // status bar is concerned.
        #expect(countdown(20) == "1m")
    }

    @Test("The units are the interface's, not English letters in a Russian window")
    func speaksTheLocale() throws {
        // Matched by its words rather than character for character: which
        // space goes between a number and its unit is the system's to decide.
        let russian = try #require(countdown(2 * 3600 + 12 * 60, in: "ru"))
        #expect(russian.contains("ч") && russian.contains("мин"))
        #expect(!russian.contains("h") && !russian.contains("m"))
    }

    @Test("A window that has already rolled over has no countdown")
    func pastIsNil() {
        #expect(countdown(0) == nil)
        #expect(countdown(-3600) == nil)
    }
}

@Suite("Claude usage")
struct ClaudeUsageReaderTests {
    /// A moment inside every window the fixture describes. The cache is read
    /// against the clock now, so a fixture read at the wrong time reads as a
    /// file whose windows have all rolled over.
    private let now = Date(timeIntervalSince1970: 1_789_469_600)

    private let payload = """
    {
      "someOtherKey": 1,
      "cachedUsageUtilization": {
        "fetchedAtMs": 1789469477815,
        "utilization": {
          "five_hour": {"utilization": 51, "resets_at": "2026-09-15T11:10:00.767106+00:00"},
          "seven_day": {"utilization": 35, "resets_at": "2026-09-16T20:00:00.767127+00:00"},
          "limits": [
            {"kind": "session", "group": "session", "percent": 51,
             "resets_at": "2026-09-15T11:10:00.767106+00:00", "scope": null},
            {"kind": "weekly_all", "group": "weekly", "percent": 35,
             "resets_at": "2026-09-16T20:00:00.767127+00:00", "scope": null},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 0,
             "resets_at": "2026-09-16T20:00:00+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}}}
          ]
        }
      }
    }
    """

    @Test("Every window the CLI knows about is read")
    func readsAllWindows() throws {
        let usage = try #require(ClaudeUsageReader.parse(Data(payload.utf8), now: now))
        #expect(usage.kind == .claude)
        #expect(usage.windows.map(\.label) == ["5h", "wk", "Fable"])
        #expect(usage.windows.map(\.percent) == [51, 35, 0])
    }

    @Test("A limit scoped to one model is named after it")
    func namesScopedLimits() throws {
        // Two weekly bars are otherwise indistinguishable, and the one that is
        // capped per model is the one worth telling apart.
        let usage = try #require(ClaudeUsageReader.parse(Data(payload.utf8), now: now))
        #expect(usage.windows.last?.label == "Fable")
    }

    @Test("Reset times survive the fractional seconds the file carries")
    func parsesTimestamps() throws {
        let usage = try #require(ClaudeUsageReader.parse(Data(payload.utf8), now: now))
        let reset = try #require(usage.windows.first?.resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_789_470_600) < 1)
    }

    @Test("When the figure was fetched is carried through")
    func readsFetchTime() throws {
        // Relay reads a cache. An hour-old number is worth showing and not worth
        // presenting as live.
        let usage = try #require(ClaudeUsageReader.parse(Data(payload.utf8), now: now))
        #expect(usage.fetchedAt == Date(timeIntervalSince1970: 1_789_469_477.815))
    }

    @Test("The flat buckets are used when the detailed list is absent")
    func fallsBackToBuckets() throws {
        // Older shape, and the one left if an update drops `limits`: better a
        // working bar than an empty one.
        let withoutLimits = payload.replacingOccurrences(
            of: #""limits": ["#,
            with: #""unusedLimits": ["#
        )
        let usage = try #require(ClaudeUsageReader.parse(Data(withoutLimits.utf8), now: now))
        #expect(usage.windows.map(\.label) == ["5h", "wk"])
        #expect(usage.windows.map(\.percent) == [51, 35])
    }

    @Test("A window that has already rolled over is not offered as the current one")
    func dropsRolledOverWindows() throws {
        // The CLI rewrites this cache only when it asks Anthropic itself, which
        // is rarely: a five-hour figure whose window reset two days ago was
        // being drawn as a third of the window running now.
        let afterFiveHour = Date(timeIntervalSince1970: 1_789_470_601)
        let usage = try #require(ClaudeUsageReader.parse(Data(payload.utf8), now: afterFiveHour))
        #expect(usage.windows.map(\.label) == ["wk", "Fable"])
    }

    @Test("A cache in which nothing is still running yields nothing")
    func dropsAnEntirelyStaleCache() {
        let nextWeek = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(ClaudeUsageReader.parse(Data(payload.utf8), now: nextWeek) == nil)
    }

    @Test("A file with nothing cached in it yields nothing")
    func toleratesAbsence() {
        #expect(ClaudeUsageReader.parse(Data("{}".utf8)) == nil)
        #expect(ClaudeUsageReader.parse(Data("not json".utf8)) == nil)
        #expect(ClaudeUsageReader.parse(Data(#"{"cachedUsageUtilization": {}}"#.utf8)) == nil)
    }
}

@Suite("Codex usage")
struct CodexUsageReaderTests {
    /// Before either window in the fixture rolls over.
    private let now = Date(timeIntervalSince1970: 1_789_400_000)

    private let line = """
    {"timestamp":"2026-09-14T12:00:00.000Z","type":"event","payload":{"type":"token_count",\
    "rate_limits":{"limit_id":"codex","limit_name":null,\
    "primary":{"used_percent":5.0,"window_minutes":300,"resets_at":1789484226},\
    "secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1790071026},\
    "credits":{"has_credits":false,"unlimited":false,"balance":"0"}}}}
    """

    @Test("Both windows are read out of a rollout log")
    func readsBothWindows() throws {
        let usage = try #require(CodexUsageReader.parse(line, now: now))
        #expect(usage.kind == .codex)
        #expect(usage.windows.map(\.label) == ["5h", "wk"])
        #expect(usage.windows.map(\.percent) == [5, 1])
        #expect(usage.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_789_484_226))
    }

    @Test("The newest record wins, not the first")
    func usesTheLastRecord() throws {
        // A log holds one of these per update; the one at the bottom is what the
        // CLI itself would show.
        let older = line.replacingOccurrences(of: "\"used_percent\":5.0", with: "\"used_percent\":2.0")
        let usage = try #require(CodexUsageReader.parse("\(older)\n\(line)\n", now: now))
        #expect(usage.windows.first?.percent == 5)
    }

    @Test("A window is labelled by how long it is")
    func labelsWindows() {
        #expect(CodexUsageReader.span(forWindowMinutes: 300) == .rolling(minutes: 300))
        #expect(CodexUsageReader.span(forWindowMinutes: 10_080) == .weekly)
        #expect(CodexUsageReader.span(forWindowMinutes: 2_880) == .rolling(minutes: 2_880))
    }

    @Test("A transcript with no limits in it yields nothing")
    func toleratesAbsence() {
        #expect(CodexUsageReader.parse("", now: now) == nil)
        #expect(CodexUsageReader.parse("{\"type\":\"message\"}\n", now: now) == nil)
    }

    @Test("A truncated record is skipped rather than half-read")
    func skipsUnparseableRecords() throws {
        // The tail of a log can begin mid-line; a record cut in half is not an
        // answer, and the complete one above it is.
        let broken = "\"rate_limits\":{\"primary\":{\"used_per"
        let usage = try #require(CodexUsageReader.parse("\(line)\n\(broken)", now: now))
        #expect(usage.windows.first?.percent == 5)
    }

    @Test("A window that has rolled over reads as empty, not as what it held")
    func emptiesRolledOverWindows() throws {
        // Codex writes a record for every answer it is given, so a window whose
        // reset has passed with no record after it was not spent in at all.
        let afterFiveHour = Date(timeIntervalSince1970: 1_789_484_227)
        let usage = try #require(CodexUsageReader.parse(line, now: afterFiveHour))
        #expect(usage.windows.map(\.percent) == [0, 1])
        #expect(usage.windows.first?.resetsAt == nil)
    }

    @Test("A record is dated by the line it is written on")
    func datesRecordsByTheirLine() throws {
        let usage = try #require(CodexUsageReader.parse(line, now: now))
        #expect(usage.fetchedAt == Date(timeIntervalSince1970: 1_789_387_200))
    }

    @Test("The newest record wins even when an older log was written last")
    func prefersTheNewestRecordOverTheNewestFile() throws {
        // Resuming a conversation appends to the log it started in, so the file
        // touched most recently is routinely an old one carrying months-old
        // limits — which is what the bar was showing.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stale = line
            .replacingOccurrences(of: "2026-09-14T12:00:00.000Z", with: "2026-08-14T12:00:00.000Z")
            .replacingOccurrences(of: "\"used_percent\":1.0", with: "\"used_percent\":9.0")
        try write(stale, named: "resumed.jsonl", in: directory, modified: now)
        try write(line, named: "current.jsonl", in: directory, modified: now.addingTimeInterval(-3600))

        let usage = try #require(CodexUsageReader.read(from: directory, now: now))
        #expect(usage.windows.map(\.percent) == [5, 1])
    }

    @Test("A session with no record in it yet does not blank the bar")
    func ignoresLogsWithoutRecords() throws {
        // The newest file is often a session opened a moment ago, which has
        // heard nothing from the provider and so knows nothing about limits.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try write("{\"type\":\"session_meta\"}\n", named: "fresh.jsonl", in: directory, modified: now)
        try write(line, named: "older.jsonl", in: directory, modified: now.addingTimeInterval(-60))

        let usage = try #require(CodexUsageReader.read(from: directory, now: now))
        #expect(usage.windows.map(\.percent) == [5, 1])
    }

    private func write(_ text: String, named name: String, in directory: URL, modified: Date) throws {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}

@Suite("Window naming")
@MainActor
struct UsageWindowNamingTests {
    private func window(_ span: UsageWindow.Span) -> UsageWindow {
        UsageWindow(span: span, fraction: 0, resetsAt: nil)
    }

    @Test("The bar gets a label short enough to fit")
    func shortLabels() {
        #expect(window(.rolling(minutes: 300)).label == "5h")
        #expect(window(.rolling(minutes: 2_880)).label == "2d")
        #expect(window(.weekly).label == "wk")
        #expect(window(.model("Fable")).label == "Fable")
    }

    @Test("The tooltip gets the window spelled out")
    func spelledOutNames() {
        // `wk` is fine in a strip at the bottom of the screen and means nothing
        // on its own, which is the whole reason these are two properties.
        #expect(window(.rolling(minutes: 300)).name == "Every 5 hours")
        #expect(window(.rolling(minutes: 2_880)).name == "Every 2 days")
        #expect(window(.weekly).name == "Weekly")
    }

    @Test("A model-scoped limit is called by the model's name, both times")
    func modelKeepsItsName() {
        #expect(window(.model("Fable")).name == "Fable")
    }
}

@Suite("Compact usage")
struct HeadlineWindowTests {
    private func usage(_ fractions: [(UsageWindow.Span, Double)]) -> AgentUsage {
        AgentUsage(
            kind: .claude,
            windows: fractions.map { UsageWindow(span: $0.0, fraction: $0.1, resetsAt: nil) },
            fetchedAt: nil
        )
    }

    @Test("One line shows the limit that will bite first")
    func picksTheFullestWindow() {
        // Not the shortest window: a five-hour bar at 5% matters less than a
        // weekly one at 90%, and a one-line summary has room for the one that
        // actually stops you.
        let agent = usage([(.rolling(minutes: 300), 0.05), (.weekly, 0.9)])
        #expect(agent.headlineWindow?.span == .weekly)
    }

    @Test("A weekly bar fuller than the five-hour one but far from its end leaves the line to the five-hour one")
    func sessionWindowByDefault() {
        // The week at 35% and the afternoon at 20% is most of the week, and
        // the line showed `wk` through all of it.
        let agent = usage([(.rolling(minutes: 300), 0.2), (.weekly, 0.35), (.model("Fable"), 0.5)])
        #expect(agent.headlineWindow?.span == .rolling(minutes: 300))
    }

    @Test("A nearly spent window the five-hour one is fuller than does not take its place")
    func sessionFullerStillWins() {
        let agent = usage([(.weekly, 0.85), (.rolling(minutes: 300), 0.95)])
        #expect(agent.headlineWindow?.span == .rolling(minutes: 300))
    }

    @Test("A compact line counts down to its own window's reset, a detailed one to the nearest")
    func countdownFollowsTheShownWindow() {
        let soon = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 9_000)
        let agent = AgentUsage(
            kind: .claude,
            windows: [
                UsageWindow(span: .rolling(minutes: 300), fraction: 0.1, resetsAt: soon),
                UsageWindow(span: .weekly, fraction: 0.9, resetsAt: later),
            ],
            fetchedAt: nil
        )
        #expect(agent.countdownTarget(for: .compact) == later)
        #expect(agent.countdownTarget(for: .detailed) == soon)
    }

    @Test("With nothing consumed it still names a window")
    func neverEmptyWhenThereAreWindows() {
        let agent = usage([(.rolling(minutes: 300), 0), (.weekly, 0)])
        #expect(agent.headlineWindow != nil)
    }

    @Test("An agent with no windows has nothing to show")
    func emptyAgent() {
        #expect(usage([]).headlineWindow == nil)
    }

    @Test("The countdown follows the window that rolls over soonest")
    func nextResetIsTheNearest() {
        // Which is not always the fullest one, so they are two questions.
        let soon = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 9_000)
        let agent = AgentUsage(
            kind: .codex,
            windows: [
                UsageWindow(span: .weekly, fraction: 0.9, resetsAt: later),
                UsageWindow(span: .rolling(minutes: 300), fraction: 0.1, resetsAt: soon),
            ],
            fetchedAt: nil
        )
        #expect(agent.nextReset == soon)
        #expect(agent.headlineWindow?.span == .weekly)
    }
}

@Suite("Usage preferences")
@MainActor
struct UsageBarDetailTests {
    @Test("The bar starts brief")
    func defaultsToCompact() {
        // A strip along the bottom of every window earns its place by being
        // glanceable; the full picture is one click away.
        #expect(WorkspaceState().usageBarDetail == .compact)
    }

    @Test("A value written when the setting meant something else is not honoured")
    func ignoresThePreviousKey() throws {
        // It used to govern the popover as well, so a stored preference from
        // then is an answer to a different question.
        let stored = Data(#"{"usageDetail": "detailed"}"#.utf8)
        let state = try JSONDecoder().decode(WorkspaceState.self, from: stored)
        #expect(state.usageBarDetail == .compact)
    }

    @Test("A deliberate choice survives a round trip")
    func roundTripsAChoice() throws {
        var state = WorkspaceState()
        state.usageBarDetail = .detailed
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: data).usageBarDetail == .detailed)
    }
}

@Suite("Claude usage endpoint")
struct ClaudeUsageEndpointTests {
    private let now = Date(timeIntervalSince1970: 1_789_469_600)

    private let answer = """
    {
      "five_hour": {"utilization": 44, "resets_at": "2026-09-15T11:10:00.767106+00:00"},
      "seven_day": {"utilization": 18, "resets_at": "2026-09-16T20:00:00.767127+00:00"},
      "limits": [
        {"kind": "session", "group": "session", "percent": 44,
         "resets_at": "2026-09-15T11:10:00.767106+00:00", "scope": null},
        {"kind": "weekly_all", "group": "weekly", "percent": 18,
         "resets_at": "2026-09-16T20:00:00.767127+00:00", "scope": null}
      ]
    }
    """

    @Test("The endpoint's answer is read by the same code as the cache")
    func readsTheAnswer() throws {
        // The CLI stores this body verbatim, which is what lets one reader
        // serve both and keeps the two from drifting apart.
        let usage = try #require(ClaudeUsageEndpoint.parse(Data(answer.utf8), fetchedAt: now))
        #expect(usage.kind == .claude)
        #expect(usage.windows.map(\.label) == ["5h", "wk"])
        #expect(usage.windows.map(\.percent) == [44, 18])
        #expect(usage.fetchedAt == now)
    }

    @Test("An answer with no limits in it is not an answer")
    func toleratesNonsense() {
        #expect(ClaudeUsageEndpoint.parse(Data("{}".utf8), fetchedAt: now) == nil)
        #expect(ClaudeUsageEndpoint.parse(Data("not json".utf8), fetchedAt: now) == nil)
    }

    @Test("The token and the scheme it belongs to are both sent")
    func buildsTheRequest() {
        let request = ClaudeUsageEndpoint.request(token: "secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    private func response(_ status: Int, retryAfter: String? = nil) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: ClaudeUsageEndpoint.url,
            statusCode: status,
            httpVersion: nil,
            headerFields: retryAfter.map { ["Retry-After": $0] }
        ))
    }

    @Test("An answer is not a refusal")
    func acceptsSuccess() throws {
        #expect(ClaudeUsageEndpoint.retryDate(for: try response(200), from: now) == nil)
    }

    @Test("A refusal is waited out for as long as it asks")
    func honoursRetryAfter() throws {
        let seconds = try response(429, retryAfter: "90")
        #expect(ClaudeUsageEndpoint.retryDate(for: seconds, from: now) == now.addingTimeInterval(90))

        let date = try response(429, retryAfter: "Tue, 15 Sep 2026 11:10:00 GMT")
        #expect(ClaudeUsageEndpoint.retryDate(for: date, from: now)
            == Date(timeIntervalSince1970: 1_789_470_600))
    }

    @Test("A refusal that names no time still stops the asking")
    func backsOffWithoutAHeader() throws {
        // Polling through a 429 keeps the refusal alive, so the absence of a
        // header cannot mean "carry on".
        let refused = try response(429)
        #expect(ClaudeUsageEndpoint.retryDate(for: refused, from: now)
            == now.addingTimeInterval(ClaudeUsageEndpoint.defaultBackoff))
    }

    @Test("A rejected token waits longer, and not forever")
    func retriesARejectedToken() throws {
        // It is Claude Code's token and Claude Code renews it; giving up for
        // the session would leave the bar on the cache until a restart.
        let rejected = try response(401)
        #expect(ClaudeUsageEndpoint.retryDate(for: rejected, from: now)
            == now.addingTimeInterval(ClaudeUsageEndpoint.rejectedTokenBackoff))
    }
}

@Suite("Claude credentials")
struct ClaudeCredentialsTests {
    @Test("The token is the one the CLI stored")
    func readsTheToken() {
        let stored = """
        {"claudeAiOauth": {"accessToken": "sk-ant-oat-x", "refreshToken": "r", "expiresAt": 1}}
        """
        #expect(ClaudeCredentials.token(fromJSON: stored) == "sk-ant-oat-x")
    }

    @Test("An expired-looking token is still offered to the endpoint")
    func ignoresExpiry() {
        // The endpoint is the authority on whether a token works; a clock that
        // disagrees would refuse a request that would have succeeded.
        let expired = """
        {"claudeAiOauth": {"accessToken": "sk-ant-oat-x", "expiresAt": 0}}
        """
        #expect(ClaudeCredentials.token(fromJSON: expired) == "sk-ant-oat-x")
    }

    @Test("Anything else is no token at all")
    func toleratesAbsence() {
        #expect(ClaudeCredentials.token(fromJSON: "{}") == nil)
        #expect(ClaudeCredentials.token(fromJSON: "not json") == nil)
        #expect(ClaudeCredentials.token(fromJSON: #"{"claudeAiOauth": {"accessToken": ""}}"#) == nil)
    }

    @Test("A keychain that will not answer is not the same as an empty one")
    func tellsRefusalFromAbsence() {
        // The difference decides whether Relay asks again on the next tick:
        // asking is what raises the system's permission sheet, and raising it
        // every five minutes would be worse than showing the cache.
        #expect(ClaudeCredentials.reading(status: 0, output: "{\"claudeAiOauth\": {}}\n")
            == .token("{\"claudeAiOauth\": {}}"))
        #expect(ClaudeCredentials.reading(status: 44, output: "") == .missing)
        #expect(ClaudeCredentials.reading(status: 128, output: "") == .refused)
        #expect(ClaudeCredentials.reading(status: 0, output: "  \n") == .missing)
    }

    @Test("A login name the CLI will not store under is not looked up")
    func namesTheKeychainAccount() {
        // Claude Code 2.1 keeps SSO logins under a fixed name, so looking the
        // item up under the login name would find nothing.
        #expect(ClaudeCredentials.account(for: "nikita") == "nikita")
        #expect(ClaudeCredentials.account(for: "first.last-2") == "first.last-2")
        #expect(ClaudeCredentials.account(for: "first@example.com") == "claude-code-user")
        #expect(ClaudeCredentials.account(for: "") == "claude-code-user")
    }
}

@Suite("Asking for live usage")
@MainActor
struct UsageMonitorPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_789_469_600)

    private func usage(_ kind: SessionKind, percent: Int, at fetched: Date?) -> AgentUsage {
        AgentUsage(
            kind: kind,
            windows: [UsageWindow(span: .rolling(minutes: 300), fraction: Double(percent) / 100, resetsAt: nil)],
            fetchedAt: fetched
        )
    }

    @Test("The endpoint is asked the first time and then left alone")
    func pacesTheAsking() {
        #expect(UsageMonitor.shouldAsk(at: now, askedAt: nil, silentUntil: nil, force: false))

        let justAsked = now.addingTimeInterval(-30)
        #expect(!UsageMonitor.shouldAsk(at: now, askedAt: justAsked, silentUntil: nil, force: false))

        let longAgo = now.addingTimeInterval(-UsageMonitor.endpointInterval)
        #expect(UsageMonitor.shouldAsk(at: now, askedAt: longAgo, silentUntil: nil, force: false))
    }

    @Test("Asking by hand skips the wait between polls")
    func honoursTheButton() {
        let justAsked = now.addingTimeInterval(-30)
        #expect(UsageMonitor.shouldAsk(at: now, askedAt: justAsked, silentUntil: nil, force: true))
    }

    @Test("A refusal is honoured even when the refresh was asked for")
    func honoursARefusal() {
        // Polling through a 429 keeps it alive, and the button cannot make the
        // endpoint answer any sooner.
        let waiting = now.addingTimeInterval(60)
        #expect(!UsageMonitor.shouldAsk(at: now, askedAt: nil, silentUntil: waiting, force: true))

        let expired = now.addingTimeInterval(-1)
        #expect(UsageMonitor.shouldAsk(at: now, askedAt: nil, silentUntil: expired, force: false))
    }

    @Test("The live figure replaces the cached one")
    func liveWins() {
        let cached = usage(.claude, percent: 31, at: now.addingTimeInterval(-86_400 * 3))
        let codex = usage(.codex, percent: 7, at: now)
        let live = usage(.claude, percent: 44, at: now)

        let merged = UsageMonitor.merge(live, into: [cached, codex])
        #expect(merged.map(\.kind) == [.claude, .codex])
        #expect(merged.first?.windows.first?.percent == 44)
    }

    @Test("A live figure with no cache behind it is still shown")
    func liveStandsAlone() {
        // The CLI writes that cache only when it asks the endpoint itself, so a
        // fresh install has none at all.
        let merged = UsageMonitor.merge(usage(.claude, percent: 44, at: now), into: [usage(.codex, percent: 7, at: now)])
        #expect(merged.map(\.kind) == [.claude, .codex])
    }

    @Test("With nothing live, what is on disk is what there is")
    func fallsBackToDisk() {
        let onDisk = [usage(.claude, percent: 31, at: now), usage(.codex, percent: 7, at: now)]
        #expect(UsageMonitor.merge(nil, into: onDisk).map(\.kind) == [.claude, .codex])
    }
}
