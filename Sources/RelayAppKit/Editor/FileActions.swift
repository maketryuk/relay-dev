import AppKit
import Foundation

/// What the file tree can do to a file, and what it refuses to do.
///
/// Deliberately thin: a rename is a move, a new file is an empty file, and a
/// delete is the Trash. The one judgement in here is that last one — a tree
/// with a Delete in its menu is one slip away from losing an afternoon, and
/// macOS already has the place things go when somebody meant it.
enum FileActions {
    /// Said in English here and translated where it is shown, the way every
    /// other name below the interface is.
    enum Failure: Error, Equatable {
        case invalidName
        case alreadyExists(String)
    }

    /// A name with a separator in it is a path, and the two dot names are
    /// directions rather than names.
    static func isValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return false }
        return !trimmed.contains("/") && !trimmed.contains(":")
    }

    /// Renaming is a move inside the same folder. Returns where the file is now.
    @discardableResult
    static func rename(_ path: String, to name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(trimmed) else { throw Failure.invalidName }

        let destination = ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(trimmed)
        guard destination != path else { return path }
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw Failure.alreadyExists(trimmed)
        }

        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }

    /// To the Trash, where it can be got back.
    static func delete(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    @discardableResult
    static func create(_ name: String, in directory: String, isDirectory: Bool) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(trimmed) else { throw Failure.invalidName }

        let path = (directory as NSString).appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: path) else { throw Failure.alreadyExists(trimmed) }

        if isDirectory {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        } else {
            guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                throw Failure.invalidName
            }
        }
        return path
    }
}
