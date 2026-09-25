import AppKit
import AVFoundation
import PDFKit
import RelayProtocol
import RelayUI
import SwiftUI

/// A picture, a PDF or a recording open beside the terminals.
///
/// The same pane as a file's — the same header, the same place in the
/// arrangement, closed with the same key — showing the file rather than its
/// bytes.
struct FilePreviewPane: View {
    @Environment(AppModel.self) private var model
    let preview: FilePreview
    let projectID: ProjectID

    private enum Content {
        case image(NSImage, width: Int, height: Int)
        case document(PDFDocument)
        case player(AVPlayer, duration: Double?)
        case unplayable
        case unreadable
    }

    @State private var content: Content?

    var body: some View {
        VStack(spacing: 0) {
            FilePaneHeader(path: preview.path, projectID: projectID) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            } accessories: {
                Text(verbatim: facts)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)

                IconButton(systemImage: "arrow.up.forward.app", help: "", size: 20) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: preview.path))
                }
                .relayTooltip(relayLocalized("Open in Default App"))
            }
            RelayDivider()

            view(for: content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.base)
        .task(id: preview.path) { content = await Self.load(preview) }
    }

    @ViewBuilder
    private func view(for content: Content?) -> some View {
        let focus = { model.focusFile(at: preview.path) }
        switch content {
        case nil:
            ProgressView()
                .controlSize(.small)
        case let .image(image, _, _):
            ImagePreviewView(image: image, zoomRequest: preview.zoomRequest, onFocus: focus)
        case let .document(document):
            PDFPreviewView(document: document, zoomRequest: preview.zoomRequest, onFocus: focus)
        case let .player(player, _):
            if preview.kind == .audio {
                // A recording has nothing to watch, and a player the size of
                // the pane would be a black rectangle with a strip of
                // controls along its bottom edge.
                VStack(spacing: Theme.Spacing.large) {
                    Image(systemName: "waveform")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    PlayerPreviewView(player: player, onFocus: focus)
                        .frame(maxWidth: 480)
                        .frame(height: 56)
                }
                .padding(Theme.Spacing.xlarge)
            } else {
                PlayerPreviewView(player: player, onFocus: focus)
            }
        case .unplayable:
            EmptyStateView(
                systemImage: "play.slash",
                title: relayLocalized("Cannot be played here"),
                message: relayLocalized("macOS has no player for this format. Open it in the app it belongs to.")
            )
        case .unreadable:
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: relayLocalized("Cannot be shown"),
                message: relayLocalized("This file could not be read as what its name says it is.")
            )
        }
    }

    private var symbol: String {
        switch preview.kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "film"
        case .audio: "waveform"
        }
    }

    /// What there is to know about the file at a glance, beside its name.
    private var facts: String {
        let size = relayByteCount(preview.byteCount)
        switch content {
        case let .image(_, width, height):
            return PreviewFacts.joined([PreviewFacts.dimensions(width: width, height: height), size])
        case let .document(document):
            return PreviewFacts.joined([
                String(format: relayLocalized("Pages: %@"), "\(document.pageCount)"),
                size,
            ])
        case let .player(_, duration):
            return PreviewFacts.joined([duration.flatMap(PreviewFacts.duration), size])
        case nil, .unplayable, .unreadable:
            return size
        }
    }

    private static func load(_ preview: FilePreview) async -> Content {
        let url = URL(fileURLWithPath: preview.path)
        switch preview.kind {
        case .image:
            let path = preview.path
            let decoded = await Task.detached(priority: .userInitiated) { PreviewImage.read(path: path) }.value
            guard let decoded else { return .unreadable }
            let image: NSImage? = if let reduced = decoded.reduced {
                // Drawn at the size of the original, so that "actual size"
                // still means the picture's and not the copy's.
                NSImage(cgImage: reduced, size: decoded.size)
            } else {
                decoded.data.flatMap(NSImage.init(data:))
            }
            guard let image else { return .unreadable }
            return .image(image, width: decoded.pixelWidth, height: decoded.pixelHeight)

        case .pdf:
            return PDFDocument(url: url).map(Content.document) ?? .unreadable

        case .video, .audio:
            // Asked before a player is made, because a player given a WebM
            // says nothing at all: it shows a black frame and a play button
            // that does not work. Asked of an asset of its own, off the main
            // actor, so that nothing but the answer crosses back: an asset is
            // not something the compiler lets two threads share.
            let playable = await Task.detached(priority: .userInitiated) { () -> (Bool, Double?) in
                let asset = AVURLAsset(url: url)
                guard (try? await asset.load(.isPlayable)) == true else { return (false, nil) }
                return (true, (try? await asset.load(.duration)).map(CMTimeGetSeconds))
            }.value
            guard playable.0 else { return .unplayable }
            return .player(AVPlayer(url: url), duration: playable.1)
        }
    }
}
