import AppKit
import RelayProtocol
import RelayUI
import SwiftUI

/// A browser tab, beside the agent building what it shows.
///
/// A pane rather than a window of its own, for the reason a file is one: the
/// arrangement of panes is the arrangement of the work, and the page is half
/// of the loop design mode exists for — point at something, hand it to the
/// agent, watch it change.
struct BrowserPane: View {
    @Environment(AppModel.self) private var model
    let browserID: BrowserID

    var body: some View {
        if let page = model.browserPages[browserID] {
            BrowserPageView(page: page)
        } else {
            EmptyStateView(
                systemImage: "globe",
                title: relayLocalized("Tab unavailable"),
                message: relayLocalized("This tab has been closed.")
            )
            .background(Theme.Palette.base)
        }
    }
}

private struct BrowserPageView: View {
    @Environment(AppModel.self) private var model
    let page: BrowserPage

    /// What the address field holds while it is being typed in; the page's
    /// address otherwise.
    @State private var typed = ""
    @FocusState private var isAddressFocused: Bool

    private static let headerHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()
            if page.design == .picking || page.design == .capturing {
                designBanner
                RelayDivider()
            }
            ZStack(alignment: .bottom) {
                BrowserHostView(page: page) { model.focusBrowser(page.id) }
                if let problem = page.problem {
                    problemView(problem)
                }
                if case let .picked(selection) = page.design {
                    DesignPickCard(page: page, selection: selection)
                        .padding(Theme.Spacing.medium)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: page.design)
        }
        .background(Theme.Palette.base)
        .onAppear { typed = BrowserAddress.display(page.address) }
        .onChange(of: page.address) { _, address in
            // Somebody half-way through typing an address keeps what they
            // typed; the page moving under them is not a reason to lose it.
            if !isAddressFocused { typed = BrowserAddress.display(address) }
        }
        .onChange(of: isAddressFocused) { _, focused in
            if focused { model.focusBrowser(page.id) } else { typed = BrowserAddress.display(page.address) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            IconButton(systemImage: "chevron.left", size: Theme.Metrics.action, isEnabled: page.canGoBack) {
                page.goBack()
            }
            .relayTooltip(relayLocalized("Back"))

            IconButton(systemImage: "chevron.right", size: Theme.Metrics.action, isEnabled: page.canGoForward) {
                page.goForward()
            }
            .relayTooltip(relayLocalized("Forward"))

            IconButton(systemImage: page.isLoading ? "xmark" : "arrow.clockwise", size: Theme.Metrics.action) {
                page.isLoading ? page.stop() : page.reload()
            }
            .relayTooltip(
                page.isLoading ? relayLocalized("Stop") : relayLocalized("Reload"),
                shortcut: page.isLoading ? nil : model.binding(for: .reloadBrowser)
            )

            addressField
                .padding(.horizontal, Theme.Spacing.xsmall)

            IconButton(
                systemImage: "cursorarrow.rays",
                size: Theme.Metrics.action,
                prominence: .selectable,
                isSelected: page.isDesignModeOn
            ) {
                page.toggleDesignMode()
            }
            .relayTooltip(relayLocalized("Design Mode"), shortcut: model.binding(for: .toggleDesignMode))

            IconButton(systemImage: "wrench.and.screwdriver", size: Theme.Metrics.action) {
                page.showDevTools()
            }
            .relayTooltip(relayLocalized("Developer Tools"), shortcut: model.binding(for: .openBrowserDevTools))

            IconButton(systemImage: "arrow.up.forward.app", size: Theme.Metrics.action, isEnabled: externalURL != nil) {
                if let externalURL { NSWorkspace.shared.open(externalURL) }
            }
            .relayTooltip(relayLocalized("Open in Default Browser"))

            IconButton(systemImage: "xmark", size: Theme.Metrics.action) {
                model.closeBrowser(page.id)
            }
            .relayTooltip(relayLocalized("Close Tab"), shortcut: model.binding(for: .closeSession))
        }
        .padding(.horizontal, Theme.Spacing.small)
        .frame(height: Self.headerHeight)
        .background(Theme.Palette.sidebar)
    }

    private var addressField: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: page.isLoading ? "circle.dotted" : "globe")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField(relayLocalized("Address or search"), text: $typed)
                .textFieldStyle(.plain)
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($isAddressFocused)
                .onSubmit {
                    page.go(to: typed)
                    isAddressFocused = false
                }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 4)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(isAddressFocused ? Theme.Palette.accent.opacity(0.7) : Theme.Palette.border, lineWidth: 1)
        )
        .relayPointer(.text)
        .help(page.title)
    }

    private var externalURL: URL? {
        guard !page.address.isEmpty, page.address != "about:blank" else { return nil }
        return URL(string: page.address)
    }

    // MARK: - Design mode

    private var designBanner: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text(verbatim: page.design == .capturing
                ? relayLocalized("Reading the element…")
                : relayLocalized("Click an element to hand it to an agent. Esc stops."))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.small)
            Button(relayLocalized("Stop")) { page.stopDesignMode() }
                .buttonStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.accent)
                .clickable()
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 4)
        .background(Theme.Palette.accentMuted.opacity(0.5))
    }

    // MARK: - Problems

    @ViewBuilder
    private func problemView(_ problem: BrowserPage.Problem) -> some View {
        switch problem {
        case let .unavailable(reason):
            problemCard(
                systemImage: "globe",
                title: relayLocalized("Chromium is not available"),
                message: reason,
                action: externalURL.map { url in (relayLocalized("Open in Default Browser"), { NSWorkspace.shared.open(url) }) }
            )
        case let .loadFailed(failure):
            problemCard(
                systemImage: "exclamationmark.triangle",
                title: relayLocalized("Could not open the page"),
                message: failure.url.isEmpty ? failure.description : "\(failure.description)\n\(failure.url)",
                action: (relayLocalized("Try Again"), { page.reload() })
            )
        case .crashed:
            problemCard(
                systemImage: "exclamationmark.triangle",
                title: relayLocalized("The page stopped working"),
                message: relayLocalized("Its renderer quit. Reloading starts a new one."),
                action: (relayLocalized("Reload"), { page.reload() })
            )
        }
    }

    private func problemCard(
        systemImage: String,
        title: String,
        message: String,
        action: (String, () -> Void)?
    ) -> some View {
        VStack(spacing: Theme.Spacing.medium) {
            EmptyStateView(systemImage: systemImage, title: title, message: message)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                RelayButton(action.0, kind: .secondary, action: action.1)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.base)
    }
}

/// Hosts the page's view without letting SwiftUI recreate it, the way
/// `TerminalHostView` hosts a terminal.
private struct BrowserHostView: NSViewRepresentable {
    let page: BrowserPage
    /// Called when the page itself is clicked: it takes its own events, so a
    /// gesture laid over it would never hear the click.
    let onClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let container = FlippedContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0x08 / 255, green: 0x09 / 255, blue: 0x0A / 255, alpha: 1).cgColor
        container.onClick = onClick
        container.embed(page.chromium.view)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? FlippedContainerView else { return }
        container.onClick = onClick
        container.embed(page.chromium.view)
    }
}

/// What was picked, and the three things to do with it: hand it to an agent,
/// copy it, or let it go.
private struct DesignPickCard: View {
    @Environment(AppModel.self) private var model
    @Bindable var page: BrowserPage
    let selection: DesignSelection

    private var projectID: ProjectID { page.projectID }

    private var pick: DesignPick { selection.pick }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            thumbnail

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: headline)
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: whereItIs)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                RelayTextField(relayLocalized("What should change?"), text: $page.note, autofocus: true) {
                    sendToDefault()
                }

                HStack(spacing: Theme.Spacing.small) {
                    IconButton(systemImage: "doc.on.doc", size: Theme.Metrics.action) {
                        model.copy(selection, from: page)
                    }
                    .relayTooltip(relayLocalized("Copy for an agent"))

                    Spacer(minLength: Theme.Spacing.small)

                    RelayButton(relayLocalized("Discard"), kind: .ghost) { page.dismissPick() }

                    sendButton
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: 560)
        .background(Theme.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.Palette.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private var headline: String {
        let component = pick.component.map { "<\($0)>  " } ?? ""
        return component + pick.label
    }

    /// Where to go to change it: the file when the page knows it, the
    /// element's path when it does not.
    private var whereItIs: String {
        if let source = pick.source {
            return source.line.map { "\(source.file):\($0)" } ?? source.file
        }
        return pick.path.isEmpty ? pick.selector : pick.path
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = selection.screenshot, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 96, maxHeight: 72)
                .background(Theme.Palette.base)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                )
        } else {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 18))
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 48, height: 48)
                .background(Theme.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
    }

    private var agents: [SessionSnapshot] { model.agentsForReview(in: projectID) }
    private var defaultAgent: SessionSnapshot? { model.agentForReview(in: projectID) }
    private var agentPresets: [SessionPreset] { model.sessionPresets.filter(\.kind.isAgent) }

    @ViewBuilder
    private var sendButton: some View {
        if let agent = defaultAgent {
            HStack(spacing: 2) {
                RelayButton(String(format: relayLocalized("Send to %@"), model.label(for: agent)), systemImage: "paperplane", kind: .primary) {
                    model.send(selection, from: page, to: agent.id)
                }
                otherTargets
            }
        } else if let preset = agentPresets.first {
            HStack(spacing: 2) {
                RelayButton(String(format: relayLocalized("Send to a new %@"), preset.localizedName), systemImage: "paperplane", kind: .primary) {
                    model.send(selection, from: page, toNewSessionFrom: preset)
                }
                otherTargets
            }
        }
    }

    /// Every other place it could go, for when the agent it would go to is not
    /// the one that should have it.
    private var otherTargets: some View {
        Menu {
            let others = agents.filter { $0.id != defaultAgent?.id }
            if !others.isEmpty {
                Section(relayLocalized("Send to")) {
                    ForEach(others) { session in
                        Button(model.label(for: session)) { model.send(selection, from: page, to: session.id) }
                    }
                }
            }
            Section(relayLocalized("New agent")) {
                ForEach(agentPresets) { preset in
                    Button(preset.localizedName) { model.send(selection, from: page, toNewSessionFrom: preset) }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: Theme.Metrics.action, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Theme.Metrics.action)
        .clickable()
        .relayTooltip(relayLocalized("Send elsewhere"))
    }

    private func sendToDefault() {
        if let agent = defaultAgent {
            model.send(selection, from: page, to: agent.id)
        } else if let preset = agentPresets.first {
            model.send(selection, from: page, toNewSessionFrom: preset)
        }
    }
}
