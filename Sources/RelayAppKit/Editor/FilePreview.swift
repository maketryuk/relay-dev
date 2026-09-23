import Foundation
import ImageIO
import Observation

/// A file open to be looked at rather than edited: a picture, a PDF, a
/// recording.
///
/// Kept apart from `OpenFile` because nothing about a buffer applies to it —
/// no text to save on losing focus, no caret, no checker — and a buffer with
/// an empty string in it would be answering every one of those questions
/// wrongly rather than not at all.
@MainActor
@Observable
final class FilePreview: @preconcurrency Identifiable {
    enum Kind: Equatable, Sendable {
        case image, pdf, video, audio

        /// What the file at this path is shown as, or nil for a file the
        /// editor opens as text.
        ///
        /// Read from a list of extensions rather than from the system's type
        /// tree, because the system answers a different question. It knows
        /// `.ts` as an MPEG transport stream and `.mts` as a camcorder's, so
        /// asking it whether a file is a video opens every TypeScript module
        /// in a player.
        ///
        /// SVG is left to the editor: it is an image, but it is also text a
        /// person writes, and in a project it is almost always opened to be
        /// changed.
        init?(path: String) {
            let pathExtension = (path as NSString).pathExtension.lowercased()
            guard let kind = Self.byExtension[pathExtension] else { return nil }
            self = kind
        }

        private static let byExtension: [String: Kind] = {
            var kinds: [String: Kind] = ["pdf": .pdf]
            for image in [
                "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif",
                "tif", "tiff", "bmp", "ico", "icns",
            ] {
                kinds[image] = .image
            }
            // Including what AVFoundation will not play: a WebM that says
            // plainly it cannot be played here, beside a way to open it in
            // something that can, is better than a toast saying the file could
            // not be opened at all.
            for video in ["mp4", "m4v", "mov", "webm", "mkv", "avi"] {
                kinds[video] = .video
            }
            for audio in ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "ogg"] {
                kinds[audio] = .audio
            }
            return kinds
        }()
    }

    /// Asked of the pane by ⌘+, ⌘− and ⌘0, which mean the picture here rather
    /// than the size of the text.
    enum Zoom: Equatable, Sendable {
        case zoomIn, zoomOut, fit
    }

    /// Carried as a request rather than as a level, for the reason a reveal
    /// is: pressing ⌘+ twice is two requests, and a pane comparing levels
    /// would take the second one for "nothing changed".
    struct ZoomRequest: Equatable {
        let id: UUID
        let zoom: Zoom
    }

    let path: String
    let kind: Kind
    /// Read once, on opening. Nothing watches the file yet, and a size that
    /// changed while the picture did not would be the one thing on screen
    /// that knew.
    let byteCount: Int64

    private(set) var zoomRequest: ZoomRequest?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    init?(path: String) {
        guard let kind = Kind(path: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        self.path = path
        self.kind = kind
        byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Whether the pane has anything to zoom. A player is the size it is
    /// given, and ⌘+ on it is better spent on nothing than on a surprise.
    var isZoomable: Bool { kind == .image || kind == .pdf }

    func zoom(_ zoom: Zoom) {
        guard isZoomable else { return }
        zoomRequest = ZoomRequest(id: UUID(), zoom: zoom)
    }
}

/// Reading a picture for its preview, off the main thread.
enum PreviewImage {
    /// A picture read far enough to be shown.
    ///
    /// `@unchecked` for the `CGImage`, which is immutable once made and which
    /// Core Graphics documents as safe to hand between threads; the rest is
    /// values.
    struct Decoded: @unchecked Sendable {
        /// The file as it is, for everything that fits: `NSImage` decodes it
        /// when it is drawn, and animates it when it is a GIF.
        let data: Data?
        /// A smaller copy, made instead of `data` for a picture too large to
        /// decode whole.
        let reduced: CGImage?
        let pixelWidth: Int
        let pixelHeight: Int
        /// In points, which is what `NSImage` measures in: a screenshot taken
        /// on a Retina screen says it is 144 dots to the inch and is half its
        /// pixels across.
        let size: CGSize
    }

    /// Past this, decoding the whole picture costs more memory than a
    /// preview is worth: 64 megapixels is a quarter of a gigabyte of bitmap,
    /// and a pane shows a fraction of it.
    static let largestDecodedPixels = 64 * 1024 * 1024
    /// The longer side of the copy made instead. Still more than a pane on
    /// any screen can show at the size that fits it.
    static let reducedSide = 8192

    static func read(path: String) -> Decoded? {
        guard let data = FileManager.default.contents(atPath: path),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }

        let dotsPerInch = (
            (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72,
            (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72
        )
        let size = CGSize(
            width: Double(width) * 72 / max(dotsPerInch.0, 1),
            height: Double(height) * 72 / max(dotsPerInch.1, 1)
        )

        let (pixels, overflowed) = width.multipliedReportingOverflow(by: height)
        guard overflowed || pixels > largestDecodedPixels else {
            return Decoded(data: data, reduced: nil, pixelWidth: width, pixelHeight: height, size: size)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: reducedSide,
        ]
        guard let reduced = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Decoded(data: nil, reduced: reduced, pixelWidth: width, pixelHeight: height, size: size)
    }
}

/// The line of facts a preview's header shows beside the file's name.
enum PreviewFacts {
    static func dimensions(width: Int, height: Int) -> String {
        "\(width) × \(height)"
    }

    /// `0:07`, `4:32`, `1:02:03`: the way every player writes a length.
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func joined(_ facts: [String?]) -> String {
        facts.compactMap { $0 }.joined(separator: " · ")
    }
}
