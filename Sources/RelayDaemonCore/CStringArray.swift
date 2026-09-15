import Darwin
import Foundation

/// A NULL-terminated `char *[]` built ahead of a `fork`.
///
/// Allocation must happen in the parent: between `fork` and `execve` only
/// async-signal-safe calls are legal, which rules out `malloc` and every Swift
/// allocation that hides behind it.
final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() {
            pointer[index] = strdup(string)
        }
        pointer[count] = nil
    }

    func deallocate() {
        for index in 0 ..< count {
            free(pointer[index])
        }
        pointer.deallocate()
    }
}
