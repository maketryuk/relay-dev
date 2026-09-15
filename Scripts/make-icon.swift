#!/usr/bin/env swift
// Generates Resources/AppIcon.icns. Run only when the mark changes.
import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { return nil }

    let inset = side * 0.06
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: side * 0.225, yRadius: side * 0.225)

    context.saveGState()
    squircle.addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.09, green: 0.11, blue: 0.13, alpha: 1),
        NSColor(srgbRed: 0.03, green: 0.035, blue: 0.04, alpha: 1),
    ])
    gradient?.draw(in: rect, angle: -90)

    // Three stacked "relay" bars: the running, waiting and finished states.
    let barHeight = side * 0.075
    let barWidth = side * 0.46
    let originX = rect.midX - barWidth / 2
    let colors = [
        NSColor(srgbRed: 0.345, green: 0.651, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.890, green: 0.702, blue: 0.255, alpha: 1),
        NSColor(srgbRed: 0.247, green: 0.725, blue: 0.314, alpha: 1),
    ]
    for (index, color) in colors.enumerated() {
        let width = barWidth * (index == 1 ? 0.72 : index == 2 ? 0.5 : 1.0)
        let y = rect.midY + side * 0.13 - CGFloat(index) * (barHeight * 2.05)
        let bar = NSBezierPath(
            roundedRect: CGRect(x: originX, y: y, width: width, height: barHeight),
            xRadius: barHeight / 2,
            yRadius: barHeight / 2
        )
        color.setFill()
        bar.fill()
    }

    // Prompt caret, so it reads as a terminal tool at small sizes.
    let caret = NSBezierPath()
    caret.lineWidth = side * 0.05
    caret.lineCapStyle = .round
    caret.lineJoinStyle = .round
    caret.move(to: CGPoint(x: rect.midX - side * 0.16, y: rect.midY - side * 0.17))
    caret.line(to: CGPoint(x: rect.midX - side * 0.05, y: rect.midY - side * 0.255))
    caret.line(to: CGPoint(x: rect.midX - side * 0.16, y: rect.midY - side * 0.34))
    NSColor(srgbRed: 0.91, green: 0.925, blue: 0.933, alpha: 1).setStroke()
    caret.stroke()

    context.restoreGState()

    squircle.lineWidth = side * 0.006
    NSColor(white: 1, alpha: 0.09).setStroke()
    squircle.stroke()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    bitmap.size = NSSize(width: side, height: side)
    return bitmap.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = draw(size: size) else { continue }
    try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    if size <= 512, let retina = draw(size: size * 2) {
        try retina.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
}
print("iconset written to \(iconset.path)")
