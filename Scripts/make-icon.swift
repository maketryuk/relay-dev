#!/usr/bin/env swift
// Generates Resources/AppIcon.icns from the Relay mark.
// Run only when the mark changes.
import AppKit
import SwiftUI

/// The logo, traced from `Resources/relay-logo.svg` so the icon and the source
/// file cannot drift.
///
/// An open ring with a dot resting in its gap: the ring is the app, which you
/// can close, and the dot is the process, which stays.
struct RelayMarkShape: Shape {
    /// The SVG's own grid, which the coordinates below are expressed in.
    private let designSize: CGFloat = 1024

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / designSize
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

    /// Stroke width in the same grid, so callers scale it the same way.
    static func strokeWidth(forSide side: CGFloat) -> CGFloat { side * 112 / 1024 }

    static func dotRect(forSide side: CGFloat, in rect: CGRect) -> CGRect {
        let scale = side / 1024
        let radius = 64 * scale
        let centre = CGPoint(
            x: rect.midX - side / 2 + 512 * scale,
            y: rect.midY - side / 2 + 224 * scale
        )
        return CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// The two builds, told apart at a glance.
///
/// Relay Dev sits in the same Dock as Relay, at sixteen points, where the only
/// thing anyone reads is the colour of the tile. A tinted ring would be
/// invisible there; the tile is the whole difference.
enum IconFlavour {
    case release
    case development

    var tile: Color {
        switch self {
        case .release: .black
        // The amber the app already uses for "waiting on you", darkened enough
        // that a white mark still sits on it.
        case .development: Color(red: 0.42, green: 0.28, blue: 0.04)
        }
    }

    var fileName: String {
        switch self {
        case .release: "AppIcon"
        case .development: "AppIconDev"
        }
    }
}

struct IconTile: View {
    let side: CGFloat
    var flavour: IconFlavour = .release

    var body: some View {
        // Apple's grid: the tile occupies 824 of a 1024 canvas, leaving the
        // margin the system expects for shadows and alignment.
        let tileSide = side * 824 / 1024
        // The mark's visible bounds are 832 units tall on its 1024 grid and are
        // not centred on it — the ring reaches 992 while the dot starts at 160 —
        // so scaling the grid to the tile pushes the artwork against the edges
        // and sits it low. The bounds are fitted instead, and re-centred.
        let artHeightFraction: CGFloat = 0.62
        let artSide = tileSide * artHeightFraction * 1024 / 832
        let artOffset = artSide * 64 / 1024

        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: tileSide * 0.2237, style: .continuous)
                .fill(flavour.tile)
                .overlay(
                    RoundedRectangle(cornerRadius: tileSide * 0.2237, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: max(0.5, side * 0.004))
                )
                .frame(width: tileSide, height: tileSide)
                .overlay {
                    ZStack {
                        RelayMarkShape()
                            .stroke(
                                .white,
                                style: StrokeStyle(
                                    lineWidth: RelayMarkShape.strokeWidth(forSide: artSide),
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                        GeometryReader { proxy in
                            Circle()
                                .fill(.white)
                                .frame(
                                    width: RelayMarkShape.dotRect(
                                        forSide: artSide,
                                        in: CGRect(origin: .zero, size: proxy.size)
                                    ).width
                                )
                                .position(
                                    x: RelayMarkShape.dotRect(
                                        forSide: artSide,
                                        in: CGRect(origin: .zero, size: proxy.size)
                                    ).midX,
                                    y: RelayMarkShape.dotRect(
                                        forSide: artSide,
                                        in: CGRect(origin: .zero, size: proxy.size)
                                    ).midY
                                )
                        }
                    }
                    .frame(width: artSide, height: artSide)
                    .offset(y: -artOffset)
                }
        }
        .frame(width: side, height: side)
    }
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let flavour: IconFlavour = CommandLine.arguments.count > 2 && CommandLine.arguments[2].hasPrefix("dev")
    ? .development
    : .release
let iconset = outputDirectory.appendingPathComponent("\(flavour.fileName).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

@MainActor
func render(size: Int) -> Data? {
    let renderer = ImageRenderer(content: IconTile(side: CGFloat(size), flavour: flavour))
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    bitmap.size = NSSize(width: size, height: size)
    return bitmap.representation(using: .png, properties: [:])
}

MainActor.assumeIsolated {
    for size in [16, 32, 64, 128, 256, 512, 1024] {
        guard let data = render(size: size) else { continue }
        try? data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
        if size <= 512, let retina = render(size: size * 2) {
            try? retina.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
        }
    }
}
print("iconset written to \(iconset.path)")
