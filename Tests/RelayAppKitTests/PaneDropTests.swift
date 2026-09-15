import CoreGraphics
import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Pane drop zones")
struct PaneDropZoneTests {
    private let size = CGSize(width: 800, height: 400)

    @Test("The middle of a pane means take it over")
    func centreReplaces() {
        #expect(PaneDropZones.edge(at: CGPoint(x: 400, y: 200), in: size) == .replace)
    }

    @Test("Each edge band splits towards that edge")
    func edgesSplit() {
        #expect(PaneDropZones.edge(at: CGPoint(x: 20, y: 200), in: size) == .leading)
        #expect(PaneDropZones.edge(at: CGPoint(x: 780, y: 200), in: size) == .trailing)
        #expect(PaneDropZones.edge(at: CGPoint(x: 400, y: 10), in: size) == .top)
        #expect(PaneDropZones.edge(at: CGPoint(x: 400, y: 390), in: size) == .bottom)
    }

    @Test("A corner resolves to whichever edge is nearer")
    func cornersPickTheNearerEdge() {
        // Both bands claim a corner, so the answer has to come from the
        // pointer's actual distance rather than from the order of the checks.
        #expect(PaneDropZones.edge(at: CGPoint(x: 8, y: 40), in: size) == .leading)
        #expect(PaneDropZones.edge(at: CGPoint(x: 40, y: 4), in: size) == .top)
    }

    @Test("A pane with no size cannot be split into")
    func zeroSizeReplaces() {
        #expect(PaneDropZones.edge(at: .zero, in: .zero) == .replace)
    }

    @Test("The preview covers the space the pane will take")
    func previewMatchesTheOutcome() {
        #expect(PaneDropZones.previewRect(for: .replace, in: size) == CGRect(origin: .zero, size: size))
        #expect(PaneDropZones.previewRect(for: .leading, in: size) == CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(PaneDropZones.previewRect(for: .trailing, in: size) == CGRect(x: 400, y: 0, width: 400, height: 400))
        #expect(PaneDropZones.previewRect(for: .top, in: size) == CGRect(x: 0, y: 0, width: 800, height: 200))
        #expect(PaneDropZones.previewRect(for: .bottom, in: size) == CGRect(x: 0, y: 200, width: 800, height: 200))
    }
}

@Suite("Moving a pane")
struct PaneMoveTests {
    private let a = SessionID(rawValue: "a")
    private let b = SessionID(rawValue: "b")
    private let c = SessionID(rawValue: "c")

    @Test("Dropping on the trailing edge puts the newcomer second")
    func trailingAppends() {
        let moved = PaneLayout.moving(b, onto: a, edge: .trailing, in: .session(a))
        guard case let .split(split) = moved else {
            Issue.record("expected a split")
            return
        }
        #expect(split.axis == .horizontal)
        #expect(split.first == .session(a))
        #expect(split.second == .session(b))
    }

    @Test("Dropping on the leading edge puts the newcomer first")
    func leadingPrepends() {
        let moved = PaneLayout.moving(b, onto: a, edge: .leading, in: .session(a))
        guard case let .split(split) = moved else {
            Issue.record("expected a split")
            return
        }
        #expect(split.first == .session(b))
        #expect(split.second == .session(a))
    }

    @Test("Dropping on the top edge stacks the newcomer above")
    func topStacksAbove() {
        let moved = PaneLayout.moving(b, onto: a, edge: .top, in: .session(a))
        guard case let .split(split) = moved else {
            Issue.record("expected a split")
            return
        }
        #expect(split.axis == .vertical)
        #expect(split.first == .session(b))
    }

    @Test("Dropping in the middle takes the pane over")
    func replaceSwapsTheOccupant() {
        let moved = PaneLayout.moving(b, onto: a, edge: .replace, in: .session(a))
        #expect(moved == .session(b))
    }

    @Test("A pane dragged across a split moves rather than appearing twice")
    func movingWithinALayoutDoesNotDuplicate() {
        // Without removing the session first the tree would show one terminal in
        // two panes, which is two views of one process pretending to be two.
        let layout = PaneNode.split(PaneSplit(axis: .horizontal, first: .session(a), second: .session(b)))
        let moved = PaneLayout.moving(a, onto: b, edge: .bottom, in: layout)

        #expect(PaneLayout.sessions(in: moved).sorted { $0.rawValue < $1.rawValue } == [a, b])
        guard case let .split(split) = moved else {
            Issue.record("expected a split")
            return
        }
        #expect(split.axis == .vertical)
        #expect(split.first == .session(b))
        #expect(split.second == .session(a))
    }

    @Test("Dropping a pane on itself changes nothing")
    func droppingOnItselfIsANoOp() {
        let layout = PaneNode.split(PaneSplit(axis: .horizontal, first: .session(a), second: .session(b)))
        #expect(PaneLayout.moving(a, onto: a, edge: .leading, in: layout) == layout)
    }

    @Test("A session arriving from the sidebar joins the pane it was dropped on")
    func arrivingSessionJoinsTheTarget() {
        let layout = PaneNode.split(PaneSplit(axis: .horizontal, first: .session(a), second: .session(b)))
        let moved = PaneLayout.moving(c, onto: b, edge: .trailing, in: layout)
        #expect(PaneLayout.sessions(in: moved) == [a, b, c])
    }
}
