import Foundation

/// ESLint kept warm.
///
/// A node process spends two thirds of a second before it lints anything:
/// starting, reading the config, loading the plugins. Paid per keystroke it
/// is the whole of the wait; paid once it is nothing. Measured on a real Nuxt
/// project: 0.92s for the first answer and 13–32ms for every one after it,
/// for checking and correcting alike.
///
/// This is what every editor that feels instant is doing. It is also what
/// `eslint_d` is, which is why that is preferred when a project has it — this
/// is the same idea for the projects that do not.
@MainActor
final class LintService {
    /// One process per project: ESLint is configured by the project it runs
    /// in, and a second project is a second configuration.
    private var instances: [String: Instance] = [:]
    /// Roots whose service could not be started. Remembered so that a broken
    /// config does not start a node process on every keystroke.
    private var refused: Set<String> = []
    private let node: String?

    init(node: String? = nil) {
        self.node = node
    }

    /// Whether this file is one the service can answer about.
    func supports(path: String, in root: String) -> Bool {
        guard !refused.contains(root) else { return false }
        guard FileCheckers.eslintExtensions.contains((path as NSString).pathExtension.lowercased())
        else { return false }
        return FileManager.default.fileExists(atPath: modulePath(in: root))
    }

    /// What ESLint says, and what it would correct when asked.
    ///
    /// Nil means the service could not answer — no node, no ESLint, a config
    /// it refuses to load, a process that died — and the caller falls back to
    /// running the command itself.
    func answer(for text: String, path: String, root: String, fix: Bool) async -> FileCheck.Fixed? {
        guard supports(path: path, in: root) else { return nil }

        guard let instance = instances[root] ?? start(root) else {
            refused.insert(root)
            return nil
        }
        guard let reply = await instance.ask(text: text, path: path, fix: fix) else {
            // It died, or took longer than anybody would wait. The next call
            // starts a fresh one rather than talking to a corpse.
            instances[root] = nil
            instance.stop()
            return nil
        }
        return reply
    }

    func stop(root: String) {
        instances[root]?.stop()
        instances[root] = nil
        refused.remove(root)
    }

    func stopAll() {
        for instance in instances.values { instance.stop() }
        instances = [:]
    }

    private func start(_ root: String) -> Instance? {
        guard let node = node ?? LoginPath.tool(named: "node"),
              let script = LintService.script
        else { return nil }

        let instance = Instance(node: node, script: script, module: modulePath(in: root), root: root)
        guard instance.start() else { return nil }
        instances[root] = instance
        return instance
    }

    private func modulePath(in root: String) -> String {
        (root as NSString).appendingPathComponent("node_modules/eslint")
    }

    /// The service written to a file once, because node runs files.
    private static let script: String? = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-eslint-service.js")
        guard (try? source.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url.path
    }()

    /// Newline-delimited JSON in, newline-delimited JSON out. Deliberately
    /// small: everything it knows about ESLint is that it has a class with a
    /// `lintText`, which is true of every version since 7.
    private static let source = """
    const [, , modulePath, cwd] = process.argv;
    let ESLint;
    try {
      ({ ESLint } = require(modulePath));
    } catch (error) {
      process.stdout.write(JSON.stringify({ ready: false, error: String(error) }) + "\\n");
      process.exit(1);
    }

    const instances = new Map();
    function instance(fix) {
      const key = fix ? "fix" : "plain";
      if (!instances.has(key)) instances.set(key, new ESLint({ cwd, fix }));
      return instances.get(key);
    }

    process.stdout.write(JSON.stringify({ ready: true }) + "\\n");

    let buffer = "";
    process.stdin.on("data", (chunk) => {
      buffer += chunk;
      let index;
      while ((index = buffer.indexOf("\\n")) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (line.trim()) handle(JSON.parse(line));
      }
    });

    async function handle(request) {
      try {
        const results = await instance(!!request.fix).lintText(request.text, {
          filePath: request.filePath,
          warnIgnored: false,
        });
        const first = results[0] || {};
        reply({ id: request.id, output: first.output, messages: first.messages || [] });
      } catch (error) {
        reply({ id: request.id, error: String((error && error.message) || error) });
      }
    }

    function reply(value) {
      process.stdout.write(JSON.stringify(value) + "\\n");
    }
    """
}

/// One project's service.
@MainActor
private final class Instance {
    private let node: String
    private let script: String
    private let module: String
    private let root: String

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let reader = Reader()
    /// Writes go on a queue of their own: a file larger than the pipe's
    /// buffer would otherwise block the window until node had read it.
    private let writes = DispatchQueue(label: "com.maketryuk.relay.lint")

    private var pending: [Int: CheckedContinuation<FileCheck.Fixed?, Never>] = [:]
    private var nextID = 0
    private var isRunning = false

    /// Long enough for the first answer, which loads the config and every
    /// plugin; anything past it is a service that is not coming back.
    private static let patience = Duration.seconds(20)

    init(node: String, script: String, module: String, root: String) {
        self.node = node
        self.script = script
        self.module = module
        self.root = root
    }

    func start() -> Bool {
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script, module, root]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.environment = LoginPath.environment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        reader.onLine = { [weak self] line in
            Task { @MainActor in self?.received(line) }
        }
        output.fileHandleForReading.readabilityHandler = { [reader] handle in
            reader.take(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            return false
        }
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        output.fileHandleForReading.readabilityHandler = nil
        process.terminate()
        for continuation in pending.values { continuation.resume(returning: nil) }
        pending = [:]
    }

    func ask(text: String, path: String, fix: Bool) async -> FileCheck.Fixed? {
        guard isRunning, process.isRunning else { return nil }

        nextID += 1
        let id = nextID
        let request: [String: Any] = ["id": id, "filePath": path, "text": text, "fix": fix]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Instance.patience)
            guard !Task.isCancelled else { return }
            self?.answer(id, with: nil)
        }
        defer { timeout.cancel() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending[id] = continuation
                let handle = input.fileHandleForWriting
                writes.async {
                    handle.write(data)
                    handle.write(Data("\n".utf8))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(id, with: nil) }
        }
    }

    private func received(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // The handshake, which says whether the project's ESLint could be
        // loaded at all.
        guard let id = json["id"] as? Int else { return }

        guard json["error"] == nil else { return answer(id, with: nil) }
        let messages = json["messages"] as? [[String: Any]] ?? []
        let diagnostics = DiagnosticParsing.eslint(messages: messages)
        answer(id, with: FileCheck.Fixed(text: json["output"] as? String, diagnostics: diagnostics))
    }

    private func answer(_ id: Int, with value: FileCheck.Fixed?) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: value)
    }
}

/// Splits what the service prints into lines, off the main thread.
private final class Reader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    var onLine: (@Sendable (String) -> Void)?

    func take(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []

        lock.lock()
        buffer.append(data)
        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< index]
            buffer = Data(buffer[buffer.index(after: index)...])
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        lock.unlock()

        for line in lines { onLine?(line) }
    }
}
