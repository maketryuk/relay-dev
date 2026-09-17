import Foundation
import Testing

@testable import RelayAppKit

@Suite("Which window a Claude session runs with")
struct ClaudeModelWindowTests {
    @Test("The suffix on the name is what says so")
    func suffixDeclaresTheWindow() {
        #expect(ClaudeModelWindow.declared(byModel: "claude-opus-5[1m]") == 1_000_000)
        #expect(ClaudeModelWindow.declared(byModel: "claude-sonnet-4-5[1M]") == 1_000_000)
        #expect(ClaudeModelWindow.declared(byModel: "claude-opus-5") == nil)
        #expect(ClaudeModelWindow.declared(byModel: "claude-haiku-4-5-20251001") == nil)
    }

    @Test("The base name is the one the transcript writes down")
    func baseNameDropsTheSuffix() {
        // The whole difficulty: the turn is recorded under the name without the
        // suffix, so the two can only be compared in that form.
        #expect(ClaudeModelWindow.baseName(of: "claude-opus-5[1m]") == "claude-opus-5")
        #expect(ClaudeModelWindow.baseName(of: "claude-opus-5") == "claude-opus-5")
    }

    @Test("A model argument on the command is taken at its word")
    func commandDeclaresTheWindow() {
        #expect(ClaudeModelWindow.declared(byCommand: ["claude", "--model", "claude-opus-5[1m]"]) == 1_000_000)
        #expect(ClaudeModelWindow.declared(byCommand: ["claude", "--model=claude-opus-5[1m]"]) == 1_000_000)
        #expect(ClaudeModelWindow.declared(
            byCommand: ["env", "ANTHROPIC_MODEL=claude-opus-5[1m]", "claude"]
        ) == 1_000_000)
        #expect(ClaudeModelWindow.declared(byCommand: ["claude", "--model", "claude-opus-5"]) == nil)
        #expect(ClaudeModelWindow.declared(byCommand: ["claude"]) == nil)
    }

    @Test("What the project last ran is evidence for the same model only")
    func evidenceIsMatchedByModel() throws {
        // Claude Code writes the models a project billed tokens against with
        // the suffix intact, which is the only place on disk it survives.
        let configuration = Data("""
        {
          "projects": {
            "/Users/test/storefront": {
              "lastModelUsage": {
                "claude-haiku-4-5-20251001": { "inputTokens": 1 },
                "claude-opus-5[1m]": { "inputTokens": 2 }
              }
            }
          }
        }
        """.utf8)

        #expect(ClaudeModelWindow.lastUsed(
            forModel: "claude-opus-5",
            directory: "/Users/test/storefront",
            configuration: configuration
        ) == 1_000_000)
        // A different model says nothing about this one.
        #expect(ClaudeModelWindow.lastUsed(
            forModel: "claude-sonnet-4-5",
            directory: "/Users/test/storefront",
            configuration: configuration
        ) == nil)
        // Nor does a different project.
        #expect(ClaudeModelWindow.lastUsed(
            forModel: "claude-opus-5",
            directory: "/Users/test/other",
            configuration: configuration
        ) == nil)
    }

    @Test("Evidence widens a window and never narrows one")
    func evidenceOnlyWidens() {
        #expect(ContextWindow.widening(200_000, toAtLeast: 1_000_000) == 1_000_000)
        #expect(ContextWindow.widening(1_000_000, toAtLeast: 200_000) == 1_000_000)
        #expect(ContextWindow.widening(200_000, toAtLeast: nil) == 200_000)
        #expect(ContextWindow.widening(nil, toAtLeast: 1_000_000) == 1_000_000)
    }

    @Test("A stated window is used as stated")
    func declaredWindowReachesTheReading() throws {
        let objects: [[String: Any]] = [[
            "type": "assistant",
            "message": [
                "model": "claude-opus-5",
                "usage": [
                    "cache_read_input_tokens": 126_000,
                    "cache_creation_input_tokens": 1_000,
                    "input_tokens": 2,
                    "output_tokens": 833,
                ],
            ],
        ]]

        // 127K in the window read as 64% full, because the smallest window that
        // fits was assumed to be the one in use.
        let inferred = try #require(ClaudeContextReader.parse(objects, measuredAt: nil))
        #expect(inferred.window == 200_000)
        #expect(!inferred.isWindowDeclared)

        let declared = try #require(
            ClaudeContextReader.parse(objects, measuredAt: nil, declaredWindow: 1_000_000)
        )
        #expect(declared.window == 1_000_000)
        #expect(declared.isWindowDeclared)
        #expect(declared.percent == 13)
    }

    @Test("The preference says which window, or leaves it to be worked out")
    func preferenceTokens() {
        #expect(ContextWindowPreference.automatic.tokens == nil)
        #expect(ContextWindowPreference.standard.tokens == 200_000)
        #expect(ContextWindowPreference.long.tokens == 1_000_000)
    }
}
