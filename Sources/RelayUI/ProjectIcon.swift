import AppKit
import RelayProtocol
import SwiftUI

/// Discord-style project tile: a squircle that morphs toward a rounded square
/// when selected, with the aggregated runtime status pinned to its corner —
/// when there is one worth pinning. A project where nothing is happening
/// carries no mark at all.
public struct ProjectIcon: View {
    private let initials: String
    private let tint: Color
    private let status: RuntimeStatus
    private let isSelected: Bool
    private let size: CGFloat
    private let artwork: ProjectArtwork?

    @State private var isHovering = false

    public init(
        initials: String,
        tint: Color,
        status: RuntimeStatus,
        isSelected: Bool,
        size: CGFloat = Theme.Metrics.projectIconSize,
        /// The project's own artwork, when it has any. Initials are the
        /// fallback, not the design.
        artwork: ProjectArtwork? = nil
    ) {
        self.initials = initials
        self.tint = tint
        self.status = status
        self.isSelected = isSelected
        self.size = size
        self.artwork = artwork
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(background)
                .frame(width: size, height: size)
                .overlay { mark }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                // Last, and over the clip. Drawn before the artwork it was
                // painted over by any icon that fills its tile edge to edge —
                // which is every application icon, and exactly the tiles whose
                // shape most needed containing.
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(borderOpacity), lineWidth: 1)
                )

            if !status.isQuiet {
                // Inside the tile, not hanging off it. Drawing past your own
                // frame works only for as long as nothing above you clips, and
                // the tile carries a context menu, which does — the dot lost
                // its right-hand side to a straight vertical edge. The ring is
                // what separates it from the artwork it now sits on.
                StatusDot(status: status, size: 8, showsRing: true)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
    }

    /// A favicon is usually transparent and often nearly the colour of the app,
    /// so it keeps a plate behind it — muted, so the artwork stays the subject.
    private var background: AnyShapeStyle {
        // Artwork that is its own tile needs nothing behind it, and a plate
        // under one draws a rounded square inside a rounded square.
        guard artwork?.isFullBleed != true else { return AnyShapeStyle(Color.clear) }
        guard artwork == nil else {
            return AnyShapeStyle(Theme.Palette.surfaceRaised.opacity(isSelected || isHovering ? 1 : 0.75))
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [tint.opacity(isSelected || isHovering ? 0.85 : 0.55), tint.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    @ViewBuilder
    private var mark: some View {
        if let artwork {
            // The artwork arrives trimmed to what it actually draws, so the
            // inset here is the whole margin and every project gets the same
            // one. Before that, a mark exported with half its canvas empty was
            // drawn half the size of one that filled it — with no setting
            // between them to explain why.
            Image(nsImage: artwork.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(artwork.isFullBleed ? 0 : size * 0.1)
        } else {
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.95))
        }
    }

    /// One hairline on every tile, whatever it is drawn with.
    ///
    /// A rail of icons that each end wherever their artwork happens to is a
    /// rail with no column in it; the outline is what makes them one set of
    /// things rather than several pictures.
    private var borderOpacity: Double {
        isSelected || isHovering ? 0.3 : 0.16
    }

    private var cornerRadius: CGFloat {
        isSelected || isHovering ? size * 0.3 : size * 0.44
    }
}

/// Deterministic colour and initials so a project keeps its identity across
/// launches without the user configuring anything.
public enum ProjectAppearance {
    private static let tints: [Color] = [
        Color(hex: 0x4C8DFF),
        Color(hex: 0x9B72F2),
        Color(hex: 0x2FB8A8),
        Color(hex: 0xE0793F),
        Color(hex: 0xD75A8C),
        Color(hex: 0x4FA84F),
        Color(hex: 0xC9A227),
        Color(hex: 0x5A9FD4),
    ]

    public static func tint(for seed: String) -> Color {
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return tints[Int(hash % UInt64(tints.count))]
    }

    public static func initials(for name: String) -> String {
        let words = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")
            .filter { !$0.isEmpty }

        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }
}

/// A project's artwork, measured and ready to draw.
public struct ProjectArtwork: Equatable {
    public var image: NSImage
    /// Whether the artwork is a tile in its own right — an application icon,
    /// which brings its own shape and its own background. Those are drawn edge
    /// to edge with nothing behind them; a mark on a transparent field is not,
    /// and without a plate it would look stuck to the rail rather than sitting
    /// on it.
    public var isFullBleed: Bool

    public init(image: NSImage, isFullBleed: Bool) {
        self.image = image
        self.isFullBleed = isFullBleed
    }
}
