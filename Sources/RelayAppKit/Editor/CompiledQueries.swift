import Foundation
import SwiftTreeSitter

/// The compiled grammar queries, kept for as long as the process runs.
///
/// Compiling one is expensive — the bindings say so in as many words, and it
/// is not evenly spread: Swift's tags query takes nearly two seconds where
/// Go's takes a hundredth of one, because the analysis a query compiler does
/// grows with the grammar it is compiled against. Reading a project of Swift
/// files spent its whole time here and none of it parsing.
///
/// A compiled query is immutable and safe to share — `Query` is `Sendable` and
/// every execution makes its own cursor — so it is compiled once, by whoever
/// asks first, and handed to everybody afterwards.
final class CompiledQueries: @unchecked Sendable {
    static let shared = CompiledQueries()

    private let lock = NSLock()
    /// A missing file is remembered as such: most grammars have no injections
    /// and none of them grows one later.
    private var queries: [String: Query?] = [:]

    /// - Parameter make: called at most once for each key, and inside the lock
    ///   so that a second caller waits for the answer rather than paying for
    ///   it again. That is the case this exists for: a scan reads a project
    ///   across every core and they all want the same query at the same
    ///   moment.
    func query(_ key: String, make: () -> Query?) -> Query? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = queries[key] { return cached }
        let made = make()
        queries[key] = made
        return made
    }
}
