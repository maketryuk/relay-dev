import Testing

import RelayProtocol
@testable import RelayUI

@Suite("Project appearance")
struct ProjectAppearanceTests {
    @Test(
        "Initials are taken from word boundaries in the project name",
        arguments: [
            ("relay", "RE"),
            ("my-cool-app", "MC"),
            ("my_cool_app", "MC"),
            ("acme.storefront", "AS"),
            ("Storefront Web", "SW"),
            ("a", "A"),
        ]
    )
    func initials(name: String, expected: String) {
        #expect(ProjectAppearance.initials(for: name) == expected)
    }

    @Test("An unnameable project still gets a placeholder")
    func initialsFallback() {
        #expect(ProjectAppearance.initials(for: "") == "?")
        #expect(ProjectAppearance.initials(for: "   ") == "?")
    }

    @Test("Tint is stable for a given seed so a project keeps its identity")
    func tintIsDeterministic() {
        let first = ProjectAppearance.tint(for: "/Users/me/projects/relay")
        let second = ProjectAppearance.tint(for: "/Users/me/projects/relay")
        #expect(first == second)
    }

    @Test("Different projects generally get different tints")
    func tintVaries() {
        let seeds = (0 ..< 40).map { "/Users/me/project-\($0)" }
        let distinct = Set(seeds.map { ProjectAppearance.tint(for: $0).description })
        // Eight tints in the palette; a hash that collapses everything into one
        // would defeat the point of the rail.
        #expect(distinct.count >= 5)
    }
}

@Suite("Status styling")
struct StatusStyleTests {
    @Test("Only transient states animate")
    func pulseSelection() {
        #expect(RuntimeStatus.working.pulses)
        #expect(RuntimeStatus.starting.pulses)
        #expect(RuntimeStatus.waiting.pulses)
        #expect(!RuntimeStatus.idle.pulses)
        #expect(!RuntimeStatus.finished.pulses)
        #expect(!RuntimeStatus.error.pulses)
        #expect(!RuntimeStatus.offline.pulses)
    }

    @Test("Every status maps to a colour and distinct states look distinct")
    func tints() {
        let attention = [RuntimeStatus.waiting, .error, .working, .finished, .idle, .offline]
        let colours = Set(attention.map { $0.tint.description })
        #expect(colours.count == attention.count)
    }
}
