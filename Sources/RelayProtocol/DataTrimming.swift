import Foundation

public extension Data {
    /// Drops the first `count` bytes and lets go of the memory they took.
    ///
    /// `removeFirst` does not: on `Data` it only moves where the bytes start,
    /// and the storage behind them keeps everything before that point. A
    /// buffer fed at one end and trimmed at the other — a scrollback, the
    /// writes queued for a socket — held every byte that had ever passed
    /// through it while its `count` said it was small. `removeSubrange` lets
    /// go, but moves everything that is left each time, which for a queue
    /// drained a few kilobytes at a time is quadratic.
    ///
    /// So the front is still dropped by moving the start, and what is left is
    /// copied into storage of its own once the dropped part outweighs it:
    /// each byte kept is copied at most once for every byte dropped, and the
    /// storage never holds much more than twice what is still wanted.
    mutating func discardFirst(_ count: Int) {
        guard count < self.count else {
            removeAll()
            return
        }
        removeFirst(count)
        // A slice's indices are offsets into the storage it shares, so the
        // start is exactly how much dropped data is still being held.
        if startIndex > self.count {
            self = Data(self)
        }
    }
}
