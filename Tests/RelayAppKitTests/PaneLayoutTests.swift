import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

@Suite("Pane layout")
struct PaneLayoutTests {
    private let a = SessionID(rawValue: "a")
    private let b = SessionID(rawValue: "b")
    private let c = SessionID(rawValue: "c")
    private let d = SessionID(rawValue: "d")

    @Test("A single pane holds one session")
    func singlePane() {
        let layout = PaneNode.session(a)
        #expect(PaneLayout.sessions(in: layout) == [a])
        #expect(PaneLayout.contains(a, in: layout))
        #expect(!PaneLayout.contains(b, in: layout))
    }

    @Test("Splitting a pane puts the new session beside it")
    func splittingAPane() {
        let layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        #expect(PaneLayout.sessions(in: layout) == [a, b])
    }

    @Test("Splitting nests, so a split can itself be split")
    func splittingNests() {
        // Anything flatter would make the second split a special case.
        var layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        layout = PaneLayout.split(layout, target: b, with: c, axis: .vertical)
        #expect(PaneLayout.sessions(in: layout) == [a, b, c])

        guard case let .split(outer) = layout else {
            Issue.record("Expected a split")
            return
        }
        #expect(outer.axis == .horizontal)
        guard case let .split(inner) = outer.second else {
            Issue.record("Expected a nested split")
            return
        }
        #expect(inner.axis == .vertical)
        #expect(PaneLayout.sessions(in: inner.first) == [b])
    }

    @Test("Splitting an absent pane changes nothing")
    func splittingUnknownTarget() {
        let layout = PaneLayout.split(.session(a), target: b, with: c, axis: .horizontal)
        #expect(PaneLayout.sessions(in: layout) == [a])
    }

    @Test("Removing a pane collapses the split that held it")
    func removingCollapses() {
        let layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        let remaining = PaneLayout.removing(b, from: layout)
        #expect(remaining == .session(a))
    }

    @Test("Removing the last pane leaves nothing, not an empty split")
    func removingEverything() throws {
        #expect(PaneLayout.removing(a, from: .session(a)) == nil)

        let layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        let afterFirst = try #require(PaneLayout.removing(a, from: layout))
        #expect(PaneLayout.removing(b, from: afterFirst) == nil)
    }

    @Test("Removing from a nested split keeps the rest intact")
    func removingFromNestedSplit() {
        var layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        layout = PaneLayout.split(layout, target: b, with: c, axis: .vertical)
        let remaining = PaneLayout.removing(b, from: layout)
        #expect(remaining.map { PaneLayout.sessions(in: $0) } == [a, c])
    }

    @Test("Replacing swaps the session a pane shows")
    func replacing() {
        let layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        let updated = PaneLayout.replacing(a, with: c, in: layout)
        #expect(PaneLayout.sessions(in: updated) == [c, b])
    }

    @Test("Pruning drops panes the daemon has forgotten")
    func pruning() {
        // Sessions outlive the app, but not for ever; a layout referring to a
        // session that has gone would render an empty pane.
        var layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        layout = PaneLayout.split(layout, target: b, with: c, axis: .vertical)

        let pruned = PaneLayout.pruning(layout, keeping: [a, c])
        #expect(pruned.map { PaneLayout.sessions(in: $0) } == [a, c])

        #expect(PaneLayout.pruning(layout, keeping: []) == nil)
        #expect(PaneLayout.pruning(layout, keeping: [a, b, c]) == layout)
    }

    @Test("A divider cannot be dragged far enough to hide a pane")
    func fractionIsClamped() {
        let layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        guard case let .split(split) = layout else {
            Issue.record("Expected a split")
            return
        }

        let collapsed = PaneLayout.setting(fraction: 0, forSplit: split.id, in: layout)
        guard case let .split(updated) = collapsed else {
            Issue.record("Expected a split")
            return
        }
        #expect(updated.fraction == PaneLayout.minimumFraction)

        let expanded = PaneLayout.setting(fraction: 2, forSplit: split.id, in: layout)
        guard case let .split(stretched) = expanded else {
            Issue.record("Expected a split")
            return
        }
        #expect(stretched.fraction == PaneLayout.maximumFraction)
    }

    @Test("Resizing addresses one split, leaving the others alone")
    func resizingIsTargeted() {
        var layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        layout = PaneLayout.split(layout, target: b, with: c, axis: .vertical)
        guard case let .split(outer) = layout, case let .split(inner) = outer.second else {
            Issue.record("Expected nested splits")
            return
        }

        let updated = PaneLayout.setting(fraction: 0.7, forSplit: inner.id, in: layout)
        guard case let .split(newOuter) = updated, case let .split(newInner) = newOuter.second else {
            Issue.record("Expected nested splits")
            return
        }
        #expect(newInner.fraction == 0.7)
        #expect(newOuter.fraction == outer.fraction)
    }

    @Test("Focus cycles through panes in layout order and wraps")
    func cyclingFocus() {
        var layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        layout = PaneLayout.split(layout, target: b, with: c, axis: .vertical)
        #expect(PaneLayout.session(after: a, in: layout) == b)
        #expect(PaneLayout.session(after: b, in: layout) == c)
        #expect(PaneLayout.session(after: c, in: layout) == a)
    }

    @Test("Cycling from a pane that is not there lands somewhere sensible")
    func cyclingFromUnknown() {
        let layout = PaneNode.session(a)
        #expect(PaneLayout.session(after: d, in: layout) == a)
        #expect(PaneLayout.session(after: a, in: layout) == a)
    }

    @Test("A layout survives persistence")
    func codable() throws {
        var layout = PaneLayout.split(.session(a), target: a, with: b, axis: .horizontal)
        layout = PaneLayout.split(layout, target: b, with: c, axis: .vertical)

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
        #expect(decoded == layout)
    }

    // MARK: - Browser tabs

    private let page = BrowserID(rawValue: "page")
    private let docs = BrowserID(rawValue: "docs")

    private let sessionBesidePage = PaneLayout.split(
        .session(SessionID(rawValue: "a")),
        target: .session(SessionID(rawValue: "a")),
        with: .browser(BrowserID(rawValue: "page")),
        axis: .horizontal
    )

    @Test("A browser tab survives persistence beside a session")
    func browserCodable() throws {
        let decoded = try JSONDecoder().decode(PaneNode.self, from: JSONEncoder().encode(sessionBesidePage))
        #expect(decoded == sessionBesidePage)
        #expect(PaneLayout.items(in: decoded) == [.session(a), .browser(page)])
    }

    @Test("A closed tab's pane goes, and an open one's stays")
    func pruningBrowser() {
        #expect(PaneLayout.pruning(sessionBesidePage, keeping: [a], openBrowsers: [page]) == sessionBesidePage)
        #expect(PaneLayout.pruning(sessionBesidePage, keeping: [a], openBrowsers: [docs]) == .session(a))
    }

    @Test("A tab takes the place of the tab on screen, the way a session replaces a session")
    func tabReplacesTab() {
        let shown = PaneLayout.showing(.browser(docs), in: sessionBesidePage, focused: .browser(page))
        #expect(PaneLayout.items(in: shown) == [.session(a), .browser(docs)])
    }

    @Test("Handing a pick to an agent does not take the place of the page it came from")
    func sessionDoesNotReplaceFocusedBrowser() {
        // The page has the keyboard when design mode sends a pick, and the
        // agent's session is selected to receive it. The page has to stay on
        // screen to check the change on.
        let shown = PaneLayout.showing(.session(b), in: sessionBesidePage, focused: .browser(page))
        #expect(PaneLayout.items(in: shown) == [.session(b), .browser(page)])
    }

    @Test("With no terminal on screen, an agent arrives beside the page")
    func sessionArrivesBesideBrowser() {
        let shown = PaneLayout.showing(.session(b), in: .browser(page), focused: .browser(page))
        #expect(PaneLayout.items(in: shown) == [.session(b), .browser(page)])
    }

    @Test("A session does not take the place of the file being worked in")
    func sessionDoesNotReplaceFocusedFile() {
        let layout = PaneLayout.split(.file("/p/a.swift"), target: .file("/p/a.swift"), with: .session(a), axis: .horizontal)
        let shown = PaneLayout.showing(.session(b), in: layout, focused: .file("/p/a.swift"))
        #expect(PaneLayout.items(in: shown) == [.file("/p/a.swift"), .session(b)])
    }
}
