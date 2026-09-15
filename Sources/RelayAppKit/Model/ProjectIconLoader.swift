import AppKit
import Foundation
import RelayProtocol

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
