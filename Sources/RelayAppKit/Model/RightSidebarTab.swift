import Foundation

/// Tabs of the right-hand panel.
enum RightSidebarTab: String, CaseIterable, Identifiable, Sendable {
    // Declaration order is the order in the strip.
    case files
    case git
    case todo
    case history
    case services
    case docker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .services: "Services"
        case .docker: "Docker"
        case .history: "History"
        case .git: "Git"
        case .todo: "TODO"
        case .files: "Files"
        }
    }

    var symbolName: String {
        switch self {
        case .services: "bolt.horizontal"
        case .docker: "shippingbox"
        case .history: "clock.arrow.circlepath"
        case .git: "arrow.triangle.branch"
        case .todo: "checklist"
        case .files: "folder"
        }
    }

    /// Whether the pane lays out its own full height. The ones that do keep a
    /// list scrolling against a box pinned to the bottom, which the shared
    /// scroll view would push somewhere below fifty rows.
    var fillsPanel: Bool {
        switch self {
        case .git, .todo, .files: true
        default: false
        }
    }
}
