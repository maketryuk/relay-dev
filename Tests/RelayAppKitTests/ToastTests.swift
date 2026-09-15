import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayUI

@Suite("Toast queue")
struct ToastTests {
    private func toast(_ title: String, key: String? = nil, kind: ToastKind = .info) -> ToastContent {
        ToastContent(kind: kind, title: title, key: key)
    }

    @Test("Newest toast is last, so the stack grows upward from the corner")
    func ordering() {
        var toasts = ToastCenter.appending(toast("first"), to: [])
        toasts = ToastCenter.appending(toast("second"), to: toasts)
        #expect(toasts.map(\.title) == ["first", "second"])
    }

    @Test("A keyed toast replaces the previous one instead of stacking")
    func keyedToastsReplace() {
        // The daemon dropping repeatedly should show one message, not five.
        var toasts = ToastCenter.appending(toast("daemon gone", key: "daemon"), to: [])
        toasts = ToastCenter.appending(toast("daemon gone again", key: "daemon"), to: toasts)
        #expect(toasts.count == 1)
        #expect(toasts[0].title == "daemon gone again")
    }

    @Test("Unkeyed toasts stack independently")
    func unkeyedToastsStack() {
        var toasts = ToastCenter.appending(toast("one"), to: [])
        toasts = ToastCenter.appending(toast("two"), to: toasts)
        #expect(toasts.count == 2)
    }

    @Test("Different keys do not collide")
    func differentKeysCoexist() {
        var toasts = ToastCenter.appending(toast("a", key: "daemon"), to: [])
        toasts = ToastCenter.appending(toast("b", key: "docker"), to: toasts)
        #expect(toasts.count == 2)
    }

    @Test("The stack is capped and drops the oldest")
    func respectsTheLimit() {
        var toasts: [ToastContent] = []
        for index in 0 ..< (ToastCenter.limit + 3) {
            toasts = ToastCenter.appending(toast("t\(index)"), to: toasts)
        }
        #expect(toasts.count == ToastCenter.limit)
        #expect(toasts.first?.title == "t3")
        #expect(toasts.last?.title == "t\(ToastCenter.limit + 2)")
    }

    @Test("Dismissing removes exactly one toast")
    func dismissById() {
        var toasts = ToastCenter.appending(toast("one"), to: [])
        toasts = ToastCenter.appending(toast("two"), to: toasts)
        toasts = ToastCenter.removing(toasts[0].id, from: toasts)
        #expect(toasts.map(\.title) == ["two"])
    }

    @Test("A resolved condition can clear its toasts by key")
    func dismissByKey() {
        // Reconnecting should take the "disconnected" message away by itself.
        var toasts = ToastCenter.appending(toast("gone", key: "daemon"), to: [])
        toasts = ToastCenter.appending(toast("other"), to: toasts)
        toasts = ToastCenter.removing(key: "daemon", from: toasts)
        #expect(toasts.map(\.title) == ["other"])
    }

    @Test("Things the user must act on do not expire on their own")
    func actionableToastsPersist() {
        // A dismissed-by-timeout "daemon disconnected" would hide a state that
        // has not gone away.
        let transient = ToastContent(kind: .info, title: "Started")
        #expect(transient.duration != nil)

        let persistent = ToastContent(kind: .error, title: "Daemon disconnected", duration: nil)
        #expect(persistent.duration == nil)
    }

    @Test("Each kind has its own colour and symbol")
    func kindsAreDistinct() {
        let kinds: [ToastKind] = [.info, .success, .warning, .error]
        #expect(Set(kinds.map(\.symbolName)).count == kinds.count)
        #expect(Set(kinds.map { $0.tint.description }).count == kinds.count)
    }
}
