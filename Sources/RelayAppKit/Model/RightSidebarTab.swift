import Foundation

/// Tabs of the right-hand panel.
enum RightSidebarTab: String, CaseIterable, Identifiable, Sendable {
    // Declaration order is the order in the strip.
    case files
    case git
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
        case .files: "Files"
        }
    }

    var symbolName: String {
        switch self {
        case .services: "bolt.horizontal"
        case .docker: "shippingbox"
        case .history: "clock.arrow.circlepath"
        case .git: "arrow.triangle.branch"
        case .files: "folder"
        }
    }

    /// Placeholders for work that is planned but not built. They are shown
    /// rather than hidden so the shape of the app is honest about where it is
    /// going, and disabled rather than half-working.
    var isAvailable: Bool {
        switch self {
        case .services, .docker, .history, .git: true
        case .files: false
        }
    }

    var comingSoonDescription: String {
        switch self {
        case .files: "A project file tree and an editor with linting will live here."
        default: ""
        }
    }
}
