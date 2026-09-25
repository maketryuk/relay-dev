import Foundation

/// What each transcript said when it was last read, kept until it is written
/// to again.
///
/// The History tab lists a project's newest transcripts every ten seconds, and
/// reading the last half-megabyte of thirty of them and parsing every line
/// took a fifth of a second of CPU a time, for a list in which almost nothing
/// had changed since the last pass. The agents only ever append to their
/// transcripts, so the size and the modification date say whether one has
/// been written to, and asking for both is a fraction of a millisecond.
final class TranscriptReadings<Value: Sendable>: @unchecked Sendable {
    /// Enough to tell a transcript that has been written to from one that has
    /// not.
    struct Stamp: Equatable {
        var modifiedAt: Date?
        var size: Int?

        init(of url: URL) {
            // A `URL` keeps the values it was last asked for, and a stamp
            // taken from those would describe the file as it was then.
            var fresh = url
            fresh.removeAllCachedResourceValues()
            let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            modifiedAt = values?.contentModificationDate
            size = values?.fileSize
        }
    }

    private struct Reading {
        var stamp: Stamp
        var value: Value?
    }

    private let lock = NSLock()
    private var readings: [URL: Reading] = [:]

    /// What `read` made of the transcript, read again only if it has changed
    /// since. A transcript that made nothing is remembered as that.
    func value(of url: URL, reading read: (URL) -> Value?) -> Value? {
        let stamp = Stamp(of: url)
        if let reading = lock.withLock({ readings[url] }), reading.stamp == stamp {
            return reading.value
        }
        let value = read(url)
        lock.withLock { readings[url] = Reading(stamp: stamp, value: value) }
        return value
    }

    /// Forgets every transcript but these, so that what is kept is never more
    /// than one listing's worth.
    func keep(only urls: [URL]) {
        let listed = Set(urls)
        lock.withLock { readings = readings.filter { listed.contains($0.key) } }
    }

    var count: Int {
        lock.withLock { readings.count }
    }
}
