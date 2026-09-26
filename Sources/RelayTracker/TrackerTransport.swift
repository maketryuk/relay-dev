import Foundation

/// What carries a request to a tracker and brings back its answer.
///
/// A protocol so the one piece that needs a network can be swapped for a
/// test's canned answers; everything either side of it is pure.
public protocol TrackerTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: TrackerTransport {
    /// Ephemeral: nothing about a tracker is worth caching on disk, and a
    /// cookie from its web login has no place in requests made with a token.
    private static let session = URLSession(configuration: .ephemeral)

    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request, delegate: RedirectRefusal.shared)
        guard let http = response as? HTTPURLResponse else { throw TrackerError(.notTheAPI) }
        return (data, http)
    }
}

/// Answers every redirect with the redirect itself.
///
/// Following one would send the token wherever the server pointed, and a
/// tracker that redirects its API is almost always one typed with the wrong
/// address — which is better said than silently worked around.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectRefusal()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
