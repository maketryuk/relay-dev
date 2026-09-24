import AppKit
import RelayUI
import SwiftUI

/// A browser tab in the sidebar, drawn the way a session is: what it is, what
/// it is doing, and the way to close it.
struct BrowserTabRow: View {
    @Environment(AppModel.self) private var model
    let page: BrowserPage
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            glyph

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    Text(verbatim: page.name)
                        .font(Theme.Typography.row)
                        .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .relayTooltip(page.name, edge: .trailing)

                    Spacer(minLength: Theme.Spacing.xsmall)

                    HoverReveal(isVisible: isHovering) {
                        IconButton(systemImage: "xmark", help: "", size: 16) {
                            model.closeBrowser(page.id)
                        }
                        .relayTooltip(relayLocalized("Close Tab"), shortcut: model.binding(for: .closeSession))
                    }
                }
                Text(verbatim: activity)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 7)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(isSelected ? Theme.Palette.borderStrong : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .clickable()
        .onHover { isHovering = $0 }
        .onTapGesture { model.selectBrowser(page.id) }
        .contextMenu {
            Button(relayLocalized("Reload")) { page.reload() }
            if let url = externalURL {
                Button(relayLocalized("Open in Default Browser")) { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button(relayLocalized("Close")) { model.closeBrowser(page.id) }
        }
    }

    private var glyph: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "globe")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 22, height: 22)

            // Where design mode is on, the row says so: a click in that tab
            // picks an element rather than following a link.
            if page.isDesignModeOn {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(1.5)
                    .background(Circle().fill(Theme.Palette.accent))
                    .offset(x: 3, y: 2)
            }
        }
        .frame(width: 24, height: 24)
    }

    /// Where the tab is, without the scheme every one of them starts with.
    private var activity: String {
        if page.isLoading { return relayLocalized("Loading…") }
        guard let url = URL(string: page.address), let host = url.host else {
            return relayLocalized("Blank page")
        }
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path == "/" ? "" : url.path
        return host + port + path
    }

    private var externalURL: URL? {
        guard let url = URL(string: page.address), url.host != nil else { return nil }
        return url
    }

    private var background: Color {
        if isSelected { return Theme.Palette.surfaceActive }
        return isHovering ? Theme.Palette.surfaceHover : .clear
    }
}
