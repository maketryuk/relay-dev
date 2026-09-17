import SwiftUI

/// The frame every panel that opens over the window shares.
///
/// Header, body, and an optional footer, with one set of insets. These were
/// each built by hand and had drifted apart: the same dialog was tighter at the
/// top than at the bottom, and no two of them agreed with each other. A panel
/// should not be identifiable by its padding.
public struct ModalSurface<Content: View, Footer: View>: View {
    /// Generous and equal, top and bottom. A dialog crowded against its own
    /// edges reads as unfinished.
    public static var verticalInset: CGFloat { Theme.Spacing.xlarge }
    public static var horizontalInset: CGFloat { Theme.Spacing.large + Theme.Spacing.xsmall }
    /// The header and the footer are bars, not pages. Given the body's inset
    /// they came out nearly ninety points tall for one line of text and one
    /// button, which reads as a dialog with a wide empty band at each end.
    public static var barVerticalInset: CGFloat { Theme.Spacing.medium }

    private let title: String
    private let onDismiss: (() -> Void)?
    private let hasFooter: Bool
    private let content: Content
    private let footer: Footer

    public init(
        _ title: String,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) where Footer == EmptyView {
        self.title = title
        self.onDismiss = onDismiss
        hasFooter = false
        self.content = content()
        footer = EmptyView()
    }

    public init(
        _ title: String,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.onDismiss = onDismiss
        hasFooter = true
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RelayDivider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if hasFooter {
                RelayDivider()
                footer
                    .padding(.horizontal, Self.horizontalInset)
                    .padding(.vertical, Self.barVerticalInset)
            }
        }
        .background(Theme.Palette.base)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.small)
            if let onDismiss {
                IconButton(systemImage: "xmark", help: "") { onDismiss() }
            }
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, Self.barVerticalInset)
    }
}

public extension View {
    /// The rounded, bordered plate a modal sits on.
    func modalPlate() -> some View {
        clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 40, y: 16)
    }
}
