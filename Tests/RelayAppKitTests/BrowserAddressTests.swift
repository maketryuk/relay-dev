import Foundation
import Testing

@testable import RelayAppKit

@Suite("Browser pane: the address field")
struct BrowserAddressTests {
    private func url(_ typed: String) -> String? {
        BrowserAddress.url(from: typed)?.absoluteString
    }

    @Test("A development server typed the short way is this machine, over http")
    func localServers() {
        #expect(url("localhost:5173") == "http://localhost:5173")
        #expect(url("localhost") == "http://localhost")
        #expect(url("127.0.0.1:8000/admin") == "http://127.0.0.1:8000/admin")
        #expect(url("0.0.0.0:3000") == "http://0.0.0.0:3000")
        #expect(url("[::1]:4000") == "http://[::1]:4000")
        #expect(url("app.localhost:3000") == "http://app.localhost:3000")
        #expect(url("shop.test") == "http://shop.test")
    }

    @Test("A machine on the private network is reached over http too")
    func privateNetwork() {
        #expect(url("192.168.1.20:8080") == "http://192.168.1.20:8080")
        #expect(url("10.0.0.5") == "http://10.0.0.5")
        #expect(url("172.20.1.1:5000") == "http://172.20.1.1:5000")
    }

    @Test("Anywhere else gets https")
    func publicHosts() {
        #expect(url("example.com") == "https://example.com")
        #expect(url("docs.swift.org/swift-book") == "https://docs.swift.org/swift-book")
        #expect(url("172.40.1.1") == "https://172.40.1.1")
    }

    @Test("An address that names its scheme is taken as it is")
    func explicitSchemes() {
        #expect(url("http://example.com") == "http://example.com")
        #expect(url("  https://localhost:5173/login  ") == "https://localhost:5173/login")
        #expect(url("about:blank") == "about:blank")
        #expect(url("chrome://gpu") == "chrome://gpu")
    }

    @Test("A path opens the file")
    func filePaths() {
        #expect(url("/tmp/report.html") == "file:///tmp/report.html")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(BrowserAddress.url(from: "~/page.html")?.path == home + "/page.html")
    }

    @Test("What reads as words is searched for")
    func searches() {
        #expect(url("how to center a div") == "https://www.google.com/search?q=how%20to%20center%20a%20div")
        #expect(url("swiftui") == "https://www.google.com/search?q=swiftui")
    }

    @Test("Nothing typed goes nowhere")
    func empty() {
        #expect(BrowserAddress.url(from: "   ") == nil)
    }

    @Test("The blank page shows as an empty field, so the placeholder can speak")
    func displaysBlankAsEmpty() {
        #expect(BrowserAddress.display("about:blank") == "")
        #expect(BrowserAddress.display("http://localhost:5173") == "http://localhost:5173")
    }
}
