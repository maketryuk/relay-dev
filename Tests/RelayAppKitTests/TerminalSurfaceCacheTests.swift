import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Terminal surface cache")
@MainActor
struct TerminalSurfaceCacheTests {
    private let client = DaemonClient()

    private func session(_ name: String) -> SessionID {
        SessionID(rawValue: name)
    }

    private func surface(_ id: SessionID) -> TerminalSurface {
        TerminalSurface(sessionID: id, client: client)
    }

    @Test("A stored renderer comes back")
    func storesAndReturns() {
        let cache = TerminalSurfaceCache(limit: 4)
        let id = session("a")
        let stored = surface(id)

        #expect(cache.store(stored, for: id, keeping: nil).isEmpty)
        #expect(cache.existing(id) === stored)
        #expect(cache.existing(session("b")) == nil)
    }

    @Test("Past the limit the least recently seen renderer is dropped")
    func evictsTheOldest() {
        let cache = TerminalSurfaceCache(limit: 2)
        _ = cache.store(surface(session("a")), for: session("a"), keeping: nil)
        _ = cache.store(surface(session("b")), for: session("b"), keeping: nil)
        let evicted = cache.store(surface(session("c")), for: session("c"), keeping: nil)

        #expect(evicted == [session("a")])
        #expect(cache.existing(session("a")) == nil)
        #expect(cache.cachedSessionIDs == [session("b"), session("c")])
    }

    @Test("Looking at a session moves it out of the firing line")
    func touchProtectsTheRecentlyViewed() {
        let cache = TerminalSurfaceCache(limit: 2)
        _ = cache.store(surface(session("a")), for: session("a"), keeping: nil)
        _ = cache.store(surface(session("b")), for: session("b"), keeping: nil)
        cache.touch(session("a"))
        let evicted = cache.store(surface(session("c")), for: session("c"), keeping: nil)

        #expect(evicted == [session("b")])
        #expect(cache.existing(session("a")) != nil)
    }

    @Test("The session on screen is never evicted")
    func pinnedSessionSurvives() {
        // Tearing down the renderer the user is typing into would blank the
        // terminal in front of them to save memory they never asked to save.
        let cache = TerminalSurfaceCache(limit: 2)
        _ = cache.store(surface(session("a")), for: session("a"), keeping: nil)
        _ = cache.store(surface(session("b")), for: session("b"), keeping: nil)
        let evicted = cache.store(surface(session("c")), for: session("c"), keeping: session("a"))

        #expect(evicted == [session("b")])
        #expect(cache.existing(session("a")) != nil)
        #expect(cache.existing(session("c")) != nil)
    }

    @Test("Touching a session with no renderer changes nothing")
    func touchingAnUncachedSessionIsHarmless() {
        let cache = TerminalSurfaceCache(limit: 2)
        _ = cache.store(surface(session("a")), for: session("a"), keeping: nil)
        cache.touch(session("z"))
        #expect(cache.cachedSessionIDs == [session("a")])
    }

    @Test("Removing reports whether there was anything to release")
    func removeReportsWhatItDid() {
        let cache = TerminalSurfaceCache(limit: 2)
        _ = cache.store(surface(session("a")), for: session("a"), keeping: nil)

        #expect(cache.remove(session("a")))
        #expect(!cache.remove(session("a")))
        #expect(cache.cachedSessionIDs.isEmpty)
    }
}
