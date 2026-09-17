import Foundation

/// Which context window a Claude session is running with.
///
/// Claude Code offers the long-context variants as models in their own right,
/// spelled with a bracketed suffix — `claude-opus-5[1m]` — and then records the
/// turn under the name *without* it. So the transcript, where every other
/// figure in the context reading comes from, is the one place that cannot
/// answer this question, and none of the CLI's live state says either: not the
/// session registry, not the cached utilisation `/usage` reads, not the
/// settings file.
///
/// What is left is stated intent and past fact. Intent, when Relay itself
/// launched the CLI with a model argument, is exact. Past fact — the models the
/// project's last finished session billed tokens against, which Claude Code
/// writes into `~/.claude.json` with the suffix intact — is evidence rather
/// than measurement, so it widens an inferred window and never overrides a
/// stated one.
enum ClaudeModelWindow {
    static let long = 1_000_000

    // MARK: - From a model identifier

    /// The window the name itself states, when it states one.
    static func declared(byModel model: String) -> Int? {
        guard let suffix = variantSuffix(of: model) else { return nil }
        return suffix.contains("1m") ? long : nil
    }

    /// The model without its variant suffix, which is how the transcript spells
    /// it and therefore the only form the two can be compared in.
    static func baseName(of model: String) -> String {
        guard let bracket = model.firstIndex(of: "[") else { return model }
        return String(model[model.startIndex ..< bracket])
    }

    private static func variantSuffix(of model: String) -> String? {
        guard let open = model.firstIndex(of: "["),
              let close = model.lastIndex(of: "]"),
              open < close
        else { return nil }
        return model[model.index(after: open) ..< close].lowercased()
    }

    // MARK: - From the command that started the session

    /// The window asked for by the command Relay ran.
    ///
    /// Exact when it is there: a session started as `claude --model
    /// claude-opus-5[1m]` is running that model whatever anything else on disk
    /// says. Both spellings of the flag are read, and the environment
    /// assignment that means the same thing.
    static func declared(byCommand command: [String]) -> Int? {
        var expectsModel = false
        for argument in command {
            if expectsModel {
                if let window = declared(byModel: argument) { return window }
                expectsModel = false
                continue
            }
            switch argument {
            case "--model", "-m":
                expectsModel = true
            default:
                for prefix in ["--model=", "ANTHROPIC_MODEL="] where argument.hasPrefix(prefix) {
                    if let window = declared(byModel: String(argument.dropFirst(prefix.count))) {
                        return window
                    }
                }
            }
        }
        return nil
    }

    // MARK: - From what the project last ran

    static var configurationURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    /// The window this project's last finished Claude session used for this
    /// model, if it used a long-context one.
    ///
    /// Matched on the base name, not merely on "something in this project was
    /// long-context": a project whose last session was `sonnet[1m]` says
    /// nothing about one running Opus today.
    static func lastUsed(
        forModel model: String,
        directory: String,
        configuration: URL? = nil
    ) -> Int? {
        let url = configuration ?? configurationURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        return lastUsed(forModel: model, directory: directory, configuration: data)
    }

    static func lastUsed(forModel model: String, directory: String, configuration data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any],
              let project = projects[directory] as? [String: Any],
              let usage = project["lastModelUsage"] as? [String: Any]
        else { return nil }

        let wanted = baseName(of: model)
        return usage.keys
            .filter { baseName(of: $0) == wanted }
            .compactMap { declared(byModel: $0) }
            .max()
    }
}
