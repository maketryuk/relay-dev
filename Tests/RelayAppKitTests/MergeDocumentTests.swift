import Testing

@testable import RelayAppKit

@Suite("The result of a merge")
struct MergeDocumentTests {
    /// What `git merge-file --diff3` hands back: the non-conflicting changes
    /// already applied, and what is left with the ancestor between the sides.
    private let file = GitConflictFile.parse(
        """
        one
        <<<<<<< ours
        TWO from the remote
        ||||||| base
        two
        =======
        two from me
        >>>>>>> theirs
        three
        <<<<<<< ours
        four from the remote
        ||||||| base
        =======
        four from me
        >>>>>>> theirs
        five
        """
    )

    @Test("It opens as the file, with no markers anywhere in it")
    func opensWithoutMarkers() {
        let document = MergeDocument.opened(file)
        // The passage nobody has answered stands as what both sides started
        // from — git's markers are how git hands a conflict over, not how a
        // person reads one.
        #expect(document.text == """
        one
        two
        three
        five
        """)
        #expect(document.regions.count == 2)
        #expect(!document.isResolved)
        #expect(document.unanswered == 2)
    }

    @Test("A passage with no ancestor takes up no room until it is answered")
    func anAddedPassageIsEmpty() {
        let document = MergeDocument.opened(file)
        let second = document.region(1)
        #expect(second?.count == 0)
        #expect(second?.base == [])
    }

    @Test("Answering one passage moves the ones after it")
    func answeringShiftsTheRest() {
        var document = MergeDocument.opened(file)
        document = document.taking(.ours, region: 0)
        #expect(document.text == """
        one
        TWO from the remote
        three
        five
        """)
        // The second passage still knows where it is, which is what its arrow
        // acts on.
        #expect(document.region(1)?.start == 3)

        document = document.taking(.theirs, region: 1)
        #expect(document.text == """
        one
        TWO from the remote
        three
        four from me
        five
        """)
        #expect(document.isResolved)
    }

    @Test("An answer can be changed")
    func answersAreNotOneWay() {
        // A conflict is exactly where people change their minds, so the arrows
        // are not one-way.
        var document = MergeDocument.opened(file)
        document = document.taking(.ours, region: 0)
        document = document.taking(.theirs, region: 0)
        #expect(document.text.contains("two from me"))
        #expect(!document.text.contains("TWO from the remote"))
        #expect(document.region(0)?.choice == .theirs)
    }

    @Test("Ignoring a change keeps the ancestor and settles the passage")
    func ignoringIsAnAnswer() {
        var document = MergeDocument.opened(file)
        document = document.taking(.base, region: 0)
        #expect(document.text.contains("two"))
        #expect(document.region(0)?.isAnswered == true)
    }

    @Test("Both sides can be kept")
    func bothIsAnAnswer() {
        var document = MergeDocument.opened(file)
        document = document.taking(.both, region: 0)
        #expect(document.text == """
        one
        TWO from the remote
        two from me
        three
        five
        """)
    }

    @Test("Typing above a passage carries it along")
    func editingAboveShiftsAPassage() {
        // The whole cost of a result with no markers in it: there is nothing
        // left to re-parse, so the passages have to be followed through the
        // change.
        var document = MergeDocument.opened(file)
        document = document.edited(to: """
        one
        inserted
        two
        three
        five
        """)
        #expect(document.region(0)?.start == 2)
        #expect(document.region(1)?.start == 4)
        #expect(document.unanswered == 2)

        // And the arrow still answers the passage it stands beside.
        document = document.taking(.theirs, region: 0)
        #expect(document.text == """
        one
        inserted
        two from me
        three
        five
        """)
    }

    @Test("Typing below a passage leaves it where it is")
    func editingBelowLeavesAPassageAlone() {
        var document = MergeDocument.opened(file)
        document = document.edited(to: """
        one
        two
        three
        five
        six
        """)
        #expect(document.region(0)?.start == 1)
        #expect(document.region(0)?.count == 1)
    }

    @Test("Rewriting a passage's own line grows it, and the arrow still replaces it")
    func editingInsideAPassage() {
        var document = MergeDocument.opened(file)
        document = document.edited(to: """
        one
        two, first half
        two, second half
        three
        five
        """)
        #expect(document.region(0)?.start == 1)
        #expect(document.region(0)?.count == 2)

        // What is in the passage is no longer either side as written, so the
        // arrow replaces what is there now rather than what was.
        document = document.taking(.ours, region: 0)
        #expect(document.text == """
        one
        TWO from the remote
        three
        five
        """)
    }

    @Test("A line typed at the edge of a passage lands outside it")
    func editingAtTheEdgeStaysOutside() {
        // Genuinely ambiguous — a line added where a passage ends is as much
        // the start of what follows as the end of what it answers. It is left
        // outside, so taking a side afterwards replaces the passage and leaves
        // what was typed where it was put; the other way round would eat it.
        var document = MergeDocument.opened(file)
        document = document.edited(to: """
        one
        two
        added after
        three
        five
        """)
        #expect(document.region(0)?.count == 1)

        document = document.taking(.ours, region: 0)
        #expect(document.text == """
        one
        TWO from the remote
        added after
        three
        five
        """)
    }

    @Test("An answered passage stops being marked")
    func answeredIsNotMarked() {
        // The mark is a question, not a record: once a passage has an answer
        // it is part of the file like anything else, and a file still striped
        // with decisions already taken says only that something happened here.
        var document = MergeDocument.opened(file)
        #expect(document.disputed().contains(1))
        document = document.taking(.ours, region: 0)
        #expect(!document.disputed().contains(1))
    }

    @Test("Each side is padded to the height the result gives the passage")
    func panesLineUp() {
        let document = MergeDocument.opened(file)
        let ours = document.rows(for: .ours)
        let theirs = document.rows(for: .theirs)
        // Every pane shows the file at the same height, or the lines below a
        // passage read against the wrong ones beside them.
        #expect(ours.count == theirs.count)

        // The second passage has nothing on the result's side of it, so the
        // room it needs is left empty there instead.
        let gaps = document.gaps()
        #expect(gaps[3] == 1, Comment(rawValue: "\(gaps)"))
    }

    @Test("A side pane numbers its own lines, and only its own")
    func sidesAreNumberedInTheirOwnRight() {
        let document = MergeDocument.opened(file)
        let numbers = document.rows(for: .theirs).compactMap { row -> Int? in
            guard case let .line(number, _, _) = row else { return nil }
            return number
        }
        #expect(numbers == [1, 2, 3, 4, 5])
        #expect(document.rows(for: .theirs).contains { if case .filler = $0 { true } else { false } } == false)
        // Ours has one line where theirs has one too, so nothing is padded on
        // that side either — the passage heights match.
        #expect(document.rows(for: .ours).count == 5)
    }
}
