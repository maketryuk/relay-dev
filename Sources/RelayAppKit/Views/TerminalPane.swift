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

    func makeNSView(context: Context) -> NSView {
        let container = FlippedContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0x08 / 255, green: 0x09 / 255, blue: 0x0A / 255, alpha: 1).cgColor
        container.embed(surface.terminalView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? FlippedContainerView else { return }
        container.embed(surface.terminalView)
        DispatchQueue.main.async {
            surface.focus()
        }
    }
}

final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }

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

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()
            terminal
        }
        .background(Theme.Palette.base)
    }

    /// Refreshed on a slow timer so the hint can appear without any event from
    /// the daemon — the whole point is that nothing is arriving.
    @ViewBuilder
    private var startupHint: some View {
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

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            SessionGlyph(
                kind: session.kind,
                size: 12,
                tint: Color(hex: session.kind.accentHex)
            )

            Text(session.displayName)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textPrimary)
                .help("Double-click the session in the sidebar to rename it")

            StatusDot(status: session.status)
            Text(session.status.displayName)
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(Theme.Palette.textTertiary)

            // An expanding drag region rather than a plain spacer, so the
            // empty middle of the header behaves like a title bar.
            WindowDragArea()
                .frame(minWidth: Theme.Spacing.medium, maxWidth: .infinity, maxHeight: .infinity)

            if let pid = session.pid, session.exitCode == nil {
                Text("pid \(pid)")
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            IconButton(systemImage: "arrow.clockwise", help: "") {
                model.closeSession(session.id)
                if let projectID = model.selectedProjectID {
                    model.createSession(kind: session.kind, in: projectID)
                }
            }
            .relayTooltip("Restart session")

            IconButton(systemImage: "xmark", help: "") {
                model.closeSession(session.id)
            }
            .relayTooltip("Close session", shortcut: model.binding(for: .closeSession))
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.large + 2)
        .padding(.bottom, Theme.Spacing.small)
        .background(Theme.Palette.sidebar)
    }

    @ViewBuilder
    private var terminal: some View {
        if let surface = model.surface(for: session.id) {
            TerminalHostView(surface: surface)
                .id(session.id)
                .overlay(alignment: .top) { startupHint }
                .onChange(of: model.focusTerminalRequest) { _, _ in surface.focus() }
        } else {
            EmptyStateView(
                systemImage: "terminal",
                title: "Session unavailable",
                message: "This session is no longer known to the daemon."
            )
        }
    }
}
