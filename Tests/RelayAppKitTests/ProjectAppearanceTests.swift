import SwiftUI
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
    @Test("Only work in progress moves")
    func spinnerSelection() {
        let moving = RuntimeStatus.allCases.filter { $0.mark == .spinner }
        #expect(Set(moving) == [.working, .starting])
    }

    @Test("A question and a result each have a shape of their own, not just a colour")
    func glyphSelection() {
        #expect(RuntimeStatus.waiting.mark == .question)
        #expect(RuntimeStatus.finished.mark == .check)
        #expect(RuntimeStatus.allCases.filter { $0.mark == .question } == [.waiting])
        #expect(RuntimeStatus.allCases.filter { $0.mark == .check } == [.finished])
    }

    @Test("A spinner steps a twelfth of a turn at a time")
    func spinnerSteps() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(WorkingSpinner.angle(at: start) == .degrees(0))
        #expect(WorkingSpinner.angle(at: start.addingTimeInterval(0.5)) == .degrees(180))
        #expect(WorkingSpinner.angle(at: start.addingTimeInterval(0.1)) == .degrees(30))
        #expect(WorkingSpinner.angle(at: start.addingTimeInterval(0.08)) == .degrees(0))
    }

    @Test("Spinners that appear at different moments turn in step")
    func spinnerPhase() {
        let moment = Date(timeIntervalSinceReferenceDate: 12345.25)
        #expect(WorkingSpinner.angle(at: moment) == WorkingSpinner.angle(at: moment.addingTimeInterval(3)))
    }

    @Test("Every status maps to a colour and distinct states look distinct")
    func tints() {
        let attention = [RuntimeStatus.waiting, .error, .working, .finished, .idle, .offline]
        let colours = Set(attention.map { $0.tint.description })
        #expect(colours.count == attention.count)
    }
}
