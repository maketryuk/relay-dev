import Darwin
import Foundation
import RelayProtocol

/// One connected GUI client.
///
/// Lives entirely on `DaemonQueue.shared`.
final class ClientConnection: @unchecked Sendable {
    let id: UInt64
    let descriptor: Int32

    /// Output is only streamed for sessions the client explicitly attached to,
    /// so background sessions cost a hidden client nothing.
    var attachedSessions: Set<SessionID> = []
    var didHandshake = false

    private var accumulator = FrameAccumulator()
    private var pendingWrites = Data()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var isWriteSourceActive = false
    private var isClosed = false
    /// The descriptor is shared by both dispatch sources, so it may only be
    /// closed once *both* have finished cancelling.
    private var liveSourceCount = 0

    private let encoder = MessageFraming.makeEncoder()
    private let decoder = MessageFraming.makeDecoder()

    private let onMessage: (ClientConnection, ClientMessage) -> Void
    private let onClose: (ClientConnection) -> Void

    init(
        id: UInt64,
        descriptor: Int32,
        onMessage: @escaping (ClientConnection, ClientMessage) -> Void,
        onClose: @escaping (ClientConnection) -> Void
    ) {
        self.id = id
        self.descriptor = descriptor
        self.onMessage = onMessage
        self.onClose = onClose
    }

    deinit {
        // Releasing a suspended dispatch source traps in libdispatch.
        if let writeSource, !isWriteSourceActive {
            writeSource.resume()
        }
    }

    func start() {
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var noSigpipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let read = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DaemonQueue.shared)
        read.setEventHandler { [weak self] in self?.handleReadable() }
        read.setCancelHandler { [weak self] in self?.noteSourceCancelled() }
        readSource = read

        let write = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: DaemonQueue.shared)
        write.setEventHandler { [weak self] in self?.flushPendingWrites() }
        write.setCancelHandler { [weak self] in self?.noteSourceCancelled() }
        writeSource = write

        liveSourceCount = 2
        read.resume()
    }

    // MARK: - Sending

    func send(_ message: ServerMessage) {
        guard !isClosed else { return }
        guard let frame = try? MessageFraming.encode(message, using: encoder) else { return }
        pendingWrites.append(frame)
        flushPendingWrites()
    }

    private func flushPendingWrites() {
        guard !isClosed else { return }
        while !pendingWrites.isEmpty {
            let written = pendingWrites.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress, raw.count)
            }
            if written > 0 {
                pendingWrites.discardFirst(written)
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN {
                resumeWriteSource()
                return
            }
            close()
            return
        }
        suspendWriteSource()
    }

    private func resumeWriteSource() {
        guard !isWriteSourceActive else { return }
        isWriteSourceActive = true
        writeSource?.resume()
    }

    private func suspendWriteSource() {
        guard isWriteSourceActive else { return }
        isWriteSourceActive = false
        writeSource?.suspend()
    }

    // MARK: - Receiving

    private func handleReadable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                read(descriptor, pointer.baseAddress, pointer.count)
            }
            if count > 0 {
                accumulator.append(Data(buffer[0 ..< count]))
                continue
            }
            if count == 0 {
                deliverFrames()
                close()
                return
            }
            if errno == EINTR { continue }
            break
        }
        deliverFrames()
    }

    private func deliverFrames() {
        for frame in accumulator.drainFrames() {
            guard let message = try? decoder.decode(ClientMessage.self, from: frame) else {
                DaemonLog.shared.write("client \(id): dropped undecodable frame (\(frame.count) bytes)")
                continue
            }
            onMessage(self, message)
        }
    }

    // MARK: - Teardown

    func close() {
        guard !isClosed else { return }
        isClosed = true
        // A suspended source cannot be cancelled, so wake it up first.
        resumeWriteSource()
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()
        readSource = nil
    }

    private func noteSourceCancelled() {
        liveSourceCount -= 1
        guard liveSourceCount <= 0 else { return }
        Darwin.close(descriptor)
        onClose(self)
    }
}
