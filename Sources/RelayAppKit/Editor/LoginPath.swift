import Darwin
import Foundation

/// The `PATH` a terminal on this machine would have.
///
/// A GUI application is launched with `/usr/bin:/bin:/usr/sbin:/sbin` and
/// nothing else. Everything a developer actually installs — node through nvm,
/// php and shellcheck through Homebrew, ruff in a virtual environment — is
/// somewhere else entirely, and invisible to a process started from the Dock.
///
/// It is worse than not finding them: `node_modules/.bin/eslint` is a script
/// whose first line is `#!/usr/bin/env node`, so it does not even start, and
/// what comes back is nothing at all rather than an error. The linter looked
/// switched off.
///
/// The daemon routes every session through the login shell for this same
/// reason. This asks that shell once what its `PATH` is and keeps the answer
/// for as long as the app runs.
enum LoginPath {
    static let value: String = read()

    /// The environment a checker is run in: this process's, with a `PATH` a
    /// terminal would recognise.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = value
        return environment
    }

    /// Where a command-line tool is, as a terminal would find it.
    static func tool(named name: String, in value: String = LoginPath.value) -> String? {
        for directory in value.split(separator: ":") where !directory.isEmpty {
            let path = (String(directory) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// The marker is what separates the answer from everything an interactive
    /// shell prints on the way to giving it — a version notice, a greeting, a
    /// tool that announces itself.
    static let marker = "__relay_path__:"

    static func read() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell())
        // `-i` as well as `-l`, because `.zshrc` rather than `.zprofile` is
        // where nvm and mise are usually set up.
        process.arguments = ["-lic", "echo \(marker)$PATH"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return fallback
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return parse(String(decoding: data, as: UTF8.self)) ?? fallback
    }

    /// The shell the user actually uses.
    ///
    /// The daemon works this out the same way for the same reason; it is four
    /// lines, and the alternative is the app linking the daemon's core to
    /// read one of them.
    static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty,
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if let entry = getpwuid(getuid())?.pointee.pw_shell {
            let shell = String(cString: entry)
            if FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    static func parse(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix(marker) {
            let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
        return nil
    }

    /// What a login shell would give if it gave nothing: the places a Mac
    /// keeps tools, plus the one Homebrew uses on Apple silicon.
    static let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}
