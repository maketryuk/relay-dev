import Foundation
import RelayProtocol

/// Minimal append-only logger. The daemon has no window to print into, so this
/// file is the only way to diagnose a failed spawn.
public final class DaemonLog: @unchecked Sendable {
    public static let shared = DaemonLog()

    private let queue = DispatchQueue(label: "com.maketryuk.relay.log", qos: .utility)
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {}

    /// The destination is injectable so a test-hosted daemon does not append to
    /// the log the user reads when diagnosing their own machine.
    public func open(url: URL = RelayPaths.daemonLogURL) {
        queue.sync {
            try? RelayPaths.ensureDirectories()
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            if let descriptor = handle?.fileDescriptor {
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            }
            _ = try? handle?.seekToEnd()
            rotateIfNeeded(url: url)
        }
    }

    public func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            self?.handle?.write(data)
            FileHandle.standardError.write(data)
        }
    }

    private func rotateIfNeeded(url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 4 * 1024 * 1024 else { return }
        handle = nil
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }
}
