import Foundation
import Observation

/// Languages Relay ships.
public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Follows the system, which is what most people want and nobody has to set.
    case system
    case english
    case russian

    public var id: String { rawValue }

    /// Shown in its own language, the way every language picker should.
    public var displayName: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .russian: "Русский"
        }
    }

    var code: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .russian: "ru"
        }
    }
}

/// Holds the chosen language.
///
/// Observable so that changing it re-renders every view: `relayLocalized` reads
/// this property during body evaluation, which is enough for Observation to
/// register the dependency, so the interface switches language without a
/// restart.
@Observable
@MainActor
public final class Localization {
    public static let shared = Localization()

    public var language: AppLanguage = .system

    private init() {}
}

/// Relay's own resource bundle.
///
/// Exposed so tests can read the string tables that ship, rather than a copy
/// that quietly drifts from them.
public enum RelayUIResources {
    public static let bundle = Bundle.module
}

/// Looks a string up in Relay's tables.
///
/// The English text is the key, so a missing translation degrades to readable
/// English rather than to a raw identifier.
@MainActor
public func relayLocalized(_ key: String) -> String {
    let language = Localization.shared.language
    let bundle = Self_bundle(for: language)
    return bundle.localizedString(forKey: key, value: key, table: nil)
}

/// Every shipped wording of a key, the one on screen first.
///
/// What a search has to be matched against, because the interface speaks one
/// language and the person at the keyboard may well be thinking in the other:
/// someone running Relay in Russian still knows the command as "branch", and
/// typing it found nothing as long as only the visible label was searched.
@MainActor
public func relaySearchTerms(_ key: String) -> [String] {
    var terms = [relayLocalized(key)]
    for language in AppLanguage.allCases {
        guard language.code != nil else { continue }
        let wording = Self_bundle(for: language).localizedString(forKey: key, value: key, table: nil)
        if !terms.contains(wording) { terms.append(wording) }
    }
    return terms
}

/// Resolves the `.lproj` for an explicit language, falling back to the module
/// bundle so the system language applies on its own.
///
/// Cached, because this is called for every label on every redraw, and locating
/// an `.lproj` means a resource lookup and a bundle open each time — it showed
/// up as one of the most expensive things the interface did.
@MainActor
private func Self_bundle(for language: AppLanguage) -> Bundle {
    guard let code = language.code else { return .module }
    if let cached = resolvedBundles[code] { return cached }

    guard let path = Bundle.module.path(forResource: code, ofType: "lproj"),
          let bundle = Bundle(path: path)
    else { return .module }
    resolvedBundles[code] = bundle
    return bundle
}

@MainActor
private var resolvedBundles: [String: Bundle] = [:]
