import Foundation

/// Why a tracker did not do what it was asked.
///
/// Kinds rather than sentences: the words are the app's, in the language the
/// window is in, and this module has no business knowing which that is. What
/// the tracker itself said travels alongside, because "the workflow does not
/// allow moving an issue to Done without a fix version" is the one part of an
/// error nobody but the tracker can write.
public struct TrackerError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The address is not one a token should be sent to.
        case invalidAddress
        /// Nothing answered.
        case unreachable
        case timedOut
        /// The address answers by sending the request somewhere else. Followed,
        /// it would carry the token to wherever that is.
        case redirected(to: String?)
        /// The token was refused.
        case unauthorized
        /// The account may not do this.
        case forbidden
        /// Not there, or not visible to this account — trackers do not say which.
        case notFound
        case rateLimited
        /// The tracker understood and said no: a field it will not take, a
        /// transition a workflow forbids.
        case rejected
        /// It failed on its side, and a read could be tried again.
        case serverFailure(status: Int)
        /// A change was sent and no answer came back, so it may or may not have
        /// been made. Never retried: doing it twice is worse than asking.
        case uncertain
        /// What answered is not the tracker's API: a login page, a proxy.
        case notTheAPI
    }

    public var kind: Kind
    /// What the tracker said, when it said anything.
    public var message: String?

    public init(_ kind: Kind, message: String? = nil) {
        self.kind = kind
        self.message = message
    }

    /// Whether asking again could come out differently.
    public var isTransient: Bool {
        switch kind {
        case .unreachable, .timedOut, .rateLimited, .serverFailure: true
        default: false
        }
    }
}
