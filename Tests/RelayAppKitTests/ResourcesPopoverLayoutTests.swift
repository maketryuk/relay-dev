import AppKit
import SwiftUI
import Testing

@testable import RelayAppKit

/// The resources popover's headings, hosted and measured rather than reasoned
/// about: a column is a few points wider or narrower than its heading, and
/// only the laid-out view says which.
@Suite("Resources popover layout")
@MainActor
struct ResourcesPopoverLayoutTests {
    private func height(of title: String, in width: CGFloat) -> CGFloat {
        let heading = SortHeading(title: title, isActive: true) {}
            .frame(width: width, alignment: .trailing)
        return NSHostingView(rootView: heading).fittingSize.height
    }

    @Test("A column heading stays on one line, in either language", arguments: ["MEMORY", "ПАМЯТЬ", "CPU", "ЦП"])
    func headingStaysOnOneLine(title: String) {
        // "MEMOR" over "Y" is what the memory column showed, once the sort
        // mark had taken its share of the width.
        let oneLine = height(of: "M", in: ResourceColumns.memory)
        #expect(height(of: title, in: ResourceColumns.memory) == oneLine)
        #expect(height(of: title, in: ResourceColumns.cpu) == oneLine)
    }
}
