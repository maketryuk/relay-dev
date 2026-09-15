import RelayProtocol
import SwiftUI

/// The glyph shown for a session, using a drawn mark where one exists and an
/// SF Symbol everywhere else.
public struct SessionGlyph: View {
    private let kind: SessionKind
    private let size: CGFloat
    private let tint: Color

    public init(kind: SessionKind, size: CGFloat, tint: Color) {
        self.kind = kind
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        switch kind {
        case .claude:
            ClaudeMarkShape()
                .fill(tint)
                .frame(width: size * 1.1, height: size * 1.1)
        case .codex:
            // The knot encloses counter-shapes, so it needs the even-odd rule
            // to keep its holes open.
            CodexMarkShape()
                .fill(tint, style: FillStyle(eoFill: true))
                .frame(width: size * 1.15, height: size * 1.15)
        case .gemini:
            GeminiMarkShape()
                .fill(tint)
                .frame(width: size * 1.05, height: size * 1.05)
        default:
            Image(systemName: kind.symbolName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
        }
    }
}
