import RelayProtocol
import SwiftUI

/// Discord-style project tile: a squircle that morphs toward a rounded square
/// when selected, with the aggregated runtime status pinned to its corner.
public struct ProjectIcon: View {
    private let initials: String
    private let tint: Color
    private let status: RuntimeStatus
    private let isSelected: Bool
    private let size: CGFloat

    @State private var isHovering = false

    public init(
        initials: String,
        tint: Color,
        status: RuntimeStatus,
        isSelected: Bool,
        size: CGFloat = Theme.Metrics.projectIconSize
    ) {
        self.initials = initials
        self.tint = tint
        self.status = status
        self.isSelected = isSelected
        self.size = size
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(isSelected || isHovering ? 0.85 : 0.55), tint.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(isSelected ? 0.22 : 0.07), lineWidth: 1)
                )
                .overlay(
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.95))
                )

            if status != .offline {
                StatusDot(status: status, size: 8, showsRing: true)
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
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
