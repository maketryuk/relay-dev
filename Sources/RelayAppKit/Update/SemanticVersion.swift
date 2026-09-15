import Foundation

/// A version as Relay writes them: `MAJOR.MINOR.PATCH`, optionally followed by a
/// pre-release tag.
///
/// Comparison has to understand that `0.1.0-dev` comes *before* `0.1.0`, because
/// that is exactly the pair the updater will meet first: a development build
/// looking at the release it was built towards. String comparison gets that
/// backwards, and numeric comparison of the three numbers alone calls them
/// equal.
struct SemanticVersion: Equatable, Comparable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int
    /// Empty for a final release.
    var preRelease: String

    init(major: Int, minor: Int, patch: Int, preRelease: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    /// Accepts a tag as well as a bare version, since a release names itself
    /// `v0.2.0` while the bundle says `0.2.0`.
    init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }

        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              let major = Int(numbers[0]),
              let minor = Int(numbers[1]),
              let patch = Int(numbers[2])
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        preRelease = parts.count > 1 ? String(parts[1]) : ""
    }

    var description: String {
        preRelease.isEmpty ? "\(major).\(minor).\(patch)" : "\(major).\(minor).\(patch)-\(preRelease)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A pre-release precedes the release it leads to; two pre-releases of
        // the same version fall back to their own order.
        switch (lhs.preRelease.isEmpty, rhs.preRelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): return lhs.preRelease < rhs.preRelease
        }
    }
}
