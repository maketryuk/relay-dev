import AppKit
import RelayTracker
import RelayUI
import SwiftUI

/// A person's picture from the tracker, and their initials until it arrives —
/// or for good, when the tracker has none worth drawing.
struct TrackerAvatar: View {
    @Environment(AppModel.self) private var model
    let name: String
    let avatar: String?
    var size: CGFloat = 20

    private var url: URL? { model.tracker.resolve(avatar) }

    var body: some View {
        Group {
            if let url, let image = model.tracker.images[url] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                PersonMark(name: name, size: size)
            }
        }
        .task(id: url) {
            if let url { await model.tracker.loadImage(at: url) }
        }
    }
}

/// A value as the tracker colours it — a priority, a state, a tag — in its
/// own fill and its own ink.
///
/// Both, because a tracker's palette keeps the hue in either one: YouTrack's
/// urgent is a red fill with white text, its critical a pale pink fill with
/// deep pink text. A tint taken from the fill alone drew the second almost
/// white, which is a priority nobody could tell apart from another.
struct TrackerChip: View {
    let text: String
    var systemImage: String?
    let color: TrackerColor?

    var body: some View {
        if let palette = Self.palette(for: color) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9, weight: .medium))
                }
                Text(verbatim: text)
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(palette.fill)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Badge(text, systemImage: systemImage, tint: Theme.Palette.textSecondary)
        }
    }

    /// The fill and the ink, or nil when the tracker gave no colour or one
    /// that is not a colour, which is drawn as a value with none.
    nonisolated static func palette(for color: TrackerColor?) -> (fill: Color, ink: Color)? {
        guard let color,
              let fill = Color.fromTrackerHex(color.background),
              let ink = Color.fromTrackerHex(color.foreground)
        else { return nil }
        return (fill, ink)
    }
}

/// Copies an issue's key and summary, the key a link, as the tracker's own
/// button beside the key does. Turns into a tick for a moment, since a copy
/// shows nothing anywhere else.
struct IssueCopyButton: View {
    @Environment(AppModel.self) private var model
    let key: String
    let summary: String
    var size: CGFloat = Theme.Metrics.action

    @State private var copied = false

    var body: some View {
        IconButton(systemImage: copied ? "checkmark" : "doc.on.doc", size: size) {
            model.copyIssueReference(key, summary: summary)
            copied = true
        }
        .relayTooltip(relayLocalized("Copy the ID and summary"))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// A picture from the tracker — an attachment, drawn where the text put it.
struct TrackerPicture: View {
    @Environment(AppModel.self) private var model
    let url: URL
    /// What the text asked for, in points; the picture's own width otherwise.
    var width: Double?
    var onOpen: () -> Void

    var body: some View {
        Group {
            if let image = model.tracker.images[url] {
                let natural = image.size.width
                let shown = min(CGFloat(width ?? natural), natural)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: shown, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .strokeBorder(Theme.Palette.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpen)
                    .clickable()
                    .relayTooltip(relayLocalized("Open the attachment"))
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Palette.surfaceRaised)
                    .frame(width: 160, height: 90)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: url) { await model.tracker.loadImage(at: url) }
    }
}

/// An issue's Markdown, with its pictures where it put them.
struct IssueText: View {
    @Environment(AppModel.self) private var model
    let source: String
    /// The issue the text is on, whose attachments it refers to by name.
    let issue: TrackerIssue

    private var tracker: TrackerController { model.tracker }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(Array(IssueMarkdown.segments(of: source).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(text):
                    RichMarkdownText(source: IssueMarkdown.linkingAttachments(in: text) { target in
                        issue.attachment(named: target).flatMap { tracker.resolve($0.url)?.absoluteString }
                    })
                case let .image(reference, width):
                    if let found = issue.attachment(named: reference), let url = tracker.resolve(found.url) {
                        TrackerPicture(url: url, width: width) { model.openAttachment(found) }
                    } else if let url = URL(string: reference), url.scheme?.hasPrefix("http") == true {
                        TrackerPicture(url: url, width: width) { NSWorkspace.shared.open(url) }
                    } else {
                        Label(reference, systemImage: "photo")
                            .font(Theme.Typography.rowSecondary)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
        }
    }
}

/// Every file on the issue: pictures as pictures, the rest by name.
struct AttachmentsSection: View {
    @Environment(AppModel.self) private var model
    let attachments: [TrackerAttachment]

    private var tracker: TrackerController { model.tracker }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: Theme.Spacing.small)],
            alignment: .leading,
            spacing: Theme.Spacing.small
        ) {
            ForEach(attachments) { attachment in
                Button { model.openAttachment(attachment) } label: { tile(attachment) }
                    .buttonStyle(.plain)
                    .clickable()
                    .relayTooltip(attachment.name)
            }
        }
    }

    private func tile(_ attachment: TrackerAttachment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Palette.surfaceRaised)
                if attachment.isImage, let url = tracker.resolve(attachment.thumbnail ?? attachment.url) {
                    AttachmentThumbnail(url: url)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .frame(height: 76)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            Text(verbatim: attachment.name)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct AttachmentThumbnail: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        Group {
            if let image = model.tracker.images[url] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) { await model.tracker.loadImage(at: url) }
    }
}
