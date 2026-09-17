import Foundation

/// `ForwardAgent` has three states, not two.
///
/// A block that says `no` is not the same as a block that says nothing: a
/// `Host *` above it may say `yes`, and a switch that cannot tell those apart
/// silently changes what a connection does.
enum SSHFlagValue: String, CaseIterable, Hashable, Sendable {
    case unset
    case yes
    case no

    var directiveValue: String? { self == .unset ? nil : rawValue }

    static func from(_ value: String?) -> SSHFlagValue {
        guard let value, let flag = SSHConfigParser.flag(value) else { return .unset }
        return flag ? .yes : .no
    }
}

/// A host as the editor holds it: text, because a form is text until it is
/// validated.
struct SSHHostDraft: Equatable, Sendable {
    var alias = ""
    var hostName = ""
    var user = ""
    var port = ""
    var identityFile = ""
    var proxyJump = ""
    var forwardAgent = SSHFlagValue.unset
    /// Everything Relay has no field for, one directive per line, written
    /// through untouched. Without it the editor would be a way of deleting the
    /// parts of a config it does not understand.
    var extraDirectives = ""

    /// Loads the block itself rather than the effective values: the editor
    /// writes to one block, so showing a value inherited from `Host *` would
    /// mean saving a copy of it into a block that never had it.
    init(editing host: SSHHost) {
        let directives = host.definitions.first?.directives ?? []
        alias = host.alias
        hostName = directives.value(of: "hostname") ?? ""
        user = directives.value(of: "user") ?? ""
        port = directives.value(of: "port") ?? ""
        identityFile = directives.value(of: "identityfile") ?? ""
        proxyJump = directives.value(of: "proxyjump") ?? ""
        forwardAgent = SSHFlagValue.from(directives.value(of: "forwardagent"))
        extraDirectives = directives
            .filter { !SSHConfigWriter.managesKeyword($0.keyword) }
            .map { "\($0.spelling) \($0.value)" }
            .joined(separator: "\n")
    }

    init() {}
}

private extension [SSHDirective] {
    func value(of keyword: String) -> String? {
        first { $0.keyword == keyword }?.value
    }
}

/// What stops a draft from being written.
enum SSHHostDraftProblem: Equatable, Sendable {
    case emptyAlias
    case aliasHasWhitespace
    case aliasIsPattern
    case aliasTaken
    case invalidPort
    case notADirective(String)
}

/// Rewrites `Host` blocks inside an OpenSSH configuration.
///
/// A config is written by hand and read by a person: its comments, the order of
/// its lines and the way its author spells `Hostname` are worth more than a tidy
/// file. So a block is patched line by line rather than regenerated, and only
/// what the form actually changed is rewritten.
enum SSHConfigWriter {
    /// The keywords the editor has a field for, spelled as `ssh_config(5)` does
    /// and in the order a new block writes them.
    static let managedKeywords = ["HostName", "User", "Port", "IdentityFile", "ProxyJump", "ForwardAgent"]

    static func managesKeyword(_ keyword: String) -> Bool {
        managedKeywords.contains { $0.lowercased() == keyword.lowercased() }
    }

    private static let defaultIndent = "    "

    // MARK: - Validation

    /// `takenAliases` is every alias already in the config, less the one being
    /// edited — an alias is only taken if somebody else has it.
    static func problem(with draft: SSHHostDraft, takenAliases: Set<String>) -> SSHHostDraftProblem? {
        let alias = draft.alias.trimmingCharacters(in: .whitespaces)
        if alias.isEmpty { return .emptyAlias }
        if alias.rangeOfCharacter(from: .whitespaces) != nil { return .aliasHasWhitespace }
        if alias.contains("*") || alias.contains("?") || alias.hasPrefix("!") { return .aliasIsPattern }
        if takenAliases.contains(alias) { return .aliasTaken }

        let port = draft.port.trimmingCharacters(in: .whitespaces)
        if !port.isEmpty, Int(port).map({ $0 < 1 || $0 > 65535 }) ?? true { return .invalidPort }

        for line in draft.extraDirectives.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#") else { continue }
            guard let parsed = SSHConfigParser.directive(in: text) else { return .notADirective(text) }
            // A second `Host` inside the block would silently start a new one.
            guard !["host", "match", "include"].contains(parsed.keyword.lowercased()) else {
                return .notADirective(text)
            }
        }
        return nil
    }

    // MARK: - Whole-file edits

    /// Adds the block at the end of the file, after a blank line.
    static func appending(_ draft: SSHHostDraft, to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append(contentsOf: rendered(draft))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Replaces the block occupying `range` with the draft, keeping every line
    /// the form did not touch.
    static func replacing(
        lines range: Range<Int>,
        in text: String,
        with draft: SSHHostDraft,
        previousAlias: String
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        guard range.lowerBound >= 0, range.upperBound <= lines.count, !range.isEmpty else { return text }
        let patched = patched(Array(lines[range]), with: draft, previousAlias: previousAlias)
        lines.replaceSubrange(range, with: patched)
        return lines.joined(separator: "\n")
    }

    /// Takes `alias` out of the block occupying `range`.
    ///
    /// A block naming other hosts as well loses only the one name: deleting the
    /// whole thing would delete them too, which is not what was asked for.
    static func removing(alias: String, atLines range: Range<Int>, from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard range.lowerBound >= 0, range.upperBound <= lines.count, !range.isEmpty else { return text }

        let header = lines[range.lowerBound]
        if let parsed = SSHConfigParser.directive(in: header) {
            let remaining = SSHConfigParser.patterns(in: parsed.value).filter { $0 != alias }
            if !remaining.isEmpty {
                lines[range.lowerBound] = indent(of: header) + parsed.keyword + " " + remaining.joined(separator: " ")
                return lines.joined(separator: "\n")
            }
        }

        let endedWithNewline = text.hasSuffix("\n")
        lines.removeSubrange(range)

        // A block taken out from between two blank lines leaves a gap twice the
        // size of the one that was there.
        let precedingIsBlank = range.lowerBound == 0
            || lines[range.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty
        if range.lowerBound < lines.count {
            if precedingIsBlank, lines[range.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.remove(at: range.lowerBound)
            }
        } else {
            // The last block in the file takes the blank line above it, and the
            // file goes on ending the way it ended before.
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            if endedWithNewline, !lines.isEmpty { lines.append("") }
        }
        return lines.joined(separator: "\n")
    }

    /// Adds directives a block does not already have, and leaves the ones it
    /// does have exactly as they were.
    ///
    /// For the settings that are nobody's host — the `Host *` defaults — where
    /// the point is to add what is missing without having an opinion about the
    /// rest of the block.
    static func ensuring(_ directives: [SSHDirective], inBlockAt range: Range<Int>, of text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard range.lowerBound >= 0, range.upperBound <= lines.count, !range.isEmpty else { return text }

        let block = Array(lines[range])
        let present = Set(block.compactMap { SSHConfigParser.directive(in: $0)?.keyword.lowercased() })
        let missing = directives.filter { !present.contains($0.keyword) }
        guard !missing.isEmpty else { return text }

        let indent = blockIndent(block)
        lines.insert(contentsOf: missing.map { indent + $0.spelling + " " + $0.value }, at: range.upperBound)
        return lines.joined(separator: "\n")
    }

    // MARK: - Rendering one block

    /// A block Relay writes from nothing, so it is written the way the manual
    /// spells it.
    static func rendered(_ draft: SSHHostDraft, indent: String = defaultIndent) -> [String] {
        var output = ["Host " + draft.alias.trimmingCharacters(in: .whitespaces)]
        for keyword in managedKeywords {
            guard let value = managedValue(of: keyword, in: draft) else { continue }
            output.append(indent + keyword + " " + value)
        }
        output.append(contentsOf: extraDirectives(in: draft).map { indent + $0.text })
        return output
    }

    /// A block that already exists, changed as little as the form allows.
    static func patched(_ original: [String], with draft: SSHHostDraft, previousAlias: String) -> [String] {
        guard !original.isEmpty else { return rendered(draft) }

        let indentation = blockIndent(original)
        var emitted: Set<String> = []
        var extras = extraDirectives(in: draft)
        var output: [String] = [hostLine(original[0], previousAlias: previousAlias, alias: draft.alias)]

        for line in original.dropFirst() {
            guard let parsed = SSHConfigParser.directive(in: line) else {
                // Blank lines and comments say something the form cannot.
                output.append(line)
                continue
            }
            let keyword = parsed.keyword.lowercased()

            if managesKeyword(keyword) {
                // A repeated keyword is dead weight: OpenSSH already ignored it.
                guard !emitted.contains(keyword) else { continue }
                guard let value = managedValue(of: keyword, in: draft) else { continue }
                emitted.insert(keyword)
                output.append(value == parsed.value ? line : indent(of: line) + parsed.keyword + " " + value)
            } else if let index = extras.firstIndex(where: { $0.keyword == keyword && $0.value == parsed.value }) {
                // Untouched in the free-text field, so it goes back verbatim,
                // trailing comment and odd spacing included.
                extras.remove(at: index)
                output.append(line)
            }
        }

        for keyword in managedKeywords where !emitted.contains(keyword.lowercased()) {
            guard let value = managedValue(of: keyword, in: draft) else { continue }
            output.append(indentation + keyword + " " + value)
        }
        output.append(contentsOf: extras.map { indentation + $0.text })
        return output
    }

    // MARK: - Pieces

    private struct ExtraDirective {
        var keyword: String
        var value: String
        var text: String
    }

    private static func extraDirectives(in draft: SSHHostDraft) -> [ExtraDirective] {
        draft.extraDirectives
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line in
                let text = String(line).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, let parsed = SSHConfigParser.directive(in: text) else { return nil }
                return ExtraDirective(keyword: parsed.keyword.lowercased(), value: parsed.value, text: text)
            }
    }

    private static func managedValue(of keyword: String, in draft: SSHHostDraft) -> String? {
        let text: String
        switch keyword.lowercased() {
        case "hostname": text = draft.hostName
        case "user": text = draft.user
        case "port": text = draft.port
        case "identityfile": text = draft.identityFile
        case "proxyjump": text = draft.proxyJump
        case "forwardagent": return draft.forwardAgent.directiveValue
        default: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hostLine(_ original: String, previousAlias: String, alias: String) -> String {
        let alias = alias.trimmingCharacters(in: .whitespaces)
        guard alias != previousAlias, let parsed = SSHConfigParser.directive(in: original) else { return original }
        let patterns = SSHConfigParser.patterns(in: parsed.value).map { $0 == previousAlias ? alias : $0 }
        return indent(of: original) + parsed.keyword + " " + patterns.joined(separator: " ")
    }

    /// How the block indents its directives, so an added line looks like the
    /// ones around it rather than like Relay.
    private static func blockIndent(_ lines: [String]) -> String {
        for line in lines.dropFirst() where SSHConfigParser.directive(in: line) != nil {
            let leading = indent(of: line)
            if !leading.isEmpty { return leading }
        }
        return defaultIndent
    }

    private static func indent(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }
}
