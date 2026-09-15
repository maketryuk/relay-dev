import RelayProtocol
import SwiftUI

// MARK: - StatusDot

/// The atom of the whole product: one glance, one colour, one meaning.
public struct StatusDot: View {
    private let status: RuntimeStatus
    private let size: CGFloat
    private let showsRing: Bool

    @State private var isPulsing = false

    public init(status: RuntimeStatus, size: CGFloat = 7, showsRing: Bool = false) {
        self.status = status
        self.size = size
        self.showsRing = showsRing
    }

    public var body: some View {
        ZStack {
            if showsRing {
                Circle()
                    .fill(Theme.Palette.rail)
                    .frame(width: size + 4, height: size + 4)
            }
            Circle()
                .fill(status.tint)
                .frame(width: size, height: size)
                .opacity(status.pulses && isPulsing ? 0.45 : 1)
        }
        .animation(
            status.pulses
                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                : .default,
            value: isPulsing
        )
        .onAppear { isPulsing = status.pulses }
        .onChange(of: status) { _, newValue in isPulsing = newValue.pulses }
        .accessibilityLabel(status.displayName)
    }
}

// MARK: - Buttons

public enum RelayButtonStyleKind {
    case primary
    case secondary
    case ghost
    case destructive
}

public struct RelayButton: View {
    private let title: String
    private let systemImage: String?
    private let kind: RelayButtonStyleKind
    private let action: () -> Void

    @State private var isHovering = false

    public init(
        _ title: String,
        systemImage: String? = nil,
        kind: RelayButtonStyleKind = .secondary,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xsmall + 2) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(Theme.Typography.row)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        switch kind {
        case .primary: isHovering ? Theme.Palette.accent.opacity(0.9) : Theme.Palette.accent
        case .secondary: isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surfaceRaised
        case .ghost: isHovering ? Theme.Palette.surfaceHover : .clear
        case .destructive: isHovering ? Theme.Palette.statusError.opacity(0.18) : Theme.Palette.surfaceRaised
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary, .ghost: Theme.Palette.textPrimary
        case .destructive: Theme.Palette.statusError
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: .clear
        case .secondary: Theme.Palette.border
        case .ghost: .clear
        case .destructive: Theme.Palette.border
        }
    }
}

/// The one icon control in the app.
///
/// Every icon-only affordance goes through this: a toolbar button, a tab, a row
/// action. Hover, disabled and selected states were being reimplemented per site
/// and drifting apart — the notification bell had no hover while the gear beside
/// it did.
public struct IconButton: View {
    public enum Prominence {
        /// Ordinary toolbar or row action.
        case standard
        /// Sits in a group where one is chosen, such as a tab strip.
        case selectable
    }

    private let systemImage: String
    private let help: String
    private let size: CGFloat
    private let prominence: Prominence
    private let isSelected: Bool
    private let isEnabled: Bool
    private let tint: Color?
    private let action: () -> Void

    @State private var isHovering = false

    public init(
        systemImage: String,
        help: String = "",
        size: CGFloat = 24,
        prominence: Prominence = .standard,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.help = help
        self.size = size
        self.prominence = prominence
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .medium))
                .frame(width: size, height: size)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                // Without this the glyph itself is the target and the padding
                // around it does nothing, which makes small buttons feel broken.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = isEnabled && $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .help(help)
    }

    private var background: Color {
        guard isEnabled else { return .clear }
        if isSelected { return isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surfaceActive }
        return isHovering ? Theme.Palette.surfaceHover : .clear
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.Palette.textTertiary.opacity(0.4) }
        if let tint { return isHovering ? tint : tint.opacity(0.85) }
        if isSelected { return Theme.Palette.textPrimary }
        return isHovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
    }
}

/// A small labelled button for grouped actions, such as the Compose row.
public struct PillButton: View {
    private let title: String
    private let systemImage: String?
    private let isEnabled: Bool
    private let action: () -> Void

    @State private var isHovering = false

    public init(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 8, weight: .semibold))
                }
                Text(title).font(Theme.Typography.caption)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = isEnabled && $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }

    private var background: Color {
        guard isEnabled else { return Theme.Palette.surface }
        return isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surfaceRaised
    }

    private var foreground: Color {
        isEnabled
            ? (isHovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
            : Theme.Palette.textTertiary.opacity(0.5)
    }
}

// MARK: - Text input

public struct RelayTextField: View {
    private let placeholder: String
    private let systemImage: String?
    @Binding private var text: String
    private let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    public init(
        _ placeholder: String,
        text: Binding<String>,
        systemImage: String? = nil,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.placeholder = placeholder
        _text = text
        self.systemImage = systemImage
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($isFocused)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, Theme.Spacing.small + 2)
        .padding(.vertical, 7)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(isFocused ? Theme.Palette.accent.opacity(0.7) : Theme.Palette.border, lineWidth: 1)
        )
    }
}

// MARK: - Structure

public struct RelayDivider: View {
    private let axis: Axis

    public init(axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        Rectangle()
            .fill(Theme.Palette.border)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

public struct SectionHeader<Trailing: View>: View {
    private let title: String
    private let isCollapsed: Bool
    private let onToggle: (() -> Void)?
    private let trailing: Trailing

    @State private var isHovering = false

    public init(
        _ title: String,
        isCollapsed: Bool = false,
        onToggle: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.isCollapsed = isCollapsed
        self.onToggle = onToggle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            if onToggle != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Text(title.uppercased())
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer(minLength: 0)
            trailing.opacity(isHovering ? 1 : 0.35)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 2)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onToggle?() }
    }
}

/// When a row's trailing controls are shown.
public enum RowAccessoryVisibility {
    /// Keeps the row quiet until the pointer is over it. Right for destructive
    /// or secondary actions.
    case onHover
    /// Always visible. Right for controls that are the point of the row, such
    /// as starting and stopping a service.
    case always
}

public struct SidebarRow<Accessory: View>: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let iconTint: Color?
    /// When set, the row draws that agent's own mark instead of an SF Symbol.
    private let sessionKind: SessionKind?
    private let status: RuntimeStatus?
    private let isSelected: Bool
    private let action: () -> Void
    private let doubleTapAction: (() -> Void)?
    private let accessoryVisibility: RowAccessoryVisibility
    private let accessory: Accessory

    @State private var isHovering = false

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        iconTint: Color? = nil,
        sessionKind: SessionKind? = nil,
        status: RuntimeStatus? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void,
        doubleTapAction: (() -> Void)? = nil,
        accessoryVisibility: RowAccessoryVisibility = .onHover,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.sessionKind = sessionKind
        self.status = status
        self.isSelected = isSelected
        self.action = action
        self.doubleTapAction = doubleTapAction
        self.accessoryVisibility = accessoryVisibility
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Group {
                if let sessionKind {
                    SessionGlyph(kind: sessionKind, size: 11, tint: glyphColor)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(glyphColor)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.row)
                    .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.xsmall)

            if isHovering || accessoryVisibility == .always {
                accessory
            }
            if let status {
                StatusDot(status: status)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 5)
        .frame(minHeight: Theme.Metrics.rowHeight)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // The double-tap gesture must be declared first, otherwise the single
        // tap claims the event and the second click never arrives.
        .onTapGesture(count: 2) { (doubleTapAction ?? action)() }
        .onTapGesture(count: 1, perform: action)
    }

    private var rowBackground: Color {
        if isSelected { return Theme.Palette.surfaceActive }
        return isHovering ? Theme.Palette.surfaceHover : .clear
    }

    private var glyphColor: Color {
        if let iconTint {
            return isSelected || isHovering ? iconTint : iconTint.opacity(0.75)
        }
        return isSelected ? Theme.Palette.textPrimary : Theme.Palette.textTertiary
    }
}

// MARK: - Badges

public struct Badge: View {
    private let text: String
    private let tint: Color

    public init(_ text: String, tint: Color = Theme.Palette.textTertiary) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Containers

/// Standard panel look: raised surface, soft border, large radius.
public struct Panel<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )
    }
}

public struct EmptyStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String

    public init(systemImage: String, title: String, message: String) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.Palette.textTertiary)
            VStack(spacing: Theme.Spacing.xsmall) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(message)
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
