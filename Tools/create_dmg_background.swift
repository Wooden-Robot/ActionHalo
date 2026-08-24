#!/usr/bin/env swift

import AppKit

func fail(_ message: String) -> Never {
    fputs("create_dmg_background: \(message)\n", stderr)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: create_dmg_background.swift <output.png> <width> <height>")
}

let outputPath = arguments[1]
guard let width = Double(arguments[2]), let height = Double(arguments[3]), width > 0, height > 0 else {
    fail("width and height must be positive numbers")
}

let pixelWidth = Int(width.rounded())
let pixelHeight = Int(height.rounded())
let size = NSSize(width: pixelWidth, height: pixelHeight)

func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor, letterSpacing: CGFloat = 0, shadow: NSShadow? = nil) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
        .kern: letterSpacing
    ]
    if let shadow {
        attributes[.shadow] = shadow
    }

    let rect = NSRect(x: 0, y: y, width: size.width, height: font.pointSize * 1.7)
    (text as NSString).draw(in: rect, withAttributes: attributes)
}

func drawInstallArrow(center: NSPoint) {
    let arrowColor = NSColor(calibratedRed: 0.94, green: 0.27, blue: 0.11, alpha: 1)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = NSSize(width: 0, height: -2)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    arrowColor.setFill()

    let shaft = NSBezierPath(
        roundedRect: NSRect(x: center.x - 56, y: center.y - 5, width: 76, height: 10),
        xRadius: 5,
        yRadius: 5
    )
    shaft.fill()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: center.x + 58, y: center.y))
    head.line(to: NSPoint(x: center.x + 18, y: center.y + 25))
    head.line(to: NSPoint(x: center.x + 18, y: center.y - 25))
    head.close()
    head.fill()

    NSGraphicsContext.restoreGraphicsState()
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelWidth,
    pixelsHigh: pixelHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("failed to create bitmap")
}

bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let bounds = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.99, green: 0.98, blue: 0.96, alpha: 1).setFill()
bounds.fill()

let glow = NSBezierPath(ovalIn: NSRect(x: size.width * 0.5 - 135, y: size.height * 0.5 - 92, width: 270, height: 160))
NSColor(calibratedRed: 1.0, green: 0.43, blue: 0.20, alpha: 0.055).setFill()
glow.fill()

drawCentered(
    "把 ActionHalo 拖到 Applications 里",
    y: size.height - 62,
    font: .systemFont(ofSize: 19, weight: .semibold),
    color: NSColor(calibratedWhite: 0.18, alpha: 1)
)

drawCentered(
    "拖动左边的程序到右边的文件夹即可安装",
    y: size.height - 90,
    font: .systemFont(ofSize: 13, weight: .regular),
    color: NSColor(calibratedWhite: 0.45, alpha: 1),
    letterSpacing: 0
)

drawCentered(
    "Drag ActionHalo into Applications to install",
    y: size.height - 112,
    font: .systemFont(ofSize: 12, weight: .regular),
    color: NSColor(calibratedWhite: 0.52, alpha: 1),
    letterSpacing: 0.1
)

drawInstallArrow(center: NSPoint(x: 320, y: 180))

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fail("failed to render PNG data")
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
