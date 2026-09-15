import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Countdown formatting")
struct UsageFormattingTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func countdown(_ seconds: TimeInterval) -> String? {
        UsageFormatting.countdown(to: now.addingTimeInterval(seconds), from: now)
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

    @Test("A window that has already rolled over has no countdown")
    func pastIsNil() {
        #expect(countdown(0) == nil)
        #expect(countdown(-3600) == nil)
    }
}

@Suite("Claude usage")
struct ClaudeUsageReaderTests {
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
        let usage = try #require(ClaudeUsageReader.parse(Data(payload.utf8)))
        #expect(usage.kind == .claude)
        #expect(usage.windows.map(\.label) == ["5h", "wk", "Fable"])
        #expect(usage.windows.map(\.percent) == [51, 35, 0])
    }

    @Test("A limit scoped to one model is named after it")
    func namesScopedLimits() throws {
        // Two weekly bars are otherwise indistinguishable, and the one that is
        // capped per model is the one worth telling apart.
        let usage = try #require(ClaudeUsageReader.parse(Data(payload.utf8)))
        #expect(usage.windows.last?.label == "Fable")
    }

    @Test("Reset times survive the fractional seconds the file carries")
    func parsesTimestamps() throws {
        let usage = try #require(ClaudeUsageReader.parse(Data(payload.utf8)))
        let reset = try #require(usage.windows.first?.resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_789_470_600) < 1)
    }

    @Test("When the figure was fetched is carried through")
    func readsFetchTime() throws {
        // Relay reads a cache. An hour-old number is worth showing and not worth
        // presenting as live.
        let usage = try #require(ClaudeUsageReader.parse(Data(payload.utf8)))
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
        let usage = try #require(ClaudeUsageReader.parse(Data(withoutLimits.utf8)))
        #expect(usage.windows.map(\.label) == ["5h", "wk"])
        #expect(usage.windows.map(\.percent) == [51, 35])
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
    private let line = """
    {"type":"event","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,\
    "primary":{"used_percent":5.0,"window_minutes":300,"resets_at":1789484226},\
    "secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1790071026},\
    "credits":{"has_credits":false,"unlimited":false,"balance":"0"}}}}
    """

    @Test("Both windows are read out of a rollout log")
    func readsBothWindows() throws {
        let usage = try #require(CodexUsageReader.parse(line))
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
        let usage = try #require(CodexUsageReader.parse("\(older)\n\(line)\n"))
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
        #expect(CodexUsageReader.parse("") == nil)
        #expect(CodexUsageReader.parse("{\"type\":\"message\"}\n") == nil)
    }

    @Test("A truncated record is skipped rather than half-read")
    func skipsUnparseableRecords() throws {
        // The tail of a log can begin mid-line; a record cut in half is not an
        // answer, and the complete one above it is.
        let broken = "\"rate_limits\":{\"primary\":{\"used_per"
        let usage = try #require(CodexUsageReader.parse("\(line)\n\(broken)"))
        #expect(usage.windows.first?.percent == 5)
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
struct MostUsedWindowTests {
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
        #expect(agent.mostUsedWindow?.span == .weekly)
    }

    @Test("With nothing consumed it still names a window")
    func neverEmptyWhenThereAreWindows() {
        let agent = usage([(.rolling(minutes: 300), 0), (.weekly, 0)])
        #expect(agent.mostUsedWindow != nil)
    }

    @Test("An agent with no windows has nothing to show")
    func emptyAgent() {
        #expect(usage([]).mostUsedWindow == nil)
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
        #expect(agent.mostUsedWindow?.span == .weekly)
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
