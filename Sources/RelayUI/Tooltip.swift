import SwiftUI

/// A tooltip waiting to be drawn.
public struct TooltipRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let shortcut: String?
    /// Frame of the control being described, in the root coordinate space.
    public let anchor: CGRect
    public let edge: Edge

    public init(id: UUID, label: String, shortcut: String?, anchor: CGRect, edge: Edge) {
        self.id = id
        self.label = label
        self.shortcut = shortcut
        self.anchor = anchor
        self.edge = edge
    }
}

/// Holds the tooltip currently being shown.
///
/// Tooltips are drawn by a single layer at the root of the window rather than as
/// an overlay on each control. An overlay is laid out inside its own parent, so
/// anything that paints later — a sibling pane, a scroll view's clip — covers
/// it. `zIndex` cannot help, because it only orders siblings within one
/// container, and a tooltip's whole job is to escape its container.
@Observable
@MainActor
public final class TooltipPresenter {
    public private(set) var request: TooltipRequest?

    public init() {}

    public func show(_ request: TooltipRequest) {
        self.request = request
    }

    /// Only the control that put the tooltip up may take it down: moving the
    /// pointer between two buttons fires the new one's enter before the old
    /// one's exit.
    public func dismiss(id: UUID) {
        guard request?.id == id else { return }
        request = nil
    }
}

public extension EnvironmentValues {
    @Entry var tooltipPresenter: TooltipPresenter?
}

/// The coordinate space tooltip anchors are measured in.
public enum TooltipSpace {
    public static let name = "relay.tooltip.root"
}

public struct RelayTooltipModifier: ViewModifier {
    private let label: String
    private let shortcut: String?
    private let edge: Edge
    /// For a control whose answer is already on screen — the panel it opens
    /// being up, say. Kept as a parameter rather than left to the caller's `if`,
    /// because a conditional modifier gives the control a new identity and it
    /// loses its hover state mid-gesture.
    private let isEnabled: Bool

    @Environment(\.tooltipPresenter) private var presenter
    @State private var identity = UUID()
    @State private var anchor: CGRect = .zero
    @State private var revealTask: Task<Void, Never>?

    /// Long enough not to fire while the pointer crosses the toolbar, short
    /// enough to feel like an answer rather than a delay.
    private static let delay = Duration.milliseconds(400)

    public init(label: String, shortcut: String?, edge: Edge, isEnabled: Bool = true) {
        self.label = label
        self.shortcut = shortcut
        self.edge = edge
        self.isEnabled = isEnabled
    }

    public func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TooltipAnchorKey.self,
                        value: proxy.frame(in: .named(TooltipSpace.name))
                    )
                }
            )
            .onPreferenceChange(TooltipAnchorKey.self) { frame in
                anchor = frame
            }
            .onChange(of: isEnabled) { _, enabled in
                guard !enabled else { return }
                revealTask?.cancel()
                presenter?.dismiss(id: identity)
            }
            .onHover { hovering in
                revealTask?.cancel()
                guard let presenter else { return }
                guard hovering, isEnabled else {
                    presenter.dismiss(id: identity)
                    return
                }
                revealTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.delay)
                    guard !Task.isCancelled, anchor != .zero else { return }
                    presenter.show(
                        TooltipRequest(
                            id: identity,
                            label: label,
                            shortcut: shortcut,
                            anchor: anchor,
                            edge: edge
                        )
                    )
                }
            }
            .onDisappear {
                revealTask?.cancel()
                presenter?.dismiss(id: identity)
            }
    }
}

private struct TooltipAnchorKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Draws the active tooltip above everything else in the window.
public struct TooltipLayer: View {
    private let presenter: TooltipPresenter
    @State private var size: CGSize = .zero

    public init(presenter: TooltipPresenter) {
        self.presenter = presenter
    }

    public var body: some View {
        GeometryReader { proxy in
            if let request = presenter.request {
                bubble(request)
                    .fixedSize()
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: TooltipSizeKey.self, value: inner.size)
                        }
                    )
                    .onPreferenceChange(TooltipSizeKey.self) { size = $0 }
                    .offset(offset(for: request, in: proxy.size))
                    .opacity(size == .zero ? 0 : 1)
                    .animation(.easeOut(duration: 0.1), value: request.id)
            }
        }
        .allowsHitTesting(false)
    }

    private func bubble(_ request: TooltipRequest) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(request.label)
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(Theme.Palette.textPrimary)
            if let shortcut = request.shortcut {
                Text(shortcut)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 5)
        .background(Theme.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.Palette.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    private func offset(for request: TooltipRequest, in container: CGSize) -> CGSize {
        TooltipPlacement.offset(anchor: request.anchor, edge: request.edge, size: size, container: container)
    }
}

/// Where a tooltip bubble sits relative to the control it describes.
///
/// Separated from the view because the interesting part is the edge handling —
/// a bubble half outside the window is worse than one on an unexpected side —
/// and that is invisible until it goes wrong.
public enum TooltipPlacement {
    public static let gap: CGFloat = 8
    public static let margin: CGFloat = 6

    public static func offset(
        anchor: CGRect,
        edge: Edge,
        size: CGSize,
        container: CGSize
    ) -> CGSize {
        var x: CGFloat
        var y: CGFloat

        switch edge {
        case .bottom:
            x = anchor.midX - size.width / 2
            y = anchor.maxY + gap
        case .top:
            x = anchor.midX - size.width / 2
            y = anchor.minY - size.height - gap
        case .leading:
            x = anchor.minX - size.width - gap
            y = anchor.midY - size.height / 2
        case .trailing:
            x = anchor.maxX + gap
            y = anchor.midY - size.height / 2
        }

        if x + size.width > container.width - margin {
            x = container.width - size.width - margin
        }
        x = max(margin, x)

        if y + size.height > container.height - margin {
            // Flip above the control rather than clamping on top of it.
            y = anchor.minY - size.height - gap
        }
        y = max(margin, y)

        return CGSize(width: x, height: y)
    }
}

private struct TooltipSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

public extension View {
    /// Attaches a dark hover label, optionally showing the keystroke that does
    /// the same thing. Requires a `TooltipLayer` at the root of the window.
    func relayTooltip(
        _ label: String,
        shortcut: String? = nil,
        edge: Edge = .bottom,
        isEnabled: Bool = true
    ) -> some View {
        modifier(RelayTooltipModifier(label: label, shortcut: shortcut, edge: edge, isEnabled: isEnabled))
    }

    /// Installs the tooltip coordinate space and the layer that draws them.
    func tooltipRoot(_ presenter: TooltipPresenter) -> some View {
        coordinateSpace(name: TooltipSpace.name)
            .environment(\.tooltipPresenter, presenter)
            .overlay { TooltipLayer(presenter: presenter) }
    }
}
