import AppKit
import Foundation
import RelayTracker
import SwiftUI
import Testing

@testable import RelayAppKit
@testable import RelayUI

@Suite("An issue handed to an agent")
struct IssueTranscriptTests {
    private let project = TrackerProject(id: "0-3", key: "WEB", name: "Website")

    private func issue(description: String = "Steps:\n1. Log in") -> TrackerIssue {
        TrackerIssue(
            id: "2-35",
            key: "WEB-342",
            summary: "Login redirects to a blank page",
            description: description,
            project: project,
            fields: [
                TrackerField(
                    name: "State",
                    kind: .option,
                    values: [FieldOption(id: "s", name: "In Progress", title: "В работе")],
                    wireType: "StateIssueCustomField"
                ),
                TrackerField(name: "Assignee", kind: .user, wireType: "SingleUserIssueCustomField"),
                TrackerField(name: "Estimation", kind: .period, text: "2h", wireType: "PeriodIssueCustomField"),
                TrackerField(name: "Notes", kind: .text, text: "Line one\nLine two", wireType: "TextIssueCustomField"),
            ],
            tags: [TrackerTag(name: "frontend")]
        )
    }

    @Test("It opens with the key, the summary and where to read more")
    func header() {
        let text = IssueTranscript.compose(issue(), comments: [], link: URL(string: "https://yt.example/issue/WEB-342"))
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "Issue: WEB-342 — Login redirects to a blank page")
        #expect(lines[1] == "Link: https://yt.example/issue/WEB-342")
    }

    @Test("Fields with something to say are passed on as the tracker shows them")
    func fields() {
        let text = IssueTranscript.compose(issue(), comments: [], link: nil)
        #expect(text.contains("State: В работе"))
        #expect(text.contains("Estimation: 2h"))
        #expect(text.contains("Tags: frontend"))
        // Empty, and a page of text, are left out.
        #expect(!text.contains("Assignee"))
        #expect(!text.contains("Notes"))
    }

    @Test("The description goes through untouched, and none means no section")
    func description() {
        #expect(IssueTranscript.compose(issue(), comments: [], link: nil).contains("Description:\nSteps:\n1. Log in"))
        #expect(!IssueTranscript.compose(issue(description: "  \n"), comments: [], link: nil).contains("Description:"))
    }

    @Test("Only the newest comments go along, and it says how many were left out")
    func comments() {
        let comments = (1 ... 25).map { number in
            TrackerComment(
                id: "\(number)",
                text: "Comment \(number)",
                author: TrackerUser(id: "u", login: "jane", name: "Jane Doe"),
                // Noon, so the day is the same in whichever time zone runs this.
                created: Date(timeIntervalSince1970: TimeInterval(number) * 86_400 + 43_200)
            )
        }
        let text = IssueTranscript.compose(issue(), comments: comments, link: nil)
        #expect(text.contains("(5 earlier comments left out)"))
        #expect(!text.contains("Comment 5\n"))
        #expect(text.contains("Jane Doe, 1970-01-07:\nComment 6"))
        #expect(text.hasSuffix("Comment 25"))
    }

    @Test("A branch is the key and as much of the summary as reads as a branch")
    func branchNames() {
        #expect(IssueTranscript.branchName(for: "WEB-342", summary: "Login redirects to a blank page!")
            == "WEB-342-login-redirects-to-a-blank-page")
        #expect(IssueTranscript.branchName(for: "WEB-343", summary: "Исправить вход") == "WEB-343")
        #expect(IssueTranscript.branchName(for: "APP-1", summary: "Fix: the API's /v2 route") == "APP-1-fix-the-api-s-v2-route")
        let long = IssueTranscript.branchName(for: "WEB-1", summary: String(repeating: "word ", count: 30))
        #expect(long.count <= 60)
    }
}

@Suite("The issue timer")
struct TrackerTimerTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("It counts while running and stands still while paused")
    func pauses() {
        var timer = TrackerTimer(key: "WEB-1", summary: "S", project: nil, startedAt: start)
        #expect(timer.elapsed(at: start.addingTimeInterval(90)) == 90)
        timer.pause(at: start.addingTimeInterval(90))
        #expect(!timer.isRunning)
        #expect(timer.elapsed(at: start.addingTimeInterval(1_000)) == 90)
        timer.resume(at: start.addingTimeInterval(1_000))
        #expect(timer.elapsed(at: start.addingTimeInterval(1_030)) == 120)
    }

    @Test("Pausing twice or resuming twice changes nothing")
    func idempotent() {
        var timer = TrackerTimer(key: "WEB-1", summary: "S", project: nil, startedAt: start)
        timer.resume(at: start.addingTimeInterval(50))
        #expect(timer.elapsed(at: start.addingTimeInterval(60)) == 60)
        timer.pause(at: start.addingTimeInterval(60))
        timer.pause(at: start.addingTimeInterval(500))
        #expect(timer.elapsed(at: start.addingTimeInterval(900)) == 60)
    }

    @Test("A clock set back does not make the time negative")
    func clockSetBack() {
        let timer = TrackerTimer(key: "WEB-1", summary: "S", project: nil, startedAt: start, accumulated: 30)
        #expect(timer.elapsed(at: start.addingTimeInterval(-600)) == 30)
    }

    @Test("It survives a relaunch, running or paused")
    func persisted() throws {
        let running = TrackerTimer(
            key: "WEB-1",
            summary: "S",
            project: TrackerProject(id: "0-3", key: "WEB", name: "Website"),
            startedAt: start,
            accumulated: 12
        )
        let settings = TrackerSettings(kind: .youTrack, address: "https://yt.example", timer: running)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try decoder.decode(TrackerSettings.self, from: encoder.encode(settings))
        #expect(read == settings)
    }
}

@Suite("Tracker settings in the workspace file")
struct TrackerSettingsTests {
    private func decode(_ json: String) throws -> TrackerSettings {
        try JSONDecoder().decode(TrackerSettings.self, from: Data(json.utf8))
    }

    @Test("A workspace from before the tracker opens with it switched off")
    func olderWorkspace() throws {
        let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(#"{"projects": []}"#.utf8))
        #expect(state.tracker == TrackerSettings())
        #expect(state.tracker.kind == nil)
    }

    @Test("A tracker this build does not know is no tracker, and the rest is kept")
    func unknownTracker() throws {
        let read = try decode(#"{"kind": "jira", "address": "https://j.example", "boards": {"p1": "b1"}}"#)
        #expect(read.kind == nil)
        #expect(read.address == "https://j.example")
        #expect(read.boards == ["p1": "b1"])
    }

    @Test("Settings that cannot be read cost the connection, not the workspace")
    func unreadableSettings() throws {
        let state = try JSONDecoder().decode(
            WorkspaceState.self,
            from: Data(#"{"projects": [], "tracker": {"boards": "not a map"}}"#.utf8)
        )
        #expect(state.tracker == TrackerSettings())
    }
}

@Suite("A value in the tracker's colours")
struct TrackerChipTests {
    @Test("Fill and ink are both the tracker's, so a pale fill keeps the hue its text carries")
    func paleFill() throws {
        // YouTrack's "critical" as a live instance sends it.
        let palette = try #require(TrackerChip.palette(for: TrackerColor(background: "#FCC3E2", foreground: "#C01173")))
        #expect(palette.fill == Color(hex: 0xFCC3E2))
        #expect(palette.ink == Color(hex: 0xC01173))
    }

    @Test("The short form is read, and no colour or a broken one is drawn as a value with none")
    func unreadable() {
        #expect(TrackerChip.palette(for: TrackerColor(background: "#DB3B4B", foreground: "#fff"))?.ink == Color(hex: 0xFFFFFF))
        #expect(TrackerChip.palette(for: nil) == nil)
        #expect(TrackerChip.palette(for: TrackerColor(background: "red", foreground: "#fff")) == nil)
    }
}

@Suite("An issue copied to paste into a chat")
struct IssueReferenceTests {
    private let link = URL(string: "https://yt.example/issue/WEB-342")!

    @Test("The key and the summary on one line, and the key alone without one")
    func text() {
        #expect(IssueReference.text(key: "WEB-342", summary: "Login redirects") == "WEB-342 Login redirects")
        #expect(IssueReference.text(key: "WEB-342", summary: "") == "WEB-342")
    }

    @Test("In HTML the key is the link, and the summary cannot become markup")
    func html() {
        #expect(IssueReference.html(key: "WEB-342", summary: "Show <b> & \"quotes\"", link: link)
            == #"<a href="https://yt.example/issue/WEB-342">WEB-342</a> Show &lt;b&gt; &amp; &quot;quotes&quot;"#)
    }

    @Test("In RTF the key carries the link and the summary does not")
    func rtf() throws {
        let data = try #require(IssueReference.rtf(key: "WEB-342", summary: "Вход ведёт на пустую страницу", link: link))
        let read = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(read.string == "WEB-342 Вход ведёт на пустую страницу")
        #expect(read.attribute(.link, at: 0, effectiveRange: nil) as? URL == link)
        #expect(read.attribute(.link, at: 8, effectiveRange: nil) == nil)
    }

    @Test("All three go on the clipboard together, and only the text without a link")
    @MainActor
    func clipboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("relay.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        IssueReference.copy(key: "WEB-342", summary: "Login redirects", link: link, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "WEB-342 Login redirects")
        #expect(pasteboard.string(forType: .html)?.contains(#"href="https://yt.example/issue/WEB-342""#) == true)
        #expect(pasteboard.data(forType: .rtf) != nil)

        IssueReference.copy(key: "WEB-342", summary: "Login redirects", link: nil, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "WEB-342 Login redirects")
        #expect(pasteboard.string(forType: .html) == nil)
    }
}

@Suite("Choosing a field's value")
@MainActor
struct TrackerFieldPickerTests {
    // One script: the order of two alphabets is the Mac's language's to say.
    private let anton = FieldOption(id: "1", name: "anton", title: "Anton Kostyaev", login: "anton")
    private let jane = FieldOption(id: "2", name: "jane", title: "Jane Doe", login: "jane")
    private let me = FieldOption(id: "3", name: "nikita", title: "Nikita Payas", login: "nikita")

    private func people(several: Bool = false) -> TrackerField {
        TrackerField(
            name: several ? "Участники" : "Assignee",
            kind: .user,
            allowsSeveral: several,
            options: [jane, me, anton],
            emptyText: "Unassigned",
            wireType: several ? "MultiUserIssueCustomField" : "SingleUserIssueCustomField"
        )
    }

    private func titles(_ rows: [TrackerFieldPicker.Row]) -> [String] {
        rows.map { row in
            switch row {
            case let .none(title): "(\(title))"
            case let .option(option): option.title
            }
        }
    }

    @Test("People are listed by name with whoever is signed in first, after no one")
    func peopleOrder() {
        #expect(titles(TrackerFieldPicker.rows(for: people(), query: "", me: "nikita"))
            == ["(Unassigned)", "Nikita Payas", "Anton Kostyaev", "Jane Doe"])
    }

    @Test("A field of several values offers no \"no one\", since that is ticking none")
    func severalHaveNoEmptyRow() {
        #expect(titles(TrackerFieldPicker.rows(for: people(several: true), query: "", me: nil))
            == ["Anton Kostyaev", "Jane Doe", "Nikita Payas"])
    }

    @Test("A search finds a name typed in the wrong layout, and a login")
    func search() {
        let russian = TrackerField(
            name: "Assignee",
            kind: .user,
            options: [FieldOption(id: "1", name: "anton", title: "Антон Костяев", login: "anton"), jane],
            wireType: "SingleUserIssueCustomField"
        )
        #expect(titles(TrackerFieldPicker.rows(for: russian, query: "fynjy", me: nil)) == ["Антон Костяев"])
        #expect(titles(TrackerFieldPicker.rows(for: people(), query: "jane", me: nil)) == ["Jane Doe"])
    }

    @Test("States and priorities keep the tracker's order, which is what they mean")
    func optionOrder() {
        let priority = TrackerField(
            name: "Priority",
            kind: .option,
            options: ["1 неотложеный", "2 критичный", "3 очень важный"].map { FieldOption(id: $0, name: $0) },
            canBeEmpty: false,
            wireType: "SingleEnumIssueCustomField"
        )
        #expect(titles(TrackerFieldPicker.rows(for: priority, query: "", me: nil))
            == ["1 неотложеный", "2 критичный", "3 очень важный"])
    }
}

@Suite("Lengths of time in the window's words", .serialized)
@MainActor
struct TrackerTextTests {
    @Test("What the timer fills in is read back as the same length, in either language")
    func roundTrips() {
        let previous = Localization.shared.language
        defer { Localization.shared.language = previous }
        for language in [AppLanguage.english, .russian] {
            Localization.shared.language = language
            for minutes in [1, 45, 60, 95, 600] {
                let written = TrackerText.duration(minutes: minutes)
                #expect(WorkDuration.minutes(from: written) == minutes, "\(language): \(written)")
            }
        }
    }

    @Test("A running clock shows hours only once there are some")
    func clock() {
        #expect(TrackerText.clock(65) == "1:05")
        #expect(TrackerText.clock(3_725) == "1:02:05")
        #expect(TrackerText.clock(-5) == "0:00")
    }
}

@Suite("Pictures in an issue's text")
struct IssueMarkdownTests {
    @Test("A picture written by an attachment's name is taken out of the text")
    func picturesByName() {
        let source = """
        Добавить ссылки на внешние источники

        ![](Screenshot 2026-09-23 at 13.13.59.png){width=70%}
        And after it.
        """
        #expect(IssueMarkdown.segments(of: source) == [
            .text("Добавить ссылки на внешние источники"),
            .image(reference: "Screenshot 2026-09-23 at 13.13.59.png", width: nil),
            .text("And after it."),
        ])
    }

    @Test("A width in points is kept, and a share of a page is not")
    func widths() {
        #expect(IssueMarkdown.segments(of: "![](a.png){width=320}") == [.image(reference: "a.png", width: 320)])
        #expect(IssueMarkdown.segments(of: "![](a.png){width=320px}") == [.image(reference: "a.png", width: 320)])
        #expect(IssueMarkdown.segments(of: "![](a.png){width=70%}") == [.image(reference: "a.png", width: nil)])
        #expect(IssueMarkdown.segments(of: "![alt](https://x.example/a.png)") == [
            .image(reference: "https://x.example/a.png", width: nil),
        ])
    }

    @Test("Text with no pictures is left as it is")
    func plainText() {
        #expect(IssueMarkdown.segments(of: "Just **words**, and [a link](https://x.example)") == [
            .text("Just **words**, and [a link](https://x.example)"),
        ])
        #expect(IssueMarkdown.segments(of: "").isEmpty)
    }

    @Test("A link to an attachment by name is pointed at the attachment, and other links are left alone")
    func attachmentLinks() {
        let text = "See [the log](build log.txt) and [the site](https://x.example)."
        let linked = IssueMarkdown.linkingAttachments(in: text) { target in
            target == "build log.txt" ? "https://yt.example/api/files/1?sign=x" : nil
        }
        #expect(linked == "See [the log](https://yt.example/api/files/1?sign=x) and [the site](https://x.example).")
    }
}

@Suite("Naming someone in a reply")
struct MentionQueryTests {
    private let people = [
        TrackerUser(id: "1", login: "jane", name: "Jane Doe"),
        TrackerUser(id: "2", login: "max.k", name: "Максим Ковалёв"),
        TrackerUser(id: "3", login: "benjamin", name: "Ben Jamieson"),
    ]

    @Test("The word after an @ at the caret is what is being looked for")
    func findsTheQuery() {
        let text = "Thanks @ja"
        let query = MentionQuery.find(in: text, caret: (text as NSString).length)
        #expect(query == MentionQuery(range: NSRange(location: 7, length: 3), text: "ja"))
        #expect(MentionQuery.find(in: "@", caret: 1) == MentionQuery(range: NSRange(location: 0, length: 1), text: ""))
    }

    @Test("In the middle of a sentence as well as at its end")
    func middleOfText() {
        let text = "Ask @ma about it"
        #expect(MentionQuery.find(in: text, caret: 7)?.text == "ma")
        #expect(MentionQuery.find(in: text, caret: 12) == nil)
    }

    @Test("An address is not a mention, nor is an @ followed by a space")
    func notMentions() {
        let email = "mail jane@example.com"
        #expect(MentionQuery.find(in: email, caret: (email as NSString).length) == nil)
        #expect(MentionQuery.find(in: "@ja ", caret: 4) == nil)
        #expect(MentionQuery.find(in: "(@ja", caret: 4)?.text == "ja")
    }

    @Test("Logins that start with it come first, then names, then anything containing it")
    func ranking() {
        #expect(MentionQuery.matches(people, for: "ja").map(\.login) == ["jane", "benjamin"])
        #expect(MentionQuery.matches(people, for: "макс").map(\.login) == ["max.k"])
        #expect(MentionQuery.matches(people, for: "").count == 3)
        #expect(MentionQuery.matches(people, for: "zzz").isEmpty)
        #expect(MentionQuery.insertion(for: people[1]) == "@max.k ")
    }

    @Test("Whoever the issue knows of can be mentioned, each once")
    func peopleOnAnIssue() {
        let jane = FieldOption(id: "1", name: "jane", title: "Jane Doe", login: "jane")
        let max = FieldOption(id: "2", name: "max.k", title: "Максим Ковалёв", login: "max.k")
        let issue = TrackerIssue(
            id: "i",
            key: "WEB-1",
            summary: "S",
            project: TrackerProject(id: "p", key: "WEB", name: "Web"),
            reporter: TrackerUser(id: "3", login: "benjamin", name: "Ben Jamieson"),
            fields: [TrackerField(
                name: "Assignee",
                kind: .user,
                values: [jane],
                options: [jane, max],
                wireType: "SingleUserIssueCustomField"
            )]
        )
        let comments = [TrackerComment(id: "c", text: "Hi", author: TrackerUser(id: "1", login: "jane", name: "Jane Doe"), created: Date())]
        // Their order is the language's alphabet, which is the machine's, so
        // only who they are is asked about.
        let logins = issue.people(with: comments).map(\.login)
        #expect(logins.count == 3)
        #expect(Set(logins) == ["benjamin", "jane", "max.k"])
    }
}

@Suite("Where an issue is handed")
struct HandoverTests {
    private let site = Project(name: "Site", rootPath: "/work/site")
    private let app = Project(name: "App", rootPath: "/work/app")
    private let tools = Project(name: "Tools", rootPath: "/work/tools")

    @Test("The project its issues went to last comes first, then the board's, then the rest in order")
    func order() {
        let all = [site, app, tools]
        #expect(AppModel.handoverOrder(of: all, remembered: tools.id, board: app.id).map(\.name) == ["Tools", "App", "Site"])
        #expect(AppModel.handoverOrder(of: all, remembered: nil, board: app.id).map(\.name) == ["App", "Site", "Tools"])
        #expect(AppModel.handoverOrder(of: all, remembered: app.id, board: app.id).map(\.name) == ["App", "Site", "Tools"])
    }

    @Test("A remembered project that is gone is passed over")
    func removedProject() {
        let gone = Project(name: "Gone", rootPath: "/work/gone")
        #expect(AppModel.handoverOrder(of: [site, app], remembered: gone.id, board: site.id).map(\.name) == ["Site", "App"])
    }

    @Test("Where each tracker project's issues went is kept, and a workspace without it still opens")
    func destinationsPersist() throws {
        let settings = TrackerSettings(kind: .youTrack, address: "https://yt.example", destinations: ["0-3": "p1"])
        let read = try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(settings))
        #expect(read.destinations == ["0-3": "p1"])
        let older = try JSONDecoder().decode(TrackerSettings.self, from: Data(#"{"address": "https://yt.example"}"#.utf8))
        #expect(older.destinations.isEmpty)
    }
}

@Suite("The time on an issue")
struct WorkLogTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let me = TrackerUser(id: "1", login: "me", name: "Me")
    private let anton = TrackerUser(id: "2", login: "anton", name: "Anton")

    private func item(_ id: String, _ minutes: Int, hoursIn: Double, by author: TrackerUser?) -> TrackerWorkItem {
        TrackerWorkItem(id: id, minutes: minutes, date: Date(timeIntervalSince1970: hoursIn * 3600), author: author)
    }

    @Test("Entries are grouped by day, newest day first, with each day's total")
    func days() {
        let items = [
            item("a", 60, hoursIn: 1, by: me),
            item("b", 30, hoursIn: 30, by: anton),
            item("c", 90, hoursIn: 5, by: anton),
        ]
        let days = WorkLog.days(of: items, in: utc)
        #expect(days.map(\.minutes) == [30, 150])
        #expect(days[1].items.map(\.id) == ["c", "a"])
    }

    @Test("Your time is what you recorded, and nobody signed in has recorded nothing")
    func mine() {
        let items = [item("a", 60, hoursIn: 1, by: me), item("b", 30, hoursIn: 2, by: anton), item("c", 5, hoursIn: 3, by: nil)]
        #expect(WorkLog.minutes(in: WorkLog.items(items, by: "me")) == 60)
        #expect(WorkLog.items(items, by: nil).isEmpty)
        #expect(WorkLog.minutes(in: items) == 95)
    }
}
