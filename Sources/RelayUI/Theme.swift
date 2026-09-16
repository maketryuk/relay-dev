import SwiftUI

/// The single source of truth for Relay's visual language.
///
/// Near-black base, a handful of layered surfaces, and colour reserved almost
/// entirely for runtime status. Chrome stays monochrome so a wall of projects
/// reads as "where is something happening" at a glance.
public enum Theme {
    public enum Palette {
        /// Window background. Pure-ish black so terminal content is the brightest
        /// thing on screen.
        public static let base = Color(hex: 0x08090A)
        public static let rail = Color(hex: 0x0B0C0D)
        public static let sidebar = Color(hex: 0x0D0F10)
        public static let surface = Color(hex: 0x121516)
        public static let surfaceRaised = Color(hex: 0x191D1F)
        public static let surfaceHover = Color(hex: 0x1E2325)
        public static let surfaceActive = Color(hex: 0x252B2E)

        public static let border = Color(hex: 0x1D2225)
        public static let borderStrong = Color(hex: 0x2C3337)

        public static let textPrimary = Color(hex: 0xE8ECEE)
        public static let textSecondary = Color(hex: 0x99A2A7)
        public static let textTertiary = Color(hex: 0x606A6F)

        public static let accent = Color(hex: 0x4C8DFF)
        public static let accentMuted = Color(hex: 0x1B2C4A)

        public static let statusWorking = Color(hex: 0x58A6FF)
        public static let statusWaiting = Color(hex: 0xE3B341)
        public static let statusError = Color(hex: 0xF85149)
        public static let statusFinished = Color(hex: 0x3FB950)
        public static let statusIdle = Color(hex: 0x6E7681)
        public static let statusOffline = Color(hex: 0x394044)
    }

    public enum Radius {
        public static let small: CGFloat = 6
        public static let medium: CGFloat = 10
        public static let large: CGFloat = 14
        public static let xlarge: CGFloat = 18
    }

    public enum Spacing {
        public static let xxsmall: CGFloat = 2
        public static let xsmall: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xlarge: CGFloat = 24
    }

    public enum Metrics {
        public static let titleBarHeight: CGFloat = 38
        public static let statusBarHeight: CGFloat = 26
        public static let contextBarHeight: CGFloat = 22
        public static let railWidth: CGFloat = 60
        public static let sidebarWidth: CGFloat = 248
        public static let sidebarMinWidth: CGFloat = 200
        public static let sidebarMaxWidth: CGFloat = 380
        public static let rightSidebarWidth: CGFloat = 300
        public static let rightSidebarMinWidth: CGFloat = 240
        // Wide enough for a diff: the Git panel draws code, and code at 480
        // points is a column of fragments.
        public static let rightSidebarMaxWidth: CGFloat = 900
        public static let rowHeight: CGFloat = 30
        public static let projectIconSize: CGFloat = 40
    }

    public enum Typography {
        public static let sectionHeader = Font.system(size: 10.5, weight: .semibold).monospacedDigit()
        public static let row = Font.system(size: 12.5, weight: .medium)
        public static let rowSecondary = Font.system(size: 11, weight: .regular)
        public static let title = Font.system(size: 13, weight: .semibold)
        public static let caption = Font.system(size: 10.5, weight: .medium)
        public static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
    }
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
