import Foundation

/// Whether one path lies inside another.
///
/// Shared by the ports list and Docker discovery: both have to answer "does
/// this belong to that project", and both have to get the sibling case right —
/// `shop-staging` is not inside `shop`.
enum DirectoryContainment {
    static func contains(_ path: String, in root: String) -> Bool {
        let normalise: (String) -> String = { value in
            let standardised = URL(fileURLWithPath: value).standardizedFileURL.path
            return standardised.hasSuffix("/") ? String(standardised.dropLast()) : standardised
        }
        let child = normalise(path)
        let parent = normalise(root)
        guard !parent.isEmpty, parent != "/" else { return false }
        return child == parent || child.hasPrefix(parent + "/")
    }
}
