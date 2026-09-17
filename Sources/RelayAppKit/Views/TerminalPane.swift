import AppKit
import RelayProtocol
import RelayUI
import SwiftTerm
import SwiftUI

/// Hosts a cached `TerminalView` without letting SwiftUI recreate it.
///
/// The renderer holds all the scrollback and cursor state, so it must outlive
/// any single SwiftUI view identity — hence the container that simply re-parents
/// whichever surface is current.
struct TerminalHostView: NSViewRepresentable {
    let surface: TerminalSurface
    /// Whether this pane is the one the keyboard belongs to.
    let isFocused: Bool
    /// Called when the terminal itself is clicked.
    let onClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let container = FlippedContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0x08 / 255, green: 0x09 / 255, blue: 0x0A / 255, alpha: 1).cgColor
        container.onClick = onClick
        container.embed(surface.terminalView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? FlippedContainerView else { return }
        container.onClick = onClick
        container.embed(surface.terminalView)
        // Only the focused pane may claim the keyboard. Every pane taking it on
        // every update means two of them trade it back and forth, and typing
        // lands wherever the last redraw happened to leave it.
        guard isFocused else { return }
        DispatchQueue.main.async {
            surface.focus()
        }
    }
}

final class FlippedContainerView: NSView {
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    /// How a click inside the terminal reaches SwiftUI.
    ///
    /// The terminal is an AppKit view and consumes its own mouse events, so a
    /// `.onTapGesture` layered over it never fires — which meant clicking a pane
    /// did not focus it, and every split landed on whichever pane the sidebar
    /// had last selected. `hitTest` is the one hook that runs before the child
    /// takes the event; the current event says whether this is a real click or
    /// the pointer merely passing over.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown {
            onClick?()
        }
        return hit
    }

    func embed(_ child: NSView) {
        guard child.superview !== self else { return }
        child.removeFromSuperview()
        subviews.forEach { $0.removeFromSuperview() }
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// Main content area: session header plus the live terminal.
struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    let session: SessionSnapshot

    private static let headerHeight: CGFloat = 34

    @State private var headerWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()
            terminal
            ContextBar(session: session)
        }
        .background(Theme.Palette.base)
        .overlay(alignment: .bottomLeading) { contextDetail }
    }

    /// Opened from the bar beneath it, and anchored there rather than to the
    /// pointer: the numbers it explains are the ones it sits above.
    @ViewBuilder
    private var contextDetail: some View {
        if model.sessionShowingContextDetail == session.id,
           let context = model.context.context(for: session.id) {
            ContextDetail(session: session, context: context)
                .modalPlate()
                .padding(.leading, Theme.Spacing.small)
                .padding(.bottom, Theme.Metrics.contextBarHeight + Theme.Spacing.xsmall)
                .transition(.opacity)
        }
    }

    /// Refreshed on a slow timer so the hint can appear without any event from
    /// the daemon — the whole point is that nothing is arriving.
    ///
    /// Only while the session is still starting: a timer that redraws a whole
    /// terminal pane twice a second, forever, to say nothing is not free.
    @ViewBuilder
    private var startupHint: some View {
        if session.status == .starting {
            timedStartupHint
        }
    }

    @ViewBuilder
    private var timedStartupHint: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            if let hint = StartupDiagnostics.hint(for: session, now: context.date) {
                Text(hint)
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Spacing.medium)
                    .frame(maxWidth: 460)
                    .background(Theme.Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .strokeBorder(Theme.Palette.statusWaiting.opacity(0.4), lineWidth: 1)
                    )
                    .padding(.top, Theme.Spacing.large)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                    .transition(.opacity)
            }
        }
    }

    /// What a header can afford to say at its current width.
    ///
    /// A split pane can be a couple of hundred points wide, and a header written
    /// for the full window simply falls apart there: the name wrapped down the
    /// pane, the status text pushed everything else off, and the row grew tall
    /// enough to swallow the terminal.
    private enum HeaderDetail {
        /// Name and the way out. Anything narrower is not a header.
        case minimal
        /// Plus the status dot and the pane controls.
        case standard
        /// Plus what the status is called, and the pid.
        case full

        init(width: CGFloat) {
            self = switch width {
            case ..<230: .minimal
            case ..<420: .standard
            default: .full
            }
        }

        var showsControls: Bool { self != .minimal }
        var showsStatusText: Bool { self == .full }
        var showsProcessID: Bool { self == .full }
    }

    private var header: some View {
        let detail = HeaderDetail(width: headerWidth)

        return HStack(spacing: Theme.Spacing.small) {
            SessionGlyph(
                kind: session.kind,
                size: 12,
                tint: Color(hex: session.kind.accentHex)
            )

            Text(model.label(for: session))
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Beats the status text to the remaining room: which terminal
                // this is matters more than what it is doing.
                .layoutPriority(1)
                .help(relayLocalized("Double-click the session in the sidebar to rename it"))

            StatusDot(status: session.status)
            if detail.showsStatusText {
                Text(session.status.localizedName)
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.small)

            if detail.showsProcessID, let pid = session.pid, session.exitCode == nil {
                Text(verbatim: "pid \(String(pid))")
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }

            if detail.showsControls {
                // Splitting has a keyboard shortcut and a drag gesture; neither
                // is discoverable, so the pane says out loud that it can divide.
                IconButton(systemImage: "rectangle.split.2x1", help: "") {
                    model.splitPane(showing: session.id, axis: .horizontal)
                }
                .relayTooltip(relayLocalized("Split Right"), shortcut: model.binding(for: .splitRight))

                IconButton(systemImage: "rectangle.split.1x2", help: "") {
                    model.splitPane(showing: session.id, axis: .vertical)
                }
                .relayTooltip(relayLocalized("Split Down"), shortcut: model.binding(for: .splitDown))

                IconButton(systemImage: "arrow.clockwise", help: "") {
                    model.restartSession(session.id)
                }
                .relayTooltip(relayLocalized("Restart session"))
            }

            IconButton(systemImage: "xmark", help: "") {
                model.closeSession(session.id)
            }
            .relayTooltip(relayLocalized("Close session"), shortcut: model.binding(for: .closeSession))
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        // Fixed, so nothing inside can grow the row and push the terminal down.
        .frame(height: Self.headerHeight)
        .background(Theme.Palette.sidebar)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { headerWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, updated in headerWidth = updated }
            }
        }
        .contentShape(Rectangle())
        // The header is the pane's handle: drag it onto another pane to move
        // this terminal there, the way a tab bar works. The open hand is the
        // only thing that says so before the drag.
        .relayPointer(.draggable)
        .sessionDragSource(session.id, model: model)
    }

    @ViewBuilder
    private var terminal: some View {
        if let surface = model.surface(for: session.id) {
            TerminalHostView(
                surface: surface,
                isFocused: model.selectedSessionID == session.id,
                onClick: { model.selectSession(session.id) }
            )
                .id(session.id)
                .overlay(alignment: .top) { startupHint }
                .onChange(of: model.focusTerminalRequest) { _, _ in surface.focus() }
        } else {
            EmptyStateView(
                systemImage: "terminal",
                title: relayLocalized("Session unavailable"),
                message: relayLocalized("This session is no longer known to the daemon.")
            )
        }
    }
}
