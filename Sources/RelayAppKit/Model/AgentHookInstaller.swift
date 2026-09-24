import CryptoKit
import Foundation
import os
import RelayProtocol

/// Puts Relay's hook into Claude Code's and Codex's own settings, beside
/// whatever else is there.
///
/// The entry is the same wherever it is installed and whichever build installs
/// it: it names no path, and runs the helper the terminal names in
/// `RELAY_HOOK`. Outside a Relay terminal that is unset, and the entry drains
/// what the agent sent it and does nothing — which is how other tools'
/// entries behave beside it, and why one global entry is safe.
///
/// Every launch checks, and a file is written only when Relay's entry is
/// missing or out of date.
enum AgentHookInstaller {
    enum Outcome: Equatable {
        case installed
        case unchanged
        case skipped(String)
    }

    /// What makes an entry Relay's, in this build's spelling or an older one.
    static let marker = AgentHookEnvironment.helperKey
    /// Seconds. The helper takes milliseconds; this is for a machine that is
    /// on its knees, and the agent carries on either way.
    static let timeout = 10

    static func command(for agent: AgentHookEvent.Agent) -> String {
        // Claude reads a hook that prints nothing as one that refused.
        let otherwise = agent == .claude ? "cat >/dev/null; printf '{}\\n'" : "cat >/dev/null"
        return "if [ -x \"${\(marker):-}\" ]; then exec \"$\(marker)\" \(agent.rawValue); fi; \(otherwise)"
    }

    /// The events a status is made of, and the tools each one is asked about.
    static let claudeEvents: [(name: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PreToolUse", "*"),
        ("PostToolUse", "*"),
        ("PostToolUseFailure", "*"),
        ("PermissionRequest", "*"),
        ("Stop", nil),
        ("StopFailure", nil),
    ]

    /// Codex's names, and the labels its trust records use for them.
    static let codexEvents: [(name: String, label: String)] = [
        ("UserPromptSubmit", "user_prompt_submit"),
        ("PreToolUse", "pre_tool_use"),
        ("PermissionRequest", "permission_request"),
        ("PostToolUse", "post_tool_use"),
        ("Stop", "stop"),
    ]

    private static let log = Logger(subsystem: "com.maketryuk.relay", category: "agent-hooks")

    static func installAll(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let claude = installClaude(settings: home.appendingPathComponent(".claude/settings.json"))
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        let codex = installCodex(
            hooks: codexHome.appendingPathComponent("hooks.json"),
            config: codexHome.appendingPathComponent("config.toml")
        )
        log.info("Claude hooks: \(String(describing: claude), privacy: .public); Codex hooks: \(String(describing: codex), privacy: .public)")
    }

    // MARK: - Claude

    static func installClaude(settings url: URL) -> Outcome {
        rewriteJSON(at: url) { settings in
            merging(settings, command: command(for: .claude), events: claudeEvents)
        }
    }

    // MARK: - Codex

    /// Codex runs a hook only once it has been told to trust that exact entry,
    /// in its own config, by a hash of what it runs. The hash is Codex's, and
    /// is the one other tools write for their entries.
    static func installCodex(hooks hooksURL: URL, config configURL: URL) -> Outcome {
        let command = command(for: .codex)
        let hooks = rewriteJSON(at: hooksURL) { settings in
            merging(settings, command: command, events: codexEvents.map { ($0.name, nil) })
        }
        if case .skipped = hooks { return hooks }

        guard let text = try? String(contentsOf: hooksURL, encoding: .utf8),
              let settings = try? OrderedJSON.parse(text)
        else { return .skipped("hooks.json could not be read back") }
        let source = trustSourcePath(for: hooksURL)
        let entries: [(key: String, hash: String)] = codexEvents.compactMap { event in
            guard case let .array(groups)? = settings["hooks"]?[event.name],
                  let index = groups.lastIndex(where: { isRelayGroup($0, command: command) })
            else { return nil }
            return (
                "\(source):\(event.label):\(index):0",
                trustHash(label: event.label, command: command, timeout: timeout)
            )
        }

        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard let trusted = trusting(existing, entries: entries, source: source) else {
            return .skipped("config.toml defines hooks in a form this does not edit")
        }
        if trusted != existing {
            do {
                try write(trusted, to: configURL)
            } catch {
                return .skipped("config.toml: \(error.localizedDescription)")
            }
            return .installed
        }
        return hooks
    }

    /// `sha256` of the entry as Codex sees it: canonical JSON, keys sorted.
    static func trustHash(label: String, command: String, timeout: Int) -> String {
        let identity = "{\"event_name\":\(OrderedJSON.quoted(label)),\"hooks\":[{\"async\":false,"
            + "\"command\":\(OrderedJSON.quoted(command)),\"timeout\":\(max(1, timeout)),\"type\":\"command\"}]}"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Codex names a hooks file by its real folder and its own name.
    static func trustSourcePath(for hooksURL: URL) -> String {
        let folder = hooksURL.deletingLastPathComponent().path
        guard let resolved = realpath(folder, nil) else { return hooksURL.path }
        defer { free(resolved) }
        return String(cString: resolved) + "/" + hooksURL.lastPathComponent
    }

    /// The config with a trust record for each entry and no stale one of
    /// Relay's. Nil when the file defines hooks in a way a table added to it
    /// could clash with — Codex then asks about the hook itself.
    static func trusting(_ config: String, entries: [(key: String, hash: String)], source: String) -> String? {
        var lines = config.components(separatedBy: "\n")
        let isForeign = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: #"^(hooks\s*=|hooks\.|state\s*=)"#, options: .regularExpression) != nil
        }
        guard !isForeign else { return nil }

        let keys = Set(entries.map(\.key))
        let hashes = Set(entries.map(\.hash))
        let wanted = Dictionary(entries.map { ($0.key, $0.hash) }, uniquingKeysWith: { $1 })
        var present: [String: String] = [:]
        var index = 0
        while index < lines.count {
            guard let key = trustKey(inHeader: lines[index]), key.hasPrefix(source + ":") else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            let body = lines[(index + 1) ..< end]
            let hash = body.lazy.compactMap(trustedHash(in:)).first
            let isRelays = keys.contains(key) || hash.map(hashes.contains) == true
            guard isRelays else {
                index = end
                continue
            }
            // A table of Relay's with anything else in it is not one this
            // wrote, and removing half of it would leave the rest orphaned.
            let isOnlyTrust = body.allSatisfy { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || trustedHash(in: line) != nil
            }
            guard isOnlyTrust else { return nil }
            if let hash, wanted[key] == hash, present[key] == nil {
                present[key] = hash
                index = end
                continue
            }
            lines.removeSubrange(index ..< end)
        }

        var result = lines.joined(separator: "\n")
        let missing = entries.filter { present[$0.key] == nil }
        guard !missing.isEmpty else { return result }
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        for entry in missing {
            result += "\n[hooks.state.\(tomlQuoted(entry.key))]\ntrusted_hash = \(tomlQuoted(entry.hash))\n"
        }
        return result
    }

    private static func trustKey(inHeader line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "[hooks.state.\""
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("\"]") else { return nil }
        let quoted = trimmed.dropFirst(prefix.count).dropLast(2)
        return quoted.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func trustedHash(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.firstMatch(of: /^trusted_hash\s*=\s*"([^"]*)"$/) else { return nil }
        return String(match.1)
    }

    private static func tomlQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - The hooks object both agents use

    /// The settings with Relay's entry last under each event and nowhere else.
    ///
    /// Last, because both agents run every entry for an event and the order
    /// is theirs to choose; nowhere else, because an event a newer build no
    /// longer asks about must not keep calling the helper.
    static func merging(
        _ settings: OrderedJSON,
        command: String,
        events: [(name: String, matcher: String?)]
    ) -> OrderedJSON? {
        guard case .object = settings else { return nil }
        guard case let .object(existing) = settings["hooks"] ?? .object([]) else { return nil }

        // In place, so an event keeps its position in the file even when
        // Relay's was its only entry; emptied ones that are not asked for
        // again are dropped at the end.
        var emptied: Set<String> = []
        var hooks: [(key: String, value: OrderedJSON)] = existing.map { member in
            let cleaned = withoutRelay(member.value)
            if case let .array(before) = member.value, !before.isEmpty, case .array([]) = cleaned {
                emptied.insert(member.key)
            }
            return (member.key, cleaned)
        }
        for event in events {
            var group: [(key: String, value: OrderedJSON)] = []
            if let matcher = event.matcher { group.append(("matcher", .string(matcher))) }
            group.append(("hooks", .array([.object([
                ("type", .string("command")),
                ("command", .string(command)),
                ("timeout", .number(timeout)),
            ])])))
            let entry = OrderedJSON.object(group)
            if let index = hooks.firstIndex(where: { $0.key == event.name }) {
                guard case let .array(groups) = hooks[index].value else { return nil }
                hooks[index].value = .array(groups + [entry])
            } else {
                hooks.append((event.name, .array([entry])))
            }
            emptied.remove(event.name)
        }
        hooks.removeAll { emptied.contains($0.key) }
        return settings.setting("hooks", to: .object(hooks))
    }

    /// An event's groups without Relay's handlers, and without groups that
    /// held nothing else.
    private static func withoutRelay(_ value: OrderedJSON) -> OrderedJSON {
        guard case let .array(groups) = value else { return value }
        var kept: [OrderedJSON] = []
        for group in groups {
            guard case let .array(handlers)? = group["hooks"] else {
                kept.append(group)
                continue
            }
            let others = handlers.filter { !isRelayHandler($0) }
            if others.count == handlers.count {
                kept.append(group)
            } else if !others.isEmpty {
                kept.append(group.setting("hooks", to: .array(others)))
            }
        }
        return .array(kept)
    }

    private static func isRelayHandler(_ handler: OrderedJSON) -> Bool {
        handler["command"]?.stringValue?.contains(marker) == true
    }

    private static func isRelayGroup(_ group: OrderedJSON, command: String) -> Bool {
        guard case let .array(handlers)? = group["hooks"] else { return false }
        return handlers.contains { $0["command"]?.stringValue == command }
    }

    // MARK: - Files

    /// Reads, changes and writes back a JSON file in its own folder, which
    /// must exist: a folder that is not there is an agent that is not
    /// installed, and one it is not Relay's place to create.
    private static func rewriteJSON(at url: URL, change: (OrderedJSON) -> OrderedJSON?) -> Outcome {
        var isDirectory: ObjCBool = false
        let folder = url.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .skipped("\(folder) does not exist")
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let current: OrderedJSON
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current = .object([])
        } else {
            guard let parsed = try? OrderedJSON.parse(text) else {
                return .skipped("\(url.lastPathComponent) is not JSON Relay can read")
            }
            current = parsed
        }
        guard let changed = change(current) else {
            return .skipped("\(url.lastPathComponent) has hooks in a shape Relay does not edit")
        }
        guard changed != current else { return .unchanged }
        do {
            try write(changed.serialized() + "\n", to: url)
        } catch {
            return .skipped("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        return .installed
    }

    /// Atomically, and with the permissions the file already had: a settings
    /// file somebody made private stays private.
    private static func write(_ text: String, to url: URL) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try Data(text.utf8).write(to: url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }
}
