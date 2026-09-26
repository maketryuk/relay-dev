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
                    MarkdownText(IssueMarkdown.linkingAttachments(in: text) { target in
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
