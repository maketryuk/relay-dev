import AppKit
import Foundation
import RelayProtocol
import UserNotifications

/// Presents attention events as macOS notifications.
///
/// Authorisation is requested lazily on the first event that would actually be
/// shown, so a user who never triggers one is never prompted.
@MainActor
final class AttentionNotifier {
    private var hasRequestedAuthorisation = false
    private var isAuthorised = false
    /// Notification centre is unavailable to a process with no bundle
    /// identifier, which is how the app runs under `swift run` and in tests.
    private let isSupported: Bool

    init() {
        isSupported = Bundle.main.bundleIdentifier != nil
    }

    func present(_ event: AttentionEvent) {
        guard isSupported else { return }
        Task { await deliver(event) }
    }

    private func deliver(_ event: AttentionEvent) async {
        let center = UNUserNotificationCenter.current()

        if !hasRequestedAuthorisation {
            hasRequestedAuthorisation = true
            isAuthorised = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard isAuthorised else { return }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        // Only a blocked agent is worth a sound; completions stay silent.
        content.sound = event.kind == .waitingForInput ? .default : nil
        content.userInfo = ["sessionID": event.sessionID.rawValue]

        let request = UNNotificationRequest(
            identifier: "\(event.kind.rawValue)-\(event.sessionID.rawValue)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
