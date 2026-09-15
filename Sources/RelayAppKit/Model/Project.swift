import Foundation
import RelayProtocol

/// A local directory the user has adopted into their workspace.
///
/// Projects are configuration, not runtime: the daemon never sees this type.
struct Project: Codable, Identifiable, Hashable {
    var id: ProjectID
    var name: String
    var rootPath: String
    var createdAt: Date
    var defaultAgent: SessionKind
    var defaultServiceCommand: String?
    var preferredEditor: String?
    /// SSH aliases the user pinned to this project; shown above the rest.
    var pinnedSSHHosts: [String]
    /// Long-running processes this project knows how to start.
    var services: [ServiceDefinition]

    init(
        id: ProjectID = .generate(),
        name: String,
        rootPath: String,
        createdAt: Date = Date(),
        defaultAgent: SessionKind = .claude,
        defaultServiceCommand: String? = nil,
        preferredEditor: String? = nil,
        pinnedSSHHosts: [String] = [],
        services: [ServiceDefinition] = []
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
        self.defaultAgent = defaultAgent
        self.defaultServiceCommand = defaultServiceCommand
        self.preferredEditor = preferredEditor
        self.pinnedSSHHosts = pinnedSSHHosts
        self.services = services
    }

    /// Decoding is tolerant of absent keys so a workspace written by an older
    /// build keeps loading after new settings are added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProjectID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        defaultAgent = try container.decodeIfPresent(SessionKind.self, forKey: .defaultAgent) ?? .claude
        defaultServiceCommand = try container.decodeIfPresent(String.self, forKey: .defaultServiceCommand)
        preferredEditor = try container.decodeIfPresent(String.self, forKey: .preferredEditor)
        pinnedSSHHosts = try container.decodeIfPresent([String].self, forKey: .pinnedSSHHosts) ?? []
        services = try container.decodeIfPresent([ServiceDefinition].self, forKey: .services) ?? []
    }

    var defaultService: ServiceDefinition? {
        services.first { $0.isDefault } ?? services.first
    }

    var url: URL { URL(fileURLWithPath: rootPath) }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return rootPath.hasPrefix(home) ? "~" + rootPath.dropFirst(home.count) : rootPath
    }

    mutating func togglePin(sshHost alias: String) {
        if let index = pinnedSSHHosts.firstIndex(of: alias) {
            pinnedSSHHosts.remove(at: index)
        } else {
            pinnedSSHHosts.append(alias)
        }
    }
}

/// Everything Relay remembers between launches.
struct WorkspaceState: Codable {
    var version: Int
    var projects: [Project]
    var lastActiveProjectID: String?
    /// projectID → sessionID, so switching projects restores the last terminal.
    var lastActiveSessionByProject: [String: String]
    var sidebarWidth: Double
    var collapsedSections: [String]
    var notifications: NotificationSettings
    var shortcuts: ShortcutSettings
    /// Presets the user added; the built-in ones live in code.
    var customPresets: [SessionPreset]

    init(
        version: Int = 1,
        projects: [Project] = [],
        lastActiveProjectID: String? = nil,
        lastActiveSessionByProject: [String: String] = [:],
        sidebarWidth: Double = 248,
        collapsedSections: [String] = [],
        notifications: NotificationSettings = NotificationSettings(),
        shortcuts: ShortcutSettings = ShortcutSettings(),
        customPresets: [SessionPreset] = []
    ) {
        self.version = version
        self.projects = projects
        self.lastActiveProjectID = lastActiveProjectID
        self.lastActiveSessionByProject = lastActiveSessionByProject
        self.sidebarWidth = sidebarWidth
        self.collapsedSections = collapsedSections
        self.notifications = notifications
        self.shortcuts = shortcuts
        self.customPresets = customPresets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        lastActiveProjectID = try container.decodeIfPresent(String.self, forKey: .lastActiveProjectID)
        lastActiveSessionByProject = try container
            .decodeIfPresent([String: String].self, forKey: .lastActiveSessionByProject) ?? [:]
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 248
        collapsedSections = try container.decodeIfPresent([String].self, forKey: .collapsedSections) ?? []
        notifications = try container
            .decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        shortcuts = try container.decodeIfPresent(ShortcutSettings.self, forKey: .shortcuts) ?? ShortcutSettings()
        customPresets = try container.decodeIfPresent([SessionPreset].self, forKey: .customPresets) ?? []
    }
}
