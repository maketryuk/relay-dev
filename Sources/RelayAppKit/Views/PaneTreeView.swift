import RelayProtocol
import RelayUI
import SwiftUI

/// Draws the pane tree.
///
/// Recursive, because the model is: a split whose halves may themselves be
/// splits. Each leaf is a terminal, and the divider between two panes resizes
/// the split that owns it.
struct PaneTreeView: View {
    @Environment(AppModel.self) private var model
    let node: PaneNode
    let projectID: ProjectID

    var body: some View {
        switch node {
        case let .session(sessionID):
            leaf(sessionID)
        case let .split(split):
            SplitPaneView(split: split, projectID: projectID)
        }
    }

    @ViewBuilder
    private func leaf(_ sessionID: SessionID) -> some View {
        if let session = model.sessions[sessionID] {
            TerminalPane(session: session)
                .overlay(alignment: .top) { focusIndicator(for: sessionID) }
                // A click anywhere in a pane focuses it, which is what makes a
                // split usable without reaching for the sidebar.
                .onTapGesture { model.selectSession(sessionID) }
                .paneDropTarget(sessionID)
        } else {
            EmptyStateView(
                systemImage: "terminal",
                title: relayLocalized("Session unavailable"),
                message: relayLocalized("This session is no longer known to the daemon.")
            )
            .background(Theme.Palette.base)
        }
    }

    /// Which pane the keyboard is talking to. Only drawn when there is more
    /// than one, because a lone pane is unambiguous.
    @ViewBuilder
    private func focusIndicator(for sessionID: SessionID) -> some View {
        let layout = model.paneLayout(for: projectID)
        let paneCount = layout.map { PaneLayout.sessions(in: $0).count } ?? 1

        if paneCount > 1 {
            Rectangle()
                .fill(model.selectedSessionID == sessionID ? Theme.Palette.accent : .clear)
                .frame(height: 2)
                .animation(.easeOut(duration: 0.12), value: model.selectedSessionID)
        }
    }
}

private struct SplitPaneView: View {
    @Environment(AppModel.self) private var model
    let split: PaneSplit
    let projectID: ProjectID

    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = split.axis == .horizontal ? proxy.size.width : proxy.size.height
            let fraction = dragFraction ?? split.fraction
            let firstLength = max(0, (total - dividerThickness) * fraction)
            let secondLength = max(0, total - dividerThickness - firstLength)

            layout {
                PaneTreeView(node: split.first, projectID: projectID)
                    .frame(
                        width: split.axis == .horizontal ? firstLength : nil,
                        height: split.axis == .vertical ? firstLength : nil
                    )

                divider(total: total)

                PaneTreeView(node: split.second, projectID: projectID)
                    .frame(
                        width: split.axis == .horizontal ? secondLength : nil,
                        height: split.axis == .vertical ? secondLength : nil
                    )
            }
        }
    }

    private var dividerThickness: CGFloat { 1 }

    @ViewBuilder
    private func layout(@ViewBuilder content: () -> some View) -> some View {
        if split.axis == .horizontal {
            HStack(spacing: 0, content: content)
        } else {
            VStack(spacing: 0, content: content)
        }
    }

    private func divider(total: CGFloat) -> some View {
        ResizeHandle(orientation: split.axis == .horizontal ? .vertical : .horizontal) {
            dragFraction = split.fraction
        } onDrag: { translation in
            dragFraction = ResizeMath.fraction(
                from: split.fraction,
                translation: translation,
                total: total,
                limits: PaneLayout.minimumFraction ... PaneLayout.maximumFraction
            )
        } onEnd: {
            if let dragFraction {
                model.setPaneFraction(dragFraction, forSplit: split.id, in: projectID)
            }
            dragFraction = nil
            model.commitPaneLayout()
        }
    }
}
