import Foundation
import RelayProtocol
import RelayUI

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
    /// An image the user picked. Nil means "whatever the project itself
    /// carries", which is right for almost every project and needs no setting.
    var iconPath: String?
    /// SSH aliases the user pinned to this project; shown above the rest.
    var pinnedSSHHosts: [String]
    /// Long-running processes this project knows how to start.
    var services: [ServiceDefinition]
    /// The words the TODO panel searches this project's comments for. Almost
    /// every codebase uses the same handful; the ones that have their own
    /// vocabulary have no other way to be found.
    var todoMarkers: [String]

    init(
        id: ProjectID = .generate(),
        name: String,
        rootPath: String,
        createdAt: Date = Date(),
        defaultAgent: SessionKind = .claude,
        defaultServiceCommand: String? = nil,
        preferredEditor: String? = nil,
        iconPath: String? = nil,
        pinnedSSHHosts: [String] = [],
        services: [ServiceDefinition] = [],
        todoMarkers: [String] = TodoScanner.defaultMarkers
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
        self.defaultAgent = defaultAgent
        self.defaultServiceCommand = defaultServiceCommand
        self.preferredEditor = preferredEditor
        self.iconPath = iconPath
        self.pinnedSSHHosts = pinnedSSHHosts
        self.services = services
        self.todoMarkers = todoMarkers
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
        iconPath = try container.decodeIfPresent(String.self, forKey: .iconPath)
        pinnedSSHHosts = try container.decodeIfPresent([String].self, forKey: .pinnedSSHHosts) ?? []
        services = try container.decodeIfPresent([ServiceDefinition].self, forKey: .services) ?? []
        todoMarkers = try container
            .decodeIfPresent([String].self, forKey: .todoMarkers) ?? TodoScanner.defaultMarkers
    }

    var defaultService: ServiceDefinition? {
        services.first { $0.isDefault } ?? services.first
    }

    var url: URL { URL(fileURLWithPath: rootPath) }

    var displayPath: String {
        HomeRelativePath.abbreviating(rootPath)
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
    var rightSidebarWidth: Double
    var collapsedSections: [String]
    var notifications: NotificationSettings
    var shortcuts: ShortcutSettings
    /// Presets the user added; the built-in ones live in code.
    /// Nil means a workspace written before presets were editable, which is
    /// migrated on load.
    var presets: [SessionPreset]?
    /// Read only to migrate; no longer written.
    var customPresets: [SessionPreset]
    var enabledPresetIDs: [String]?
    var sessionHistory: [SessionHistoryEntry]
    /// Sessions that were closed, newest first, for ⌘⇧T. Kept apart from the
    /// history: that is a record of what agents did, this is an undo.
    /// Nil means a workspace written before the shortcut existed.
    var closedSessions: [SessionSpec]?
    /// The order sessions are listed in, as dragged. Session identifiers rather
    /// than anything about them: the daemon owns the sessions, and this only
    /// says where each one sits.
    var sessionOrder: [String]
    var isRightSidebarVisible: Bool
    var isLeftSidebarVisible: Bool
    var rightSidebarTab: String?
    var language: AppLanguage
    /// Asking GitHub about releases is the only request Relay makes; it can be
    /// refused outright.
    var checksForUpdates: Bool
    /// The strip along the bottom showing what the agents have left.
    var showsStatusBar: Bool
    /// Named for the bar because that is all it governs. The key it is
    /// stored under changed with the meaning, so a value written when it
    /// meant something else is ignored rather than honoured.
    var usageBarDetail: UsageDetail
    /// How large the terminals are drawn, in points.
    var terminalFontSize: Double
    /// And the files, which are read at a different distance.
    var editorFontSize: Double
    /// Whether a Markdown file opens as the page it makes or as its source:
    /// whichever was chosen last.
    var showsMarkdownPreview: Bool
    /// Whether terminals are drawn on the GPU.
    var terminalUsesGPURendering: Bool
    /// Review notes that have not been handed to an agent yet. Kept because
    /// they are work — a window that loses an afternoon of remarks to a restart
    /// is a window nobody writes remarks in.
    var reviewComments: [ReviewComment]
    /// Terminal arrangement per project, so a split survives a relaunch the
    /// way the sessions in it do.
    var paneLayouts: [String: PaneNode]

    init(
        version: Int = 1,
        projects: [Project] = [],
        lastActiveProjectID: String? = nil,
        lastActiveSessionByProject: [String: String] = [:],
        sidebarWidth: Double = 248,
        rightSidebarWidth: Double = 300,
        collapsedSections: [String] = [],
        notifications: NotificationSettings = NotificationSettings(),
        shortcuts: ShortcutSettings = ShortcutSettings(),
        presets: [SessionPreset]? = nil,
        customPresets: [SessionPreset] = [],
        enabledPresetIDs: [String]? = nil,
        sessionHistory: [SessionHistoryEntry] = [],
        closedSessions: [SessionSpec]? = nil,
        sessionOrder: [String] = [],
        isRightSidebarVisible: Bool = true,
        isLeftSidebarVisible: Bool = true,
        rightSidebarTab: String? = nil,
        language: AppLanguage = .system,
        checksForUpdates: Bool = true,
        showsStatusBar: Bool = true,
        usageBarDetail: UsageDetail = .compact,
        terminalFontSize: Double = 13,
        editorFontSize: Double = 13,
        showsMarkdownPreview: Bool = true,
        terminalUsesGPURendering: Bool = true,
        reviewComments: [ReviewComment] = [],
        paneLayouts: [String: PaneNode] = [:]
    ) {
        self.version = version
        self.projects = projects
        self.lastActiveProjectID = lastActiveProjectID
        self.lastActiveSessionByProject = lastActiveSessionByProject
        self.sidebarWidth = sidebarWidth
        self.rightSidebarWidth = rightSidebarWidth
        self.collapsedSections = collapsedSections
        self.notifications = notifications
        self.shortcuts = shortcuts
        self.presets = presets
        self.customPresets = customPresets
        self.enabledPresetIDs = enabledPresetIDs
        self.sessionHistory = sessionHistory
        self.closedSessions = closedSessions
        self.sessionOrder = sessionOrder
        self.isRightSidebarVisible = isRightSidebarVisible
        self.isLeftSidebarVisible = isLeftSidebarVisible
        self.rightSidebarTab = rightSidebarTab
        self.language = language
        self.checksForUpdates = checksForUpdates
        self.showsStatusBar = showsStatusBar
        self.usageBarDetail = usageBarDetail
        self.terminalFontSize = terminalFontSize
        self.editorFontSize = editorFontSize
        self.showsMarkdownPreview = showsMarkdownPreview
        self.terminalUsesGPURendering = terminalUsesGPURendering
        self.reviewComments = reviewComments
        self.paneLayouts = paneLayouts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        lastActiveProjectID = try container.decodeIfPresent(String.self, forKey: .lastActiveProjectID)
        lastActiveSessionByProject = try container
            .decodeIfPresent([String: String].self, forKey: .lastActiveSessionByProject) ?? [:]
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 248
        rightSidebarWidth = try container.decodeIfPresent(Double.self, forKey: .rightSidebarWidth) ?? 300
        collapsedSections = try container.decodeIfPresent([String].self, forKey: .collapsedSections) ?? []
        notifications = try container
            .decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        shortcuts = try container.decodeIfPresent(ShortcutSettings.self, forKey: .shortcuts) ?? ShortcutSettings()
        presets = try container.decodeIfPresent([SessionPreset].self, forKey: .presets)
        customPresets = try container.decodeIfPresent([SessionPreset].self, forKey: .customPresets) ?? []
        enabledPresetIDs = try container.decodeIfPresent([String].self, forKey: .enabledPresetIDs)
        sessionHistory = try container.decodeIfPresent([SessionHistoryEntry].self, forKey: .sessionHistory) ?? []
        closedSessions = try container.decodeIfPresent([SessionSpec].self, forKey: .closedSessions)
        sessionOrder = try container.decodeIfPresent([String].self, forKey: .sessionOrder) ?? []
        isRightSidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .isRightSidebarVisible) ?? true
        isLeftSidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .isLeftSidebarVisible) ?? true
        rightSidebarTab = try container.decodeIfPresent(String.self, forKey: .rightSidebarTab)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        checksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checksForUpdates) ?? true
        showsStatusBar = try container.decodeIfPresent(Bool.self, forKey: .showsStatusBar) ?? true
        usageBarDetail = try container.decodeIfPresent(UsageDetail.self, forKey: .usageBarDetail) ?? .compact
        terminalFontSize = try container.decodeIfPresent(Double.self, forKey: .terminalFontSize) ?? 13
        editorFontSize = try container.decodeIfPresent(Double.self, forKey: .editorFontSize) ?? 13
        showsMarkdownPreview = try container.decodeIfPresent(Bool.self, forKey: .showsMarkdownPreview) ?? true
        terminalUsesGPURendering = try container
            .decodeIfPresent(Bool.self, forKey: .terminalUsesGPURendering) ?? true
        reviewComments = try container.decodeIfPresent([ReviewComment].self, forKey: .reviewComments) ?? []
        paneLayouts = try container.decodeIfPresent([String: PaneNode].self, forKey: .paneLayouts) ?? [:]
    }
}
