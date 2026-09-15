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
///
/// The visible bounds are 832 units tall on the 1024 grid and sit low on it —
/// the ring reaches 992 while the dot starts at 160 — so the shape is fitted by
/// its bounds and re-centred rather than by the grid, which would leave it
/// off-centre and touching the edges.
public struct RelayMark: View {
    private let size: CGFloat
    private let tint: Color

    /// Height of the visible artwork on the design grid.
    private static let boundsHeight: CGFloat = 832
    /// How far the artwork's centre sits below the grid's.
    private static let boundsOffset: CGFloat = 64

    public init(size: CGFloat, tint: Color = Theme.Palette.textPrimary) {
        self.size = size
        self.tint = tint
    }

    private var gridSide: CGFloat { size * 1024 / Self.boundsHeight }

    public var body: some View {
        ZStack {
            RelayMarkShape()
                .stroke(
                    tint,
                    style: StrokeStyle(
                        lineWidth: RelayMarkShape.strokeWidth(forSide: gridSide),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            Circle()
                .fill(tint)
                .frame(width: RelayMarkShape.dotDiameter(forSide: gridSide))
                .position(RelayMarkShape.dotCentre(forSide: gridSide))
        }
        .frame(width: gridSide, height: gridSide)
        .offset(y: -gridSide * Self.boundsOffset / 1024)
        .frame(width: size, height: size)
    }
}
