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

    /// Placeholders for work that is planned but not built. They are shown
    /// rather than hidden so the shape of the app is honest about where it is
    /// going, and disabled rather than half-working.
    var isAvailable: Bool {
        switch self {
        case .services, .docker, .history, .git, .todo: true
        case .files: false
        }
    }

    /// Whether the pane lays out its own full height. The ones that do keep a
    /// list scrolling against a box pinned to the bottom, which the shared
    /// scroll view would push somewhere below fifty rows.
    var fillsPanel: Bool {
        switch self {
        case .git, .todo: true
        default: false
        }
    }

    var comingSoonDescription: String {
        switch self {
        case .files: "A project file tree and an editor with linting will live here."
        default: ""
        }
    }
}
