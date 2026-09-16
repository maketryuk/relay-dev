import AppKit
import Foundation
import RelayProtocol
import RelayUI

/// Reads the image a project is drawn with.
///
/// Deliberately not part of the view: decoding a file is not something to do
/// while drawing, and the answer is the same for every tile until the project
/// changes.
enum ProjectIconLoader {
    /// Anything larger is a poster, not an icon, and nothing about a 44-point
    /// tile justifies decoding it.
    static let maximumBytes = 4 * 1024 * 1024

    /// The file to draw for a project: what the user chose, otherwise what the
    /// project carries, otherwise nothing.
    static func path(
        for project: Project,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        if let chosen = project.iconPath {
            // A chosen icon that has since been deleted falls back rather than
            // leaving the project blank.
            if ProjectIconLocator.isReadable(chosen), fileExists(chosen) { return chosen }
        }
        return ProjectIconLocator.icon(forProjectAt: project.rootPath, fileExists: fileExists)
    }

    /// The box an image actually draws inside, and how much of that box it
    /// fills.
    struct IconCoverage: Equatable {
        /// In rows and columns of the buffer, inclusive.
        var left: Int
        var right: Int
        var bottom: Int
        var top: Int
        /// What fraction of the box is drawn in, which is what tells an
        /// application icon from a line-art mark.
        var density: Double

        var width: Int { right - left + 1 }
        var height: Int { top - bottom + 1 }

        /// Square enough, and solid enough, to be a tile in its own right.
        ///
        /// An app icon's rounded square covers most of its box; a wordmark is
        /// nothing like square and a logo drawn in strokes covers a third of
        /// one. Neither of those can be its own tile.
        var isFullBleed: Bool {
            guard density >= 0.75 else { return false }
            let longer = Double(max(width, height))
            let shorter = Double(min(width, height))
            return shorter / longer >= 0.85
        }
    }

    /// Anything this faint is a shadow or an antialiased edge, not the mark.
    private static let alphaFloor: UInt8 = 24

    /// Measures an image's alpha, given row-major samples with row 0 at the
    /// bottom. Nil when nothing is drawn at all.
    ///
    /// Split out from the drawing so the arithmetic — which is where an
    /// off-by-one hides — can be tested without a bitmap.
    static func coverage(alpha: [UInt8], width: Int, height: Int) -> IconCoverage? {
        guard width > 0, height > 0, alpha.count == width * height else { return nil }

        var left = width, right = -1, bottom = height, top = -1
        var drawn = 0

        for row in 0 ..< height {
            for column in 0 ..< width where alpha[row * width + column] >= alphaFloor {
                drawn += 1
                if column < left { left = column }
                if column > right { right = column }
                if row < bottom { bottom = row }
                if row > top { top = row }
            }
        }

        guard right >= left, top >= bottom else { return nil }
        let area = (right - left + 1) * (top - bottom + 1)
        return IconCoverage(
            left: left,
            right: right,
            bottom: bottom,
            top: top,
            density: Double(drawn) / Double(area)
        )
    }

    /// Trims the empty margin off a project's artwork and says whether what is
    /// left can stand as a tile on its own.
    ///
    /// Two projects' marks agree on nothing: an application icon fills its
    /// canvas, and a logo exported for a readme carries a third of its width in
    /// empty space. Drawn at one size they are not one size, which is what the
    /// rail looked like.
    static func artwork(for image: NSImage) -> ProjectArtwork? {
        guard let source = bitmap(image),
              let coverage = coverage(of: source)
        else { return ProjectArtwork(image: image, isFullBleed: false) }

        // `cropping(to:)` counts from the top, the buffer from the bottom.
        let box = CGRect(
            x: coverage.left,
            y: source.height - coverage.top - 1,
            width: coverage.width,
            height: coverage.height
        )
        guard let cropped = source.cropping(to: box) else {
            return ProjectArtwork(image: image, isFullBleed: coverage.isFullBleed)
        }
        return ProjectArtwork(
            image: NSImage(cgImage: cropped, size: NSSize(width: box.width, height: box.height)),
            isFullBleed: coverage.isFullBleed
        )
    }

    /// Rasterises at a size worth measuring: an `.icns` carries several and an
    /// SVG carries none, and the smallest of either is too coarse to find an
    /// edge in.
    private static func bitmap(_ image: NSImage) -> CGImage? {
        var proposed = CGRect(x: 0, y: 0, width: 256, height: 256)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    private static func coverage(of source: CGImage) -> IconCoverage? {
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { return nil }

        let count = width * height * 4
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { bytes.deallocate() }
        bytes.initialize(repeating: 0, count: count)

        guard let context = CGContext(
            data: bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in 0 ..< width * height {
            alpha[index] = bytes[index * 4 + 3]
        }
        return coverage(alpha: alpha, width: width, height: height)
    }

    /// Reads the bytes, off whatever thread the caller is on.
    static func read(_ path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return data
    }
}
