import Foundation
import RelayProtocol

/// Keeps a bounded number of terminal renderers alive.
///
/// Its own object, and deliberately not part of the observable model: a view
/// body asks for a renderer while it is drawing, and anything the interface
/// watches must not change underneath it at that moment. When these lived on
/// the model as observed properties, that read-then-write invalidated the very
/// view that had just read it, and the window spun redrawing itself.
///
/// Evicting a renderer costs nothing the user can see — the session keeps
/// running in the daemon and comes back with its scrollback intact.
@MainActor
final class TerminalSurfaceCache {
    private let limit: Int
    private var surfaces: [SessionID: TerminalSurface] = [:]
    private var useOrder: [SessionID] = []

    init(limit: Int = 8) {
        self.limit = max(1, limit)
    }

    var cachedSessionIDs: [SessionID] { useOrder }

    func existing(_ sessionID: SessionID) -> TerminalSurface? {
        surfaces[sessionID]
    }

    /// Records that the user is looking at a session, so it is the last thing
    /// to be evicted.
    func touch(_ sessionID: SessionID) {
        guard surfaces[sessionID] != nil else { return }
        useOrder.removeAll { $0 == sessionID }
        useOrder.append(sessionID)
    }

    /// Adds a renderer and returns whatever had to be dropped to make room.
    ///
    /// `keeping` is the session on screen; evicting that one would tear down the
    /// terminal the user is typing into.
    func store(_ surface: TerminalSurface, for sessionID: SessionID, keeping pinned: SessionID?) -> [SessionID] {
        surfaces[sessionID] = surface
        useOrder.removeAll { $0 == sessionID }
        useOrder.append(sessionID)

        var evicted: [SessionID] = []
        var index = 0
        while useOrder.count > limit, index < useOrder.count {
            let candidate = useOrder[index]
            guard candidate != pinned, candidate != sessionID else {
                index += 1
                continue
            }
            useOrder.remove(at: index)
            surfaces.removeValue(forKey: candidate)
            evicted.append(candidate)
        }
        return evicted
    }

    /// Returns true when there was something to release.
    @discardableResult
    func remove(_ sessionID: SessionID) -> Bool {
        useOrder.removeAll { $0 == sessionID }
        return surfaces.removeValue(forKey: sessionID) != nil
    }

    func removeAll() {
        surfaces.removeAll()
        useOrder.removeAll()
    }
}
