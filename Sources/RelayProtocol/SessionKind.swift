import Foundation

/// A session type describes *how* to launch an interactive terminal entity and
/// which activity adapter interprets its output.
public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case shell
    case claude
    case codex
    case gemini
    case opencode
    case ssh
    case custom

    public var displayName: String {
        switch self {
        case .shell: "Terminal"
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .ssh: "SSH"
        case .custom: "Custom"
        }
    }

    /// SF Symbol used across the sidebar and the new-session menu.
    ///
    /// Each agent needs a glyph that cannot be confused with another's: the
    /// four-point sparkle reads as Gemini's mark, so it belongs to Gemini and
    /// nothing else. These evoke the tools rather than reproducing their
    /// trademarks, which Relay has no licence to ship.
    public var symbolName: String {
        switch self {
        case .shell: "terminal"
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gemini: "sparkle"
        case .opencode: "cube"
        case .ssh: "network"
        case .custom: "wrench.and.screwdriver"
        }
    }

    /// Accent used for the agent's glyph, so the sidebar is scannable by colour
    /// as well as by shape without turning the whole UI multicoloured.
    public var accentHex: UInt32 {
        switch self {
        case .claude: 0xD97757
        case .codex: 0xE8ECEE
        case .gemini: 0x6E8BF5
        case .opencode: 0x3FB950
        case .shell: 0x9BA3A8
        case .ssh: 0x58A6FF
        case .custom: 0x9BA3A8
        }
    }

    /// Default argv when the user does not override it. An empty array means
    /// "launch the user's login shell interactively".
    public var defaultCommand: [String] {
        switch self {
        case .shell: []
        case .claude: ["claude"]
        case .codex: ["codex"]
        case .gemini: ["gemini"]
        case .opencode: ["opencode"]
        case .ssh: ["ssh"]
        case .custom: []
        }
    }

    public var isQuickAction: Bool {
        switch self {
        case .claude, .codex, .shell: true
        default: false
        }
    }
}
