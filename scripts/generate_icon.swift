import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: generate_icon.swift <output.iconset_dir>\n", stderr)
    exit(1)
}

let iconsetPath = args[1]
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderIcon(size: Int) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
    guard let bitmap = rep else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let s = CGFloat(size)
    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = rect.width * 0.225

    // Background squircle with vibrant blue-cyan gradient
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    path.addClip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradColors = [
        CGColor(red: 0.06, green: 0.36, blue: 0.94, alpha: 1.0),
        CGColor(red: 0.04, green: 0.72, blue: 0.88, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0.0, 1.0]) {
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // Inner subtle glass ring
    NSColor.white.withAlphaComponent(0.24).setStroke()
    path.lineWidth = max(1.0, s * 0.018)
    path.stroke()

    // Draw stylized SSD drive card in center
    let cardW = rect.width * 0.56
    let cardH = rect.height * 0.44
    let cardRect = CGRect(
        x: rect.midX - cardW / 2,
        y: rect.midY - cardH / 2 - s * 0.03,
        width: cardW,
        height: cardH
    )
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: cardW * 0.14, yRadius: cardW * 0.14)
    NSColor.white.withAlphaComponent(0.95).setFill()
    cardPath.fill()

    // Storage meter bar inside SSD card
    let barW = cardW * 0.72
    let barH = cardH * 0.18
    let barRect = CGRect(
        x: cardRect.midX - barW / 2,
        y: cardRect.midY - barH / 2,
        width: barW,
        height: barH
    )
    let barBg = NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2)
    NSColor(calibratedRed: 0.84, green: 0.90, blue: 0.98, alpha: 1.0).setFill()
    barBg.fill()

    let usedRect = CGRect(
        x: barRect.minX,
        y: barRect.minY,
        width: barW * 0.42,
        height: barH
    )
    let usedBar = NSBezierPath(roundedRect: usedRect, xRadius: barH / 2, yRadius: barH / 2)
    NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.45, alpha: 1.0).setFill()
    usedBar.fill()

    // Draw 4-point sparkle star at top-right
    let starCenter = CGPoint(x: rect.midX + cardW * 0.28, y: rect.midY + cardH * 0.44)
    let starR = s * 0.13
    let innerR = starR * 0.32
    let starPath = NSBezierPath()
    for i in 0..<8 {
        let angle = CGFloat(i) * (.pi / 4.0)
        let r = (i % 2 == 0) ? starR : innerR
        let pt = CGPoint(x: starCenter.x + cos(angle) * r, y: starCenter.y + sin(angle) * r)
        if i == 0 {
            starPath.move(to: pt)
        } else {
            starPath.line(to: pt)
        }
    }
    starPath.close()
    NSColor.white.setFill()
    starPath.fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for spec in specs {
    if let pngData = renderIcon(size: spec.pixels) {
        let outURL = URL(fileURLWithPath: iconsetPath).appendingPathComponent(spec.name)
        try pngData.write(to: outURL)
    }
}
print("Generated iconset at \(iconsetPath)")
