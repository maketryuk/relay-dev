import Darwin
import Foundation
import RelayProtocol

/// Turns a `SessionSpec` into an executable launch plan.
///
/// Everything is routed through the user's login shell on purpose: agents like
/// `claude` and `codex` are usually installed by nvm, mise or Homebrew, and a
/// GUI-launched process does not inherit the PATH those tools rely on.
public enum LaunchPlanBuilder {
    public static func makePlan(for spec: SessionSpec) -> PTYProcess.LaunchPlan {
        let shell = loginShell()
        let directory = resolveDirectory(spec.workingDirectory)

        let arguments: [String]
        if spec.command.isEmpty {
            arguments = ["-l"]
        } else {
            // `-i` forces zsh/bash to read the interactive rc file, which is
            // where most developers actually export PATH.
            arguments = ["-lic", "exec " + spec.command.map(shellQuoted).joined(separator: " ")]
        }

        return PTYProcess.LaunchPlan(
            executable: shell,
            arguments: arguments,
            workingDirectory: directory,
            environment: makeEnvironment(extra: spec.environment),
            columns: spec.columns,
            rows: spec.rows
        )
    }

    public static func loginShell() -> String {
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

    private static func resolveDirectory(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func makeEnvironment(extra: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Relay"
        environment["RELAY_SESSION"] = "1"
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        // Inherited from the GUI process; meaningless and confusing in a child.
        environment.removeValue(forKey: "XPC_SERVICE_NAME")
        environment.removeValue(forKey: "XPC_FLAGS")
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }

    private static func shellQuoted(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,"))
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
