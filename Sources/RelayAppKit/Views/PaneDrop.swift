import RelayProtocol
import RelayUI
import SwiftUI
import UniformTypeIdentifiers

/// Where a pointer inside a pane is asking the dropped session to go.
///
/// Pure geometry so the rule can be stated once and tested, instead of being
/// re-derived from pixel arithmetic scattered through a view.
enum PaneDropZones {
    /// How much of each side reads as "beside this pane" rather than "in its
    /// place". A quarter is wide enough to hit without aiming and narrow enough
    /// that the middle of a pane still means the middle.
    static let edgeBand = 0.25

    static func edge(at point: CGPoint, in size: CGSize) -> PaneDropEdge {
        guard size.width > 0, size.height > 0 else { return .replace }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)

        let horizontal = min(x, 1 - x)
        let vertical = min(y, 1 - y)
        guard min(horizontal, vertical) < edgeBand else { return .replace }

        // In a corner both bands qualify. The nearer edge wins, which is what
        // the pointer is actually saying.
        if horizontal <= vertical {
            return x < 0.5 ? .leading : .trailing
        }
        return y < 0.5 ? .top : .bottom
    }

    /// The space the dropped pane is about to occupy, for the preview.
    static func previewRect(for edge: PaneDropEdge, in size: CGSize) -> CGRect {
        switch edge {
        case .replace: CGRect(origin: .zero, size: size)
        case .leading: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .trailing: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

/// Reports where in a pane the drag currently is, and lands it there.
///
/// A delegate rather than `dropDestination`, because only `dropUpdated` reports
/// the pointer's position while it moves — and without that the preview could
/// only say "somewhere in this pane", which is the half of the gesture that
/// carries no information.
private struct PaneDropDelegate: DropDelegate {
    let size: CGSize
    let draggedSession: () -> SessionID?
    let onZoneChanged: (PaneDropEdge?) -> Void
    let onDrop: (SessionID, PaneDropEdge) -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        draggedSession() != nil
    }

    func dropEntered(info: DropInfo) {
        guard draggedSession() != nil else { return }
        onZoneChanged(PaneDropZones.edge(at: info.location, in: size))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggedSession() != nil else { return DropProposal(operation: .cancel) }
        onZoneChanged(PaneDropZones.edge(at: info.location, in: size))
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        onZoneChanged(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let session = draggedSession() else { return false }
        let edge = PaneDropZones.edge(at: info.location, in: size)
        onZoneChanged(nil)
        onDrop(session, edge)
        return true
    }
}

private struct PaneDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: SessionID

    @State private var size: CGSize = .zero
    @State private var zone: PaneDropEdge?

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, updated in size = updated }
                }
            }
            .overlay { preview }
            .onDrop(
                of: [.text],
                delegate: PaneDropDelegate(
                    size: size,
                    draggedSession: { model.draggingSessionID },
                    onZoneChanged: { zone = $0 },
                    onDrop: { session, edge in
                        model.movePane(session, onto: target, edge: edge)
                    }
                )
            )
    }

    @ViewBuilder
    private var preview: some View {
        if let zone {
            GeometryReader { proxy in
                let rect = PaneDropZones.previewRect(for: zone, in: proxy.size)
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.Palette.accent.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .strokeBorder(Theme.Palette.accent, lineWidth: 1.5)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            // Purely a preview; the drop itself is handled by the delegate.
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.1), value: zone)
        }
    }
}

extension View {
    /// Accepts a dragged session, splitting towards whichever edge it is over.
    func paneDropTarget(_ target: SessionID) -> some View {
        modifier(PaneDropTarget(target: target))
    }

    /// Marks a view as a handle for dragging a session into a pane.
    ///
    /// The payload is the session's identifier, but the drop reads the model
    /// instead: `onDrag` fires the moment the drag starts, while an item
    /// provider only resolves on drop — far too late to preview anything.
    func sessionDragSource(_ sessionID: SessionID, model: AppModel) -> some View {
        onDrag {
            model.draggingSessionID = sessionID
            return NSItemProvider(object: sessionID.rawValue as NSString)
        }
    }
}
