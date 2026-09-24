import CoreGraphics
import Foundation

enum DevToolsError: Error, Equatable {
    /// The protocol said no: a method the page does not have, parameters it
    /// would not take, a page that navigated while it was being asked.
    case refused(code: Int, message: String)
    /// The script ran and threw.
    case scriptFailed(String)
    /// There was no page to take the question.
    case unavailable
    /// The page went away with the question unanswered.
    case abandoned
    /// A reply without the shape that was asked for.
    case malformed
}

/// The DevTools protocol, as far as Relay speaks it: numbered requests out,
/// replies matched back to whoever asked.
///
/// This is the whole channel between Relay and the page: evaluating script,
/// taking a picture. It goes through the browser process, so nothing of
/// Relay's has to run inside the renderer.
///
/// Knows nothing about Chromium. What carries the bytes is handed in, which is
/// what lets the matching be tested without a browser.
@MainActor
final class DevToolsSession {
    /// Hands a message to the page, answering false when there is no page to
    /// take it.
    private let send: (Data) -> Bool
    private var nextIdentifier = 1
    private var waiting: [Int: CheckedContinuation<Data, any Error>] = [:]

    init(send: @escaping (Data) -> Bool) {
        self.send = send
    }

    /// Sends `method` and returns the whole reply, as the page sent it.
    func call(_ method: String, _ parameters: some Encodable) async throws -> Data {
        let identifier = nextIdentifier
        nextIdentifier += 1
        let request = try JSONEncoder().encode(Request(id: identifier, method: method, params: parameters))
        return try await withCheckedThrowingContinuation { continuation in
            waiting[identifier] = continuation
            if !send(request) {
                waiting.removeValue(forKey: identifier)
                continuation.resume(throwing: DevToolsError.unavailable)
            }
        }
    }

    func call<Result: Decodable>(
        _ method: String,
        _ parameters: some Encodable,
        returning _: Result.Type
    ) async throws -> Result {
        let reply = try await call(method, parameters)
        guard let decoded = try? JSONDecoder().decode(Reply<Result>.self, from: reply) else {
            throw DevToolsError.malformed
        }
        return decoded.result
    }

    /// A message from the page. A reply settles whoever is waiting for it;
    /// events are not listened for, and are dropped.
    func receive(_ message: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: message),
              let identifier = envelope.id,
              let continuation = waiting.removeValue(forKey: identifier)
        else { return }

        if let error = envelope.error {
            continuation.resume(throwing: DevToolsError.refused(code: error.code, message: error.message))
        } else {
            continuation.resume(returning: message)
        }
    }

    /// Settles every question still open. The page is gone, and no answer to
    /// any of them is coming.
    func abandonAll() {
        let abandoned = waiting
        waiting = [:]
        for continuation in abandoned.values {
            continuation.resume(throwing: DevToolsError.abandoned)
        }
    }

    var hasOpenQuestions: Bool { !waiting.isEmpty }

    // MARK: - The methods Relay uses

    /// Runs `expression` in the page and returns what it evaluated to, or nil
    /// for `undefined` and `null`.
    ///
    /// With `awaitingPromise`, a promise is waited for and its value returned,
    /// which is how design mode waits for a click without polling.
    func evaluate<Value: Decodable>(
        _ expression: String,
        awaitingPromise: Bool = false,
        as _: Value.Type
    ) async throws -> Value? {
        let evaluation = try await call(
            "Runtime.evaluate",
            Evaluate(expression: expression, awaitPromise: awaitingPromise),
            returning: Evaluation<Value>.self
        )
        if let exception = evaluation.exceptionDetails {
            throw DevToolsError.scriptFailed(exception.exception?.description ?? exception.text)
        }
        return evaluation.result?.value
    }

    /// A PNG of `clip`, in CSS pixels measured from the top of the document,
    /// at the display's own resolution.
    func screenshot(of clip: CGRect) async throws -> Data {
        let picture = try await call(
            "Page.captureScreenshot",
            Screenshot(clip: .init(clip)),
            returning: Picture.self
        )
        guard let data = Data(base64Encoded: picture.data) else { throw DevToolsError.malformed }
        return data
    }
}

// MARK: - Wire shapes

private struct Request<Parameters: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: Parameters
}

private struct Envelope: Decodable {
    struct Failure: Decodable {
        let code: Int
        let message: String
    }

    let id: Int?
    let error: Failure?
}

private struct Reply<Result: Decodable>: Decodable {
    let result: Result
}

private struct Evaluate: Encodable {
    let expression: String
    let awaitPromise: Bool
    let returnByValue = true
}

private struct Evaluation<Value: Decodable>: Decodable {
    struct Remote: Decodable {
        let value: Value?
    }

    struct Exception: Decodable {
        struct Thrown: Decodable {
            let description: String?
        }

        let text: String
        let exception: Thrown?
    }

    let result: Remote?
    let exceptionDetails: Exception?
}

private struct Screenshot: Encodable {
    struct Clip: Encodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let scale = 1.0

        init(_ rect: CGRect) {
            x = rect.minX
            y = rect.minY
            width = rect.width
            height = rect.height
        }
    }

    let format = "png"
    let clip: Clip
}

private struct Picture: Decodable {
    let data: String
}

/// Parameters for a method that takes none.
struct NoParameters: Encodable {}
