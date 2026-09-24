import CoreGraphics
import Foundation
import JavaScriptCore
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

/// What `DesignModeScript` returned for a button in a page with a React 18
/// tree, captured from Chromium 154. The page's address is swapped for a dev
/// server's, with the query and fragment an address really carries.
private let capturedButton = #"""
{
  "ancestors" : ["form", "main", "body"],
  "element" : {
    "attributes" : { "class" : "primary css-1x2y3z", "data-testid" : "save-button", "id" : "save", "type" : "submit" },
    "classes" : "primary css-1x2y3z",
    "components" : ["SettingsForm", "SaveButton"],
    "framework" : "React",
    "html" : "<button id=\"save\" class=\"primary css-1x2y3z\" type=\"submit\" data-testid=\"save-button\">Save changes</button>",
    "name" : "Save changes",
    "path" : "main > form.settings > #save",
    "rect" : { "height" : 31.5, "width" : 120.921875, "x" : 405.0078125, "y" : 40 },
    "role" : null,
    "selector" : "button#save",
    "source" : { "column" : 5, "exact" : true, "file" : "/Users/dev/app/src/components/SaveButton.tsx", "line" : 12 },
    "styles" : {
      "background-color" : "rgb(37, 99, 235)", "border" : "0px none rgb(255, 255, 255)", "border-radius" : "6px",
      "box-shadow" : "none", "color" : "rgb(255, 255, 255)", "display" : "block", "font-family" : "Arial",
      "font-size" : "13.3333px", "font-weight" : "600", "gap" : "normal", "height" : "31.5px",
      "line-height" : "normal", "margin" : "0px", "opacity" : "1", "padding" : "8px 16px", "position" : "static",
      "text-align" : "center", "width" : "120.922px", "z-index" : "auto"
    },
    "tag" : "button",
    "text" : "Save changes"
  },
  "nearby" : ["a: Docs", "label: Email"],
  "page" : {
    "devicePixelRatio" : 2,
    "scroll" : { "x" : 0, "y" : 120 },
    "title" : "Settings — Acme",
    "url" : "http://localhost:5173/settings?session_id=42#profile",
    "viewport" : { "height" : 640, "width" : 900 }
  }
}
"""#

private func decodePick(_ json: String) throws -> DesignPick {
    let reply = try JSONDecoder().decode(DesignPickReply.self, from: Data(json.utf8))
    guard case let .picked(pick) = reply else {
        Issue.record("expected a pick, got \(reply)")
        throw DevToolsError.malformed
    }
    return pick
}

@Suite("Design mode: what the page said")
struct DesignPickTests {
    @Test("A captured pick decodes into the element, its component and its source")
    func decodesCapturedPick() throws {
        let pick = try decodePick(capturedButton)

        #expect(pick.tag == "button")
        #expect(pick.selector == "button#save")
        #expect(pick.label == "button \"Save changes\"")
        #expect(pick.components == ["SettingsForm", "SaveButton"])
        #expect(pick.component == "SaveButton")
        #expect(pick.source == DesignPick.Source(
            file: "/Users/dev/app/src/components/SaveButton.tsx",
            line: 12,
            column: 5,
            isExact: true
        ))
        #expect(pick.rect.width == 120.921875)
        #expect(pick.styles.first?.name == "display")
    }

    @Test("The page's query and fragment are dropped even if the script let them through")
    func dropsQueryFromPageAddress() throws {
        // The script strips them itself; this is the side that does not trust
        // the script, since the page can replace anything it calls.
        let pick = try decodePick(capturedButton)
        #expect(pick.page.url == "http://localhost:5173/settings")
    }

    @Test("Every field is clamped again, whatever the page returned")
    func clampsOversizedFields() throws {
        let long = String(repeating: "x", count: 10_000)
        let json = """
        {"page": {"url": "http://localhost/"}, "element": {
          "tag": "div", "text": "\(long)", "html": "\(long)", "selector": "\(long)",
          "components": ["A1", "B2", "C3", "D4", "E5", "F6", "G7", "H8"],
          "rect": {"x": 0, "y": 0, "width": -40, "height": 10}
        }, "nearby": ["\(long)"]}
        """
        let pick = try decodePick(json)

        #expect(pick.text.count == 201)
        #expect(pick.html.count == 3001)
        #expect(pick.selector.count == 701)
        #expect(pick.components.count == 6)
        #expect(pick.nearby.first?.count == 161)
        #expect(pick.rect.width == 0)
    }

    @Test("Nothing picked comes back as the reason, not as an empty element")
    func cancellationDecodes() throws {
        let escape = try JSONDecoder().decode(DesignPickReply.self, from: Data(#"{"cancelled":"escape"}"#.utf8))
        let failure = try JSONDecoder().decode(DesignPickReply.self, from: Data(#"{"failed":"boom"}"#.utf8))
        #expect(escape == .cancelled("escape"))
        #expect(failure == .failed("boom"))
    }

    @Test("The picture is of the part on screen, measured from the top of the document")
    func visibleRectAddsScroll() throws {
        var pick = try decodePick(capturedButton)
        #expect(pick.visibleRectInDocument == CGRect(x: 405.0078125, y: 160, width: 120.921875, height: 31.5))

        // Taller than the window: only what can be seen can be photographed.
        pick.rect = CGRect(x: 0, y: -100, width: 900, height: 2000)
        #expect(pick.visibleRectInDocument == CGRect(x: 0, y: 120, width: 900, height: 640))

        pick.rect = CGRect(x: 0, y: 900, width: 100, height: 100)
        #expect(pick.visibleRectInDocument == nil)
    }
}

@Suite("Design mode: what the agent is handed")
struct DesignNoteTranscriptTests {
    @Test("The element, where it is written, and the request arrive together")
    func composesTranscript() throws {
        let pick = try decodePick(capturedButton)
        let screenshot = URL(fileURLWithPath: "/Users/dev/.relay/design/shot.png")
        let text = DesignNoteTranscript.compose(pick, note: "  match the cards above  ", screenshot: screenshot)
        let lines = text.components(separatedBy: "\n")

        #expect(lines.first == "Design feedback on http://localhost:5173/settings (Settings — Acme)")
        #expect(lines.contains("Element: <SaveButton> button \"Save changes\""))
        #expect(lines.contains("Source: /Users/dev/app/src/components/SaveButton.tsx:12:5"))
        #expect(lines.contains("Components (React): <SettingsForm> <SaveButton>"))
        #expect(lines.contains("Selector: button#save"))
        #expect(lines.contains("Size: 121×32 at 405, 40"))
        #expect(lines.contains("Screenshot: /Users/dev/.relay/design/shot.png"))
        #expect(lines.last == "User comment: \"match the cards above\"")
    }

    @Test("Only the styles that say something are listed")
    func filtersDefaultStyles() throws {
        let pick = try decodePick(capturedButton)
        let styles = DesignNoteTranscript.telling(pick.styles).map(\.name)

        #expect(styles.contains("padding"))
        #expect(styles.contains("background-color"))
        #expect(styles.contains("border-radius"))
        // Every element has these unless told otherwise, and Size already
        // gives width and height.
        for noise in ["position", "margin", "border", "box-shadow", "gap", "opacity", "z-index", "width", "height"] {
            #expect(!styles.contains(noise), "\(noise) should be left out")
        }
    }

    @Test("A line read off the dev server's copy says it may be off")
    func approximateSource() throws {
        var pick = try decodePick(capturedButton)
        pick.source = DesignPick.Source(file: "src/components/Card.tsx", line: 21, column: 7, isExact: false)
        let text = DesignNoteTranscript.compose(pick, note: "", screenshot: nil)

        #expect(text.contains("Source (line as the dev server serves it): src/components/Card.tsx:21\n"))
        #expect(!text.contains("User comment"))
        #expect(!text.contains("Screenshot:"))
    }

    @Test("Markup with backticks in it cannot close the fence around it")
    func fenceOutlastsMarkup() throws {
        var pick = try decodePick(capturedButton)
        pick.html = "<code>```swift</code>"
        let lines = DesignNoteTranscript.compose(pick, note: "", screenshot: nil).components(separatedBy: "\n")

        #expect(lines.contains("````html"))
        #expect(lines.contains("````"))
    }
}

@Suite("Design mode: pictures on disk")
struct DesignScreenshotsTests {
    @Test("A picture is named for when it was taken and what it shows")
    func namesPicture() throws {
        let directory = try TemporaryDirectory()
        let pick = try decodePick(capturedButton)
        let date = Date(timeIntervalSince1970: 1_790_000_000)

        let url = try DesignScreenshots.save(Data([0x89, 0x50]), of: pick, at: date, in: directory.url)

        #expect(url.lastPathComponent.hasSuffix("-savebutton.png"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Pictures older than a week are cleared as new ones arrive")
    func prunesOldPictures() throws {
        let directory = try TemporaryDirectory()
        let now = Date()
        let old = directory.url.appendingPathComponent("old.png")
        let recent = directory.url.appendingPathComponent("recent.png")
        let other = directory.url.appendingPathComponent("notes.txt")
        for url in [old, recent, other] {
            try Data([0]).write(to: url)
        }
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: other.path)

        DesignScreenshots.prune(in: directory.url, now: now)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}

@Suite("Design mode: the script")
struct DesignModeScriptTests {
    /// The script lives in a Swift string, where a stray quote or brace
    /// breaks nothing the compiler can see, and the page reports it only as
    /// design mode never arming.
    @Test("Every expression the page is asked to run parses")
    func scriptsParse() throws {
        let context = try #require(JSContext())
        let scripts = [
            DesignModeScript.arm, DesignModeScript.pick, DesignModeScript.resume,
            DesignModeScript.hide, DesignModeScript.show, DesignModeScript.teardown,
        ]
        for script in scripts {
            let source = JSStringCreateWithCFString(script as CFString)
            defer { JSStringRelease(source) }
            var exception: JSValueRef?
            let parses = JSCheckScriptSyntax(context.jsGlobalContextRef, source, nil, 1, &exception)
            let message = exception.flatMap { JSValue(jsValueRef: $0, in: context)?.toString() } ?? ""
            #expect(parses, "\(script.prefix(60))… does not parse: \(message)")
        }
    }

    @Test("Without an overlay, every call answers instead of throwing")
    func callsSurviveNoOverlay() throws {
        // A navigation takes the overlay with the page, and Relay can ask
        // before it has put a new one up.
        let context = try #require(JSContext())
        context.evaluateScript("var window = this;")
        #expect(context.evaluateScript(DesignModeScript.teardown).toBool())
        #expect(!context.evaluateScript(DesignModeScript.resume).toBool())
        #expect(context.evaluateScript(DesignModeScript.pick).forProperty("cancelled").toString() == "gone")
    }
}

@Suite("Design mode: talking to the page")
@MainActor
struct DevToolsSessionTests {
    @MainActor
    private final class Outbox {
        var messages: [[String: Any]] = []
        var accepts = true

        func send(_ data: Data) -> Bool {
            guard accepts else { return false }
            messages.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
            return true
        }

        /// Waits until the session has sent `count` messages, which is the
        /// moment a reply can be matched to one.
        func sent(_ count: Int) async {
            while messages.count < count {
                await Task.yield()
            }
        }
    }

    private func reply(_ id: Int, _ body: String) -> Data {
        Data("{\"id\":\(id),\(body)}".utf8)
    }

    @Test("A request is numbered and a reply is matched back to it, in whatever order replies come")
    func matchesRepliesToRequests() async throws {
        let outbox = Outbox()
        let session = DevToolsSession(send: outbox.send)

        let first = Task { try await session.evaluate("1 + 1", as: Int.self) }
        let second = Task { try await session.evaluate("'a' + 'b'", as: String.self) }
        await outbox.sent(2)

        let requests = Dictionary(uniqueKeysWithValues: outbox.messages.map {
            (($0["params"] as? [String: Any])?["expression"] as? String ?? "", $0["id"] as? Int ?? 0)
        })
        #expect(outbox.messages.allSatisfy { $0["method"] as? String == "Runtime.evaluate" })
        #expect(Set(requests.values).count == 2)

        session.receive(reply(requests["'a' + 'b'"]!, #""result":{"result":{"type":"string","value":"ab"}}"#))
        session.receive(reply(requests["1 + 1"]!, #""result":{"result":{"type":"number","value":2}}"#))

        #expect(try await first.value == 2)
        #expect(try await second.value == "ab")
        #expect(!session.hasOpenQuestions)
    }

    @Test("A script that throws is reported with what it threw")
    func scriptFailure() async throws {
        let outbox = Outbox()
        let session = DevToolsSession(send: outbox.send)

        let value = Task { try await session.evaluate("boom()", as: Bool.self) }
        await outbox.sent(1)
        session.receive(reply(1, #""result":{"result":{"type":"object"},"exceptionDetails":{"text":"Uncaught","exception":{"description":"ReferenceError: boom is not defined"}}}"#))

        await #expect(throws: DevToolsError.scriptFailed("ReferenceError: boom is not defined")) {
            try await value.value
        }
    }

    @Test("A refusal from the protocol, as when the page navigated mid-question, is an error")
    func protocolRefusal() async throws {
        let outbox = Outbox()
        let session = DevToolsSession(send: outbox.send)

        let value = Task { try await session.evaluate("x", awaitingPromise: true, as: Bool.self) }
        await outbox.sent(1)
        #expect((outbox.messages[0]["params"] as? [String: Any])?["awaitPromise"] as? Bool == true)
        session.receive(reply(1, #""error":{"code":-32000,"message":"Execution context was destroyed."}"#))

        await #expect(throws: DevToolsError.refused(code: -32000, message: "Execution context was destroyed.")) {
            try await value.value
        }
    }

    @Test("Undefined comes back as nothing rather than as a failure")
    func undefinedIsNil() async throws {
        let outbox = Outbox()
        let session = DevToolsSession(send: outbox.send)

        let value = Task { try await session.evaluate("void 0", as: Bool.self) }
        await outbox.sent(1)
        session.receive(reply(1, #""result":{"result":{"type":"undefined"}}"#))

        #expect(try await value.value == nil)
    }

    @Test("Events and replies nobody asked for are ignored")
    func ignoresStrayMessages() async throws {
        let outbox = Outbox()
        let session = DevToolsSession(send: outbox.send)

        let value = Task { try await session.evaluate("1", as: Int.self) }
        await outbox.sent(1)
        session.receive(Data(#"{"method":"Page.frameNavigated","params":{}}"#.utf8))
        session.receive(reply(99, #""result":{}"#))
        session.receive(Data("not json".utf8))
        #expect(session.hasOpenQuestions)
        session.receive(reply(1, #""result":{"result":{"type":"number","value":1}}"#))

        #expect(try await value.value == 1)
    }

    @Test("With no page to take the question, it fails at once")
    func unavailableWithoutPage() async {
        let outbox = Outbox()
        outbox.accepts = false
        let session = DevToolsSession(send: outbox.send)

        await #expect(throws: DevToolsError.unavailable) {
            try await session.evaluate("1", as: Int.self)
        }
        #expect(!session.hasOpenQuestions)
    }

    @Test("A page that goes away settles every open question")
    func abandonsOnClose() async {
        let outbox = Outbox()
        let session = DevToolsSession(send: outbox.send)

        let value = Task { try await session.evaluate("new Promise(() => {})", awaitingPromise: true, as: Bool.self) }
        await outbox.sent(1)
        session.abandonAll()

        await #expect(throws: DevToolsError.abandoned) {
            try await value.value
        }
    }

    @Test("A screenshot is asked for as a clip of the document and comes back as PNG bytes")
    func screenshot() async throws {
        let outbox = Outbox()
        let session = DevToolsSession(send: outbox.send)
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        let picture = Task { try await session.screenshot(of: CGRect(x: 10, y: 160, width: 120, height: 32)) }
        await outbox.sent(1)
        let parameters = outbox.messages[0]["params"] as? [String: Any]
        let clip = parameters?["clip"] as? [String: Double]
        #expect(outbox.messages[0]["method"] as? String == "Page.captureScreenshot")
        #expect(parameters?["format"] as? String == "png")
        #expect(clip == ["x": 10, "y": 160, "width": 120, "height": 32, "scale": 1])
        session.receive(reply(1, "\"result\":{\"data\":\"\(png.base64EncodedString())\"}"))

        #expect(try await picture.value == png)
    }
}

@Suite("Browser pane: Chromium")
@MainActor
struct ChromiumEngineTests {
    @Test("Outside an app bundle, Chromium is said to be missing rather than tried")
    func unavailableOutsideBundle() {
        // `swift run` and the tests run a bare executable. Only a bundle built
        // by Scripts/build-app.sh carries the framework and its helpers.
        #expect(BundleLayout.current == nil)
        #expect(!ChromiumEngine.shared.start())
        guard case .unavailable = ChromiumEngine.shared.state else {
            Issue.record("expected Chromium to be unavailable, found \(ChromiumEngine.shared.state)")
            return
        }
    }
}
