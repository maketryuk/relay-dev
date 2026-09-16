import SwiftUI

public enum ToastKind: Sendable, Hashable {
    case info
    case success
    case warning
    case error

    var tint: Color {
        switch self {
        case .info: Theme.Palette.statusWorking
        case .success: Theme.Palette.statusFinished
        case .warning: Theme.Palette.statusWaiting
        case .error: Theme.Palette.statusError
        }
    }

    var symbolName: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

/// A button offered by a toast.
///
/// Without one, a toast that reports a condition the user can do something
/// about — the daemon dropping, most obviously — leaves them with nothing to
/// press, which is worse than the banner it replaced.
public struct ToastAction: Sendable {
    public let title: String
    public let handler: @MainActor @Sendable () -> Void

    public init(title: String, handler: @escaping @MainActor @Sendable () -> Void) {
        self.title = title
        self.handler = handler
    }
}

public struct ToastContent: Identifiable, Sendable {
    public let id: UUID
    public let kind: ToastKind
    public let title: String
    public let message: String?
    /// Nil means it stays until dismissed — right for anything the user has to
    /// act on.
    public let duration: Duration?
    /// Groups repeats: a second toast with the same key replaces the first
    /// rather than stacking a duplicate.
    public let key: String?
    public let action: ToastAction?

    public init(
        kind: ToastKind,
        title: String,
        message: String? = nil,
        duration: Duration? = .seconds(5),
        key: String? = nil,
        action: ToastAction? = nil
    ) {
        id = UUID()
        self.kind = kind
        self.title = title
        self.message = message
        self.duration = duration
        self.key = key
        self.action = action
    }
}

extension ToastContent: Equatable {
    /// Identity is the whole comparison: a toast carries a closure, and two
    /// toasts are the same toast only if they are literally the same one.
    public static func == (lhs: ToastContent, rhs: ToastContent) -> Bool {
        lhs.id == rhs.id
    }
}

/// Bottom-right stack of transient messages.
public struct ToastStack: View {
    private let toasts: [ToastContent]
    private let onDismiss: (UUID) -> Void

    public init(toasts: [ToastContent], onDismiss: @escaping (UUID) -> Void) {
        self.toasts = toasts
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.small) {
            ForEach(toasts) { toast in
                ToastView(toast: toast) { onDismiss(toast.id) }
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.96))
                        )
                    )
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(!toasts.isEmpty)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: toasts.map(\.id))
    }
}

struct ToastView: View {
    let toast: ToastContent
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: toast.kind.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(toast.kind.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = toast.message {
                    Text(message)
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Theme.Spacing.small)

            if let action = toast.action {
                Button(action.title) {
                    action.handler()
                    onDismiss()
                }
                .buttonStyle(.plain)
                .clickable()
                .font(Theme.Typography.caption)
                .foregroundStyle(toast.kind.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(toast.kind.tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
            }

            IconButton(systemImage: "xmark", help: relayLocalized("Dismiss"), size: 16, action: onDismiss)
                .opacity(isHovering ? 1 : 0.4)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small + 2)
        .frame(width: 340, alignment: .leading)
        .background(Theme.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.Palette.borderStrong, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // A hairline in the status colour, so the kind reads before the text.
            Rectangle()
                .fill(toast.kind.tint)
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .padding(.vertical, Theme.Spacing.small)
        }
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .onHover { isHovering = $0 }
    }
}
