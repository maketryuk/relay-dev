import SwiftUI
import Testing

@testable import RelayUI

@Suite("Tooltip placement")
struct TooltipPlacementTests {
    private let container = CGSize(width: 1000, height: 700)
    private let bubble = CGSize(width: 140, height: 28)

    private func place(anchor: CGRect, edge: Edge, size: CGSize? = nil) -> CGSize {
        TooltipPlacement.offset(
            anchor: anchor,
            edge: edge,
            size: size ?? bubble,
            container: container
        )
    }

    @Test("A bubble below a control is centred under it")
    func centredBelow() {
        let anchor = CGRect(x: 400, y: 100, width: 24, height: 24)
        let offset = place(anchor: anchor, edge: .bottom)
        #expect(offset.width == anchor.midX - bubble.width / 2)
        #expect(offset.height == anchor.maxY + TooltipPlacement.gap)
    }

    @Test("Each edge positions on the expected side")
    func edges() {
        let anchor = CGRect(x: 400, y: 300, width: 24, height: 24)
        #expect(place(anchor: anchor, edge: .top).height == anchor.minY - bubble.height - TooltipPlacement.gap)
        #expect(place(anchor: anchor, edge: .trailing).width == anchor.maxX + TooltipPlacement.gap)
        #expect(place(anchor: anchor, edge: .leading).width == anchor.minX - bubble.width - TooltipPlacement.gap)
        // Side placements are vertically centred on the control.
        #expect(place(anchor: anchor, edge: .trailing).height == anchor.midY - bubble.height / 2)
    }

    @Test("A bubble near the right edge is pulled back inside the window")
    func clampsToRightEdge() {
        // The sidebar's gear button is the real case: centred, the bubble would
        // run past the window and be clipped.
        let anchor = CGRect(x: 960, y: 100, width: 24, height: 24)
        let offset = place(anchor: anchor, edge: .bottom)
        #expect(offset.width + bubble.width <= container.width - TooltipPlacement.margin)
    }

    @Test("A bubble near the left edge stays inside too")
    func clampsToLeftEdge() {
        let anchor = CGRect(x: 4, y: 100, width: 24, height: 24)
        #expect(place(anchor: anchor, edge: .bottom).width >= TooltipPlacement.margin)

        // The rail's buttons point trailing; leading would go off-window.
        let leading = place(anchor: anchor, edge: .leading)
        #expect(leading.width >= TooltipPlacement.margin)
    }

    @Test("A bubble that would fall off the bottom flips above the control")
    func flipsAboveNearBottom() {
        // Rail buttons live at the bottom of the window.
        let anchor = CGRect(x: 30, y: 660, width: 28, height: 28)
        let offset = place(anchor: anchor, edge: .bottom)
        #expect(offset.height < anchor.minY)
        #expect(offset.height + bubble.height <= container.height)
    }

    @Test("A bubble never escapes the top")
    func clampsToTop() {
        let anchor = CGRect(x: 400, y: 2, width: 24, height: 24)
        #expect(place(anchor: anchor, edge: .top).height >= TooltipPlacement.margin)
    }

    @Test("A bubble wider than the window is still anchored inside it")
    func oversizedBubble() {
        let wide = CGSize(width: 1200, height: 28)
        let offset = place(anchor: CGRect(x: 500, y: 100, width: 24, height: 24), edge: .bottom, size: wide)
        #expect(offset.width == TooltipPlacement.margin)
    }
}

@Suite("Tooltip presentation")
@MainActor
struct TooltipPresenterTests {
    private func request(_ id: UUID, label: String = "Label") -> TooltipRequest {
        TooltipRequest(id: id, label: label, shortcut: "⌘T", anchor: CGRect(x: 0, y: 0, width: 10, height: 10), edge: .bottom)
    }

    @Test("Showing replaces whatever was visible")
    func showReplaces() {
        let presenter = TooltipPresenter()
        let first = UUID()
        let second = UUID()
        presenter.show(request(first, label: "First"))
        presenter.show(request(second, label: "Second"))
        #expect(presenter.request?.label == "Second")
    }

    @Test("Only the control that opened a tooltip can close it")
    func dismissIsOwnerOnly() {
        // Moving between two buttons fires the new one's enter before the old
        // one's exit; without ownership the fresh tooltip would be cancelled.
        let presenter = TooltipPresenter()
        let old = UUID()
        let new = UUID()
        presenter.show(request(old))
        presenter.show(request(new))
        presenter.dismiss(id: old)
        #expect(presenter.request?.id == new)

        presenter.dismiss(id: new)
        #expect(presenter.request == nil)
    }
}
