import Foundation

/// Which build this is: the one that ships, or the one being worked on.
///
/// Both run on the same Mac at once, because the way to find out whether a
/// change is any good is to work in it. Everything that would let them reach
/// each other is keyed by this — the socket, the workspace, the log, and the
/// identity macOS hangs privacy permissions on.
///
/// Without it they share one daemon, and the client takes over a daemon whose
/// binary is not the one it shipped with. That is right for a single app and
/// ruinous for two: every rebuild of the development app would claim the daemon
/// the released one is using, and the sessions being worked in with it.
public enum RelayFlavour: String, Sendable, CaseIterable {
    case release
    case development

    public static let environmentKey = "RELAY_FLAVOUR"

    /// Read once, since nothing about it can change while the process runs.
    ///
    /// The app knows from its own bundle identifier. The daemon cannot: it is a
    /// bare executable inside `Contents/MacOS` with no identifier of its own,
    /// so the app that launches it says which build it belongs to.
    public static let current: RelayFlavour = resolve(
        environment: ProcessInfo.processInfo.environment[environmentKey],
        bundleIdentifier: Bundle.main.bundleIdentifier
    )

    /// Release is the answer when nothing says otherwise: a daemon started by
    /// hand, or a binary run straight out of the build directory, belongs to
    /// the ordinary app until something claims it.
    public static func resolve(environment: String?, bundleIdentifier: String?) -> RelayFlavour {
        if let named = environment.flatMap(named) { return named }
        if bundleIdentifier?.hasSuffix(".dev") == true { return .development }
        return .release
    }

    /// Lenient, because this is typed on a command line: `dev` is what anyone
    /// would write, and being right about the spelling is not the point.
    public static func named(_ value: String) -> RelayFlavour? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "dev", "development": .development
        case "release", "prod", "production": .release
        case "": nil
        default: nil
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .release: "com.maketryuk.relay"
        case .development: "com.maketryuk.relay.dev"
        }
    }

    /// What the app is called — in the Dock, and in Application Support.
    public var displayName: String {
        switch self {
        case .release: "Relay"
        case .development: "Relay Dev"
        }
    }

    /// The socket lives in a directory both builds share, so its name has to
    /// carry the difference.
    public var socketName: String {
        switch self {
        case .release: "relay"
        case .development: "relay-dev"
        }
    }

    /// What the directory under the home folder is called.
    ///
    /// A dotted name rather than the display one: everything in it is written
    /// by Relay for Relay, and a path a person types into a terminal — to read
    /// a log, to keep a chat note — should be short and lower case, the way
    /// every other tool of this kind names its own.
    public var supportDirectoryName: String {
        switch self {
        case .release: ".relay"
        case .development: ".relay-dev"
        }
    }

    /// A build being worked on has no business replacing itself with the one
    /// that shipped.
    public var allowsUpdates: Bool { self == .release }
}
