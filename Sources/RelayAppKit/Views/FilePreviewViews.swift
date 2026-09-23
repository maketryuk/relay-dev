import AppKit
import AVKit
import PDFKit
import RelayUI
import SwiftUI

/// A picture, fitted to the pane until somebody zooms it.
///
/// Pinch, ⌘+ and ⌘− zoom; a double click goes between fitting the pane and
/// the picture's own size, which is the pair of sizes anybody looking at a
/// picture keeps wanting.
struct ImagePreviewView: NSViewRepresentable {
    let image: NSImage
    let zoomRequest: FilePreview.ZoomRequest?
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> ImageScrollView {
        ImageScrollView()
    }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        view.onFocus = onFocus
        if view.image !== image { view.show(image) }
        if let zoomRequest, zoomRequest.id != view.appliedZoom {
            view.appliedZoom = zoomRequest.id
            view.apply(zoomRequest.zoom)
        }
    }
}

final class ImageScrollView: NSScrollView {
    var onFocus: (() -> Void)?
    var appliedZoom: UUID?

    private let imageView = NSImageView()
    /// True until the picture is zoomed by hand. While it holds, the picture
    /// follows the pane as it is resized, which is what fitting means.
    private var fitsPane = true

    var image: NSImage? { imageView.image }

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 32
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        backgroundColor = NSColor(Theme.Palette.base)

        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        documentView = imageView

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(doubleClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ image: NSImage) {
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        fitsPane = true
        fit()
    }

    func apply(_ zoom: FilePreview.Zoom) {
        switch zoom {
        case .zoomIn: scale(by: 1.25)
        case .zoomOut: scale(by: 1 / 1.25)
        case .fit:
            fitsPane = true
            fit()
        }
    }

    /// Where a scroll view learns it was resized, and so where a picture
    /// that fits the pane is fitted to its new size.
    override func tile() {
        super.tile()
        if fitsPane { fit() }
    }

    override func magnify(with event: NSEvent) {
        fitsPane = false
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        doubleClicked()
    }

    /// The size at which the whole picture is in view — and never larger than
    /// its own, because a 16-point icon blown up to fill a pane is a picture
    /// of the scaling rather than of the icon.
    private var fittingMagnification: CGFloat {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0 else { return 1 }
        let available = contentSize
        return min(1, available.width / size.width, available.height / size.height)
    }

    private func fit() {
        let fitting = fittingMagnification
        // Setting it lays the view out again, and the layout lands back here.
        guard abs(magnification - fitting) > 0.0001 else { return }
        magnification = fitting
    }

    private func scale(by factor: CGFloat) {
        fitsPane = false
        let visible = contentView.bounds
        setMagnification(magnification * factor, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
    }

    @objc private func clicked() {
        onFocus?()
    }

    @objc private func doubleClicked() {
        let fitting = fittingMagnification
        if fitsPane, fitting < 1 {
            fitsPane = false
            let visible = contentView.bounds
            setMagnification(1, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        } else {
            fitsPane = true
            fit()
        }
    }
}

/// Keeps a picture smaller than the pane in the middle of it rather than in
/// the corner a scroll view puts its document in.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let frame = documentView.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

/// A PDF, as PDFKit draws it: pages one under another, links that work, text
/// that can be selected and copied.
struct PDFPreviewView: NSViewRepresentable {
    let document: PDFDocument
    let zoomRequest: FilePreview.ZoomRequest?
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> FocusReportingPDFView {
        let view = FocusReportingPDFView()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.backgroundColor = NSColor(Theme.Palette.base)
        return view
    }

    func updateNSView(_ view: FocusReportingPDFView, context: Context) {
        view.onFocus = onFocus
        if view.document !== document { view.document = document }
        if let zoomRequest, zoomRequest.id != view.appliedZoom {
            view.appliedZoom = zoomRequest.id
            switch zoomRequest.zoom {
            case .zoomIn: view.zoomIn(nil)
            case .zoomOut: view.zoomOut(nil)
            case .fit: view.autoScales = true
            }
        }
    }
}

final class FocusReportingPDFView: PDFView {
    var onFocus: (() -> Void)?
    var appliedZoom: UUID?

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }
}

/// A video, or a recording with nothing to watch, with the system's own
/// controls. Nothing plays until it is asked to.
struct PlayerPreviewView: NSViewRepresentable {
    let player: AVPlayer
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> FocusReportingPlayerView {
        let view = FocusReportingPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: FocusReportingPlayerView, context: Context) {
        view.onFocus = onFocus
        if view.player !== player { view.player = player }
    }

    /// A player taken off screen is stopped, rather than left talking from a
    /// pane that is no longer there.
    static func dismantleNSView(_ view: FocusReportingPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}

final class FocusReportingPlayerView: AVPlayerView {
    var onFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }
}
