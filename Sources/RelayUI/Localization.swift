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

    /// What the picker calls it. A language is named in itself, so that it can
    /// be found by someone who cannot read the one on screen; "System" is not a
    /// language, and is named in the one the window speaks.
    @MainActor
    public var localizedName: String {
        self == .system ? relayLocalized("System") : displayName
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

    /// The locale numbers, dates and sizes are written in: the language of the
    /// words around them, which need not be the system's.
    ///
    /// `Locale.current` follows the Mac, so with Relay set to Russian on an
    /// English Mac a relative time said "2h ago" in the middle of Russian, and
    /// the other way round. The region is kept, so a clock still reads the way
    /// the Mac is set to.
    public var locale: Locale {
        let current = Locale.current
        let wanted = language.code ?? RelayUIResources.bundle.preferredLocalizations.first ?? "en"
        if current.language.languageCode?.identifier == wanted { return current }
        guard let region = current.region?.identifier else { return Locale(identifier: wanted) }
        return Locale(identifier: "\(wanted)_\(region)")
    }

    private init() {}
}

/// Relay's own resource bundle.
///
/// Exposed so tests can read the string tables that ship, rather than a copy
/// that quietly drifts from them.
public enum RelayUIResources {
    public static let bundle = resolved

    /// Found rather than trusted.
    ///
    /// `Bundle.module` traps when it cannot locate the resource bundle, and the
    /// first thing that asks for a string is the menu bar, built during
    /// `applicationWillFinishLaunching` — so an app that cannot find its string
    /// table does not start with English labels, it dies before it has a
    /// window, and the crash report blames a menu. The keys *are* the English
    /// text, so there is always something readable to fall back to.
    private static let resolved: Bundle = {
        let name = "Relay_RelayUI.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: BundleToken.self).resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: candidate.appendingPathComponent(name)) {
                return bundle
            }
        }
        return .main
    }()

    /// Only here to be asked which bundle it was compiled into.
    private final class BundleToken {}
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
    guard let code = language.code else { return RelayUIResources.bundle }
    if let cached = resolvedBundles[code] { return cached }

    guard let path = RelayUIResources.bundle.path(forResource: code, ofType: "lproj"),
          let bundle = Bundle(path: path)
    else { return RelayUIResources.bundle }
    resolvedBundles[code] = bundle
    return bundle
}

@MainActor
private var resolvedBundles: [String: Bundle] = [:]

// MARK: - Dates and sizes

/// A moment against now — "2h ago", "2 ч назад" — in the interface's language.
///
/// Russian gets the short style rather than the abbreviated one, which in
/// Russian comes out as "-2 ч": a negative number where "ago" should be. The
/// short style says "назад" and is nearly as brief as the English.
@MainActor
public func relayRelativeTime(_ date: Date, relativeTo now: Date) -> String {
    let locale = Localization.shared.locale
    if let formatter = relativeFormatters[locale.identifier] {
        return formatter.localizedString(for: date, relativeTo: now)
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = locale.language.languageCode == .russian ? .short : .abbreviated
    relativeFormatters[locale.identifier] = formatter
    return formatter.localizedString(for: date, relativeTo: now)
}

/// A time of day, written the way the interface's language writes one.
@MainActor
public func relayTime(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.shared.locale))
}

/// A size on disk. Not `ByteCountFormatter`, which takes its units from the
/// app bundle — English only — and so wrote "MB" into a Russian window.
@MainActor
public func relayByteCount(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file).locale(Localization.shared.locale))
}

/// Built once per locale: a formatter is costly to make, and these are asked
/// for by every row of a list on every redraw.
@MainActor
private var relativeFormatters: [String: RelativeDateTimeFormatter] = [:]
