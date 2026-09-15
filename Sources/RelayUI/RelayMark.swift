import SwiftUI

/// Relay's mark: an open ring with a dot resting in its gap.
///
/// The ring is the app, which you can close; the dot is the process, which
/// stays. Traced from `Resources/relay-logo.svg` on its own 1024 grid, so the
/// icon generator and the interface draw the same shape.
public struct RelayMarkShape: Shape {
    private static let designSize: CGFloat = 1024

    public init() {}

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / Self.designSize
        let originX = rect.midX - side / 2
        let originY = rect.midY - side / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        path.move(to: point(338, 384))
        path.addCurve(to: point(216, 640), control1: point(260, 447), control2: point(216, 541))
        path.addCurve(to: point(512, 936), control1: point(216, 803), control2: point(349, 936))
        path.addCurve(to: point(808, 640), control1: point(675, 936), control2: point(808, 803))
        path.addCurve(to: point(686, 384), control1: point(808, 541), control2: point(764, 447))
        return path
    }

    static func strokeWidth(forSide side: CGFloat) -> CGFloat { side * 112 / designSize }

    static func dotDiameter(forSide side: CGFloat) -> CGFloat { side * 128 / designSize }

    static func dotCentre(forSide side: CGFloat) -> CGPoint {
        CGPoint(x: side * 512 / designSize, y: side * 224 / designSize)
    }
}

/// The mark, drawn at a given size.
public struct RelayMark: View {
    private let size: CGFloat
    private let tint: Color

    public init(size: CGFloat, tint: Color = Theme.Palette.textPrimary) {
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            RelayMarkShape()
                .stroke(
                    tint,
                    style: StrokeStyle(
                        lineWidth: RelayMarkShape.strokeWidth(forSide: size),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            Circle()
                .fill(tint)
                .frame(width: RelayMarkShape.dotDiameter(forSide: size))
                .position(RelayMarkShape.dotCentre(forSide: size))
        }
        .frame(width: size, height: size)
    }
}
