import Foundation

/// Opaque, type-safe identifier. The phantom parameter prevents accidentally
/// passing a `ProjectID` where a `SessionID` is expected.
public struct Identifier<Subject>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> Identifier<Subject> {
        Identifier(rawValue: UUID().uuidString)
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public enum ProjectSubject: Sendable {}
public enum SessionSubject: Sendable {}
public enum ServiceSubject: Sendable {}

public typealias ProjectID = Identifier<ProjectSubject>
public typealias SessionID = Identifier<SessionSubject>
public typealias ServiceID = Identifier<ServiceSubject>
