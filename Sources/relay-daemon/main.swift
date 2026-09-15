import Darwin
import Foundation
import RelayDaemonCore
import RelayProtocol

// Terminal output written to a closed pipe must not take the daemon down.
signal(SIGPIPE, SIG_IGN)

// Detach from whoever launched us — usually the GUI. Without its own session
// the daemon would inherit the app's process group and die with it, which is
// precisely the failure mode the daemon exists to prevent.
if getpgrp() != getpid() {
    _ = setsid()
}

let server = DaemonServer()
server.onExitRequested = { exit(0) }

do {
    try server.start()
} catch let error as SocketListener.ListenError {
    switch error {
    case .alreadyRunning:
        FileHandle.standardError.write(Data("relay-daemon: already running\n".utf8))
        exit(0)
    default:
        FileHandle.standardError.write(Data("relay-daemon: \(error.description)\n".utf8))
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("relay-daemon: \(error)\n".utf8))
    exit(1)
}

// SIGTERM/SIGINT are handled through dispatch sources so cleanup runs on a real
// thread instead of inside an async-signal-unsafe handler.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        server.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
