import RelayProtocol
import SwiftUI

// MARK: - StatusDot

/// The atom of the whole product: one glance, one shape, one meaning.
///
/// The shape says which state it is and the colour confirms it. Seven dots
/// told apart by hue alone asked for eyes that can tell amber from green at
/// seven points across, and three of them pulsed, which said "something is
/// going on" three ways that looked the same. Work in progress turns, a
/// question is a question, a result is a tick, and a plain dot is left to the
/// states at rest.
public struct StatusDot: View {
    private let status: RuntimeStatus
    private let size: CGFloat
    private let showsRing: Bool

    /// `size` is the diameter of a plain dot. Any other mark is drawn a third
    /// larger: a ring weighs less than a disc of the same width, and a question
    /// mark at seven points is a smudge.
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
                    .frame(width: markDiameter + 4, height: markDiameter + 4)
            }
            mark
        }
        // The same box whatever the state, so a title beside it does not
        // shift sideways when its session starts asking something.
        .frame(width: boxSize, height: boxSize)
        .accessibilityElement()
        .accessibilityLabel(status.displayName)
    }

    @ViewBuilder
    private var mark: some View {
        switch status.mark {
        case .spinner:
            WorkingSpinner(tint: status.tint, diameter: glyphSize)
        case .question:
            // A circle rather than a speech bubble, whose tail would stick out
            // of the ring that parts a badge from the artwork under it.
            glyph("questionmark.circle.fill")
        case .check:
            glyph("checkmark.circle.fill")
        case .dot:
            Circle()
                .fill(status.tint)
                .frame(width: size, height: size)
        }
    }

    private func glyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(status.tint)
            .frame(width: glyphSize, height: glyphSize)
    }

    private var glyphSize: CGFloat { (size * 4 / 3).rounded() }

    private var markDiameter: CGFloat {
        switch status.mark {
        case .spinner, .question, .check: glyphSize
        case .dot: size
        }
    }

    private var boxSize: CGFloat { glyphSize + (showsRing ? 4 : 0) }
}

/// An open ring turning once a second in twelve steps: as smooth as a few
/// points of arc can show, for a fifth of the redraws of a continuous
/// animation. The angle is read off the clock rather than counted from when
/// the view appeared, so every spinner on screen turns in step — a sidebar of
/// them out of phase looks like a fault rather than like work.
struct WorkingSpinner: View {
    let tint: Color
    let diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let stepsPerTurn: Double = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.stepsPerTurn, paused: reduceMotion)) { context in
            Circle()
                .inset(by: lineWidth / 2)
                // Held still, an open ring looks like a spinner that has hung;
                // a closed one looks like what it is.
                .trim(from: 0, to: reduceMotion ? 1 : 0.75)
                .stroke(tint, lineWidth: lineWidth)
                .rotationEffect(reduceMotion ? .zero : Self.angle(at: context.date))
        }
        .frame(width: diameter, height: diameter)
    }

    private var lineWidth: CGFloat { max(1.5, diameter / 4.5) }

    nonisolated static func angle(at date: Date) -> Angle {
        let turn = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
        return .degrees((turn * stepsPerTurn).rounded(.down) * (360 / stepsPerTurn))
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
    private let leading: AnyView?
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
        leading = nil
        self.kind = kind
        self.action = action
    }

    /// For the buttons whose mark is a vendor logo rather than an SF Symbol.
    public init<Leading: View>(
        _ title: String,
        kind: RelayButtonStyleKind = .secondary,
        @ViewBuilder leading: () -> Leading,
        action: @escaping () -> Void
    ) {
        self.title = title
        systemImage = nil
        self.leading = AnyView(leading())
        self.kind = kind
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xsmall + 2) {
                if let leading {
                    leading
                } else if let systemImage {
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
        .clickable()
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
    private let isKeyboardFocused: Bool
    private let isEnabled: Bool
    private let respondsWhenDisabled: Bool
    private let isBusy: Bool
    private let tint: Color?
    private let action: () -> Void

    @State private var isHovering = false

    public init(
        systemImage: String,
        help: String = "",
        size: CGFloat = 24,
        prominence: Prominence = .standard,
        isSelected: Bool = false,
        /// The keyboard is on this control. Drawn as the pointer would draw it,
        /// because hover already teaches what "this is the one that will act"
        /// looks like — plus a ring, since a shade of grey on a near-black
        /// background is not an answer to "where am I".
        isKeyboardFocused: Bool = false,
        isEnabled: Bool = true,
        /// Keeps a dimmed control clickable. For one that is off because
        /// something was not found, where clicking is how you ask again.
        respondsWhenDisabled: Bool = false,
        /// Replaces the glyph with a spinner while the action is in flight.
        isBusy: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.help = help
        self.size = size
        self.prominence = prominence
        self.isSelected = isSelected
        self.isKeyboardFocused = isKeyboardFocused
        self.isEnabled = isEnabled
        self.respondsWhenDisabled = respondsWhenDisabled
        self.isBusy = isBusy
        self.tint = tint
        self.action = action
    }

    private var respondsToClicks: Bool { (isEnabled || respondsWhenDisabled) && !isBusy }

    public var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(size / 34)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.46, weight: .medium))
                }
            }
            .frame(width: size, height: size)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(isKeyboardFocused ? Theme.Palette.accent : .clear, lineWidth: 1)
            )
            // Without this the glyph itself is the target and the padding
            // around it does nothing, which makes small buttons feel broken.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Some of these answer a click while looking disabled — the Docker tab
        // that found nothing is asking to be tried again.
        .clickable(respondsToClicks)
        .disabled(!respondsToClicks)
        .onHover { isHovering = respondsToClicks && $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .animation(.easeOut(duration: 0.1), value: isKeyboardFocused)
        .help(help)
    }

    /// The keyboard counts as the pointer being here: one appearance for "this
    /// control is the one that will act", however you arrived at it.
    private var isPointedAt: Bool { isHovering || isKeyboardFocused }

    private var background: Color {
        guard isEnabled || respondsWhenDisabled else { return .clear }
        if isSelected { return isPointedAt ? Theme.Palette.surfaceHover : Theme.Palette.surfaceActive }
        return isPointedAt ? Theme.Palette.surfaceHover : .clear
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.Palette.textTertiary.opacity(0.4) }
        if let tint { return isPointedAt ? tint : tint.opacity(0.85) }
        if isSelected { return Theme.Palette.textPrimary }
        return isPointedAt ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
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
        .clickable()
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
    /// Takes the caret when it appears, for a panel whose whole purpose is
    /// the typing: a search that has to be clicked into first is a search
    /// that was opened by a shortcut and then abandoned.
    private let autofocus: Bool

    @FocusState private var isFocused: Bool

    public init(
        _ placeholder: String,
        text: Binding<String>,
        systemImage: String? = nil,
        autofocus: Bool = false,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.placeholder = placeholder
        _text = text
        self.systemImage = systemImage
        self.autofocus = autofocus
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
        .relayFieldPlate(isFocused: isFocused)
        .task { if autofocus { isFocused = true } }
    }
}

public extension View {
    /// The plate a text field sits on, so that every field in the window is
    /// the same object with the same edge lighting up under the caret.
    func relayFieldPlate(isFocused: Bool) -> some View {
        padding(.horizontal, Theme.Spacing.small + 2)
            .padding(.vertical, 7)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(isFocused ? Theme.Palette.accent.opacity(0.7) : Theme.Palette.border, lineWidth: 1)
            )
            // The field is the plate, not the run of glyphs inside it: clicking
            // the padding puts the caret in, so the padding has to say so too.
            .relayPointer(.text)
    }
}

/// A field holding one value that is applied when the typing is finished.
///
/// Apart from `RelayTextField`, which searches as it is typed into. A setting
/// cannot: a size applied per keystroke passes through 2 on the way to 20, and
/// every terminal in the window reflows twice for a number nobody meant. So it
/// is committed on Return — and on the caret leaving, because clicking away is
/// how half the people who type a number finish doing it.
public struct RelayValueField: View {
    private let placeholder: String
    @Binding private var text: String
    private let onCommit: () -> Void

    @FocusState private var isFocused: Bool

    public init(_ placeholder: String, text: Binding<String>, onCommit: @escaping () -> Void) {
        self.placeholder = placeholder
        _text = text
        self.onCommit = onCommit
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.Typography.row)
            .foregroundStyle(Theme.Palette.textPrimary)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .focused($isFocused)
            .onSubmit(onCommit)
            .onChange(of: isFocused) { _, hasCaret in if !hasCaret { onCommit() } }
            .relayFieldPlate(isFocused: isFocused)
    }
}

/// A name being edited in place.
///
/// Return and Escape already commit and cancel, but nothing on screen said so,
/// and an edit field with no visible way out reads as a trap. The buttons are
/// the affordance; the keys remain the shortcut.
public struct InlineRenameField: View {
    private let placeholder: String
    @Binding private var text: String
    private let allowsBlank: Bool
    private let onCommit: () -> Void
    private let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    /// `allowsBlank` is for text whose absence is an answer — a comment taken
    /// away — rather than a name, which cannot be nothing.
    public init(
        _ placeholder: String,
        text: Binding<String>,
        allowsBlank: Bool = false,
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.placeholder = placeholder
        _text = text
        self.allowsBlank = allowsBlank
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($isFocused)
                .onSubmit(commit)
                // On the field alone: the two buttons beside it are not text,
                // and a caret over a checkmark is a lie.
                .relayPointer(.text)

            IconButton(
                systemImage: "checkmark",
                size: 20,
                isEnabled: allowsBlank || !isBlank,
                tint: Theme.Palette.statusFinished,
                action: commit
            )
            IconButton(systemImage: "xmark", size: 20, action: onCancel)
        }
        .padding(.leading, Theme.Spacing.small + 2)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(isFocused ? Theme.Palette.accent.opacity(0.7) : Theme.Palette.border, lineWidth: 1)
        )
        // Renaming starts with the pointer, so the caret has to arrive without
        // a second click.
        .onAppear { isFocused = true }
        .onExitCommand(perform: onCancel)
    }

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit() {
        guard allowsBlank || !isBlank else { return }
        onCommit()
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
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            trailing.opacity(isHovering ? 1 : 0.35)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 2)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        // A header that collapses its section is a control; one that only
        // labels it is not, and must not claim to be.
        .clickable(onToggle != nil)
        .onHover { isHovering = $0 }
        .onTapGesture { onToggle?() }
    }
}

/// When a row's trailing controls are shown.
/// Keeps a control that only matters on hover in the layout at all times.
///
/// Inserting it when the pointer arrives reflows everything beside it, so the
/// row twitches under the cursor. The highlight is meant to be the only thing
/// that changes.
public struct HoverReveal<Content: View>: View {
    private let isVisible: Bool
    private let content: Content

    public init(isVisible: Bool, @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.content = content()
    }

    public var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

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

            HoverReveal(isVisible: isHovering || accessoryVisibility == .always) {
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
        .clickable()
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
    private let systemImage: String?
    private let tint: Color

    public init(_ text: String, systemImage: String? = nil, tint: Color = Theme.Palette.textTertiary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .medium))
            }
            Text(text)
        }
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

/// A row of selectable chips.
///
/// Stands in for `Picker` wherever the choice is short and visual. The native
/// pop-up and segmented controls carry their own appearance, which reads as
/// borrowed against a dark custom interface, and a menu hides the options
/// behind a click when there are only a handful.
public struct ChipPicker<Item: Hashable, Content: View>: View {
    private let items: [Item]
    @Binding private var selection: Item
    private let content: (Item, Bool) -> Content

    public init(
        items: [Item],
        selection: Binding<Item>,
        @ViewBuilder content: @escaping (Item, Bool) -> Content
    ) {
        self.items = items
        _selection = selection
        self.content = content
    }

    public var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132), spacing: Theme.Spacing.small)],
            alignment: .leading,
            spacing: Theme.Spacing.small
        ) {
            ForEach(items, id: \.self) { item in
                Chip(isSelected: item == selection) {
                    selection = item
                } content: {
                    content(item, item == selection)
                }
            }
        }
    }
}

public struct Chip<Content: View>: View {
    private let isSelected: Bool
    private let action: () -> Void
    private let content: Content

    @State private var isHovering = false

    public init(
        isSelected: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }

    public var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .animation(.easeOut(duration: 0.1), value: isSelected)
    }

    private var background: Color {
        if isSelected { return Theme.Palette.accentMuted }
        return isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surfaceRaised
    }

    private var border: Color {
        isSelected ? Theme.Palette.accent.opacity(0.7) : .clear
    }
}

// MARK: - Checkbox

/// A small square with a label, for the settings that come in sets.
///
/// A switch says "this feature is on"; a checkbox says "this one of several is
/// chosen", and a column of switches beside a list of flags is a column of
/// oversized furniture. Drawn rather than taken from AppKit so it sits at the
/// size the row needs and in the palette around it.
public struct RelayCheckbox<Label: View>: View {
    private let isOn: Bool
    private let action: () -> Void
    private let label: Label

    @State private var isHovering = false

    public init(isOn: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.small) {
                box
                label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isOn)
    }

    private var box: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(isOn ? Theme.Palette.accent : (isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surface))
            .frame(width: 15, height: 15)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(isOn ? Theme.Palette.accent : Theme.Palette.border, lineWidth: 1)
            )
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
    }
}

// MARK: - RelayTextEditor

/// Several lines of plain text, dressed as a `RelayTextField`.
///
/// For the places where the content is a small piece of a file rather than a
/// value: one directive per line, in the file's own words, so a form cannot
/// become a way of deleting what it has no field for.
public struct RelayTextEditor: View {
    private let placeholder: String
    @Binding private var text: String
    private let minHeight: CGFloat

    @FocusState private var isFocused: Bool

    public init(_ placeholder: String, text: Binding<String>, minHeight: CGFloat = 72) {
        self.placeholder = placeholder
        _text = text
        self.minHeight = minHeight
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.horizontal, Theme.Spacing.small + 2)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, Theme.Spacing.small - 2)
                .padding(.vertical, 4)
        }
        .frame(minHeight: minHeight, alignment: .topLeading)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(isFocused ? Theme.Palette.accent.opacity(0.7) : Theme.Palette.border, lineWidth: 1)
        )
        .relayPointer(.text)
    }
}
