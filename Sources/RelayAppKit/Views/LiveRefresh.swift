import SwiftUI

/// Keeps a panel true while it is being looked at.
///
/// Relay is told about what it starts itself and about nothing else. A
/// container started in Docker Desktop, a file written by an agent in a
/// terminal, a branch checked out by hand — all of it happens outside, and a
/// panel that reads the world when it opens is a panel showing what was true
/// when it opened, growing more confidently wrong the longer it stays up.
///
/// Tied to the view rather than to the model, which is what makes asking
/// repeatedly affordable: a panel nobody is looking at asks nothing. The ports
/// window had worked this way alone; everything else had to be told.
struct RefreshWhileVisible<ID: Equatable>: ViewModifier {
    /// Re-runs from the start when this changes — the selected project,
    /// usually, whose answer has nothing to do with the last one's.
    let id: ID
    let interval: Duration
    let refresh: () -> Void

    func body(content: Content) -> some View {
        content.task(id: id) {
            refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
    }
}

extension View {
    /// - Parameter interval: how stale the panel is allowed to be. Err towards
    ///   longer: each of these is a process being started.
    func refreshingWhileVisible<ID: Equatable>(
        id: ID,
        every interval: Duration,
        _ refresh: @escaping () -> Void
    ) -> some View {
        modifier(RefreshWhileVisible(id: id, interval: interval, refresh: refresh))
    }
}
