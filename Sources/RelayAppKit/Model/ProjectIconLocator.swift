import Foundation

/// Finds an image a project already carries, to use as its tile.
///
/// A repository nearly always ships its own mark somewhere — a favicon, an app
/// icon, a logo in the readme's folder — and it identifies the project far
/// better than two letters over a colour derived from its path.
///
/// The list is ordered by how much the file is *meant* to be the project's mark,
/// not by how convenient it is to find: a Next.js `app/icon.png` is deliberate,
/// while a stray `logo.png` at the root might be anything. The search stays
/// shallow and conventional for the same reason `ComposeLocator` does — walking
/// the tree would turn up a dependency's artwork and use it with total
/// confidence.
enum ProjectIconLocator {
    /// Relative paths, in order of preference.
    static let candidates = [
        // Next.js app router: these files exist to be the site's icon.
        "app/icon.png",
        "app/icon.svg",
        "app/apple-icon.png",
        "app/favicon.ico",
        "src/app/icon.png",
        "src/app/favicon.ico",

        // A native app's own icon, which is the project's mark by definition —
        // it is the thing the Dock shows. A repository that builds one is not a
        // site and has no favicon anywhere to find instead.
        "Resources/AppIcon.icns",
        "Resources/Icon.icns",
        "AppIcon.icns",
        "Icon.icns",

        // The conventional web roots.
        "public/apple-touch-icon.png",
        "public/favicon.svg",
        "public/favicon.png",
        "public/favicon.ico",
        "public/icon.png",
        "public/logo.png",
        "static/favicon.svg",
        "static/favicon.png",
        "static/favicon.ico",
        "static/icon.png",
        "assets/favicon.png",
        "assets/favicon.ico",
        "src/assets/favicon.png",
        "src/favicon.ico",
        "web/favicon.png",
        "Resources/icon.png",
        "Resources/icon.svg",
        "Resources/logo.png",
        "Resources/logo.svg",

        // Root, for sites served straight from the repository.
        "favicon.svg",
        "favicon.png",
        "favicon.ico",

        // A logo kept for the readme is usually the project's mark too.
        "logo.png",
        "logo.svg",
        "icon.png",
        "icon.svg",
        ".github/logo.png",
        "docs/logo.png",
        "docs/favicon.ico",
    ]

    /// Formats `NSImage` reads without help. SVG is included because macOS has
    /// rendered it since Big Sur, and a modern favicon is often nothing else.
    static let readableExtensions: Set<String> = ["png", "svg", "ico", "icns", "jpg", "jpeg", "tiff", "gif"]

    /// The icon to use for a project, or nil when it carries none.
    ///
    /// `fileExists` is a parameter so the search can be tested without laying
    /// out directories on disk.
    static func icon(
        forProjectAt root: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let base = URL(fileURLWithPath: root)
        for candidate in candidates {
            let path = base.appendingPathComponent(candidate).path
            if fileExists(path) { return path }
        }
        return nil
    }

    static func isReadable(_ path: String) -> Bool {
        readableExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}
