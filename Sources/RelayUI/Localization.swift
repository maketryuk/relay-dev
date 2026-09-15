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

/// Resolves the `.lproj` for an explicit language, falling back to the module
/// bundle so the system language applies on its own.
@MainActor
private func Self_bundle(for language: AppLanguage) -> Bundle {
    guard let code = language.code,
          let path = Bundle.module.path(forResource: code, ofType: "lproj"),
          let bundle = Bundle(path: path)
    else { return .module }
    return bundle
}
