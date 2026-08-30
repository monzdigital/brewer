#!/usr/bin/swift
// Renders the Brewer app icon (amber squircle + white mug) and packs it into
// packaging/AppIcon.icns using iconutil. Run: swift scripts/make-icon.swift
import AppKit

let canvasSize: CGFloat = 1024

func renderMaster() -> NSImage {
    let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
    image.lockFocus()

    // Big Sur style: icon shape is ~824pt centered on a 1024 canvas.
    let inset: CGFloat = 100
    let rect = NSRect(x: inset, y: inset, width: canvasSize - inset * 2, height: canvasSize - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

    // Subtle drop shadow.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(calibratedRed: 0.72, green: 0.45, blue: 0.12, alpha: 1).setFill()
    path.fill()
    NSShadow().set()

    // Amber gradient fill.
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.97, green: 0.78, blue: 0.35, alpha: 1),
        ending: NSColor(calibratedRed: 0.76, green: 0.47, blue: 0.11, alpha: 1)
    )!
    gradient.draw(in: path, angle: -90)

    // Inner highlight.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 177, yRadius: 177)
    highlight.lineWidth = 10
    highlight.stroke()

    // White mug symbol.
    if let symbol = NSImage(systemSymbolName: "mug.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 430, weight: .medium)) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        let symbolRect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: symbolRect)
        NSColor.white.set()
        symbolRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        let scale = min(rect.width * 0.62 / tinted.size.width, rect.height * 0.62 / tinted.size.height)
        let drawSize = NSSize(width: tinted.size.width * scale, height: tinted.size.height * scale)
        let origin = NSPoint(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2
        )
        tinted.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    image.unlockFocus()
    return image
}

func pngData(from image: NSImage, size: Int) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let master = renderMaster()
let fileManager = FileManager.default
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let root = scriptDir.deletingLastPathComponent()
let iconsetURL = root.appendingPathComponent("packaging/AppIcon.iconset")
try? fileManager.removeItem(at: iconsetURL)
try! fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, size) in entries {
    guard let data = pngData(from: master, size: size) else {
        fputs("Failed to render \(name)\n", stderr)
        exit(1)
    }
    try! data.write(to: iconsetURL.appendingPathComponent(name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetURL.path, "-o", root.appendingPathComponent("packaging/AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
try? fileManager.removeItem(at: iconsetURL)
print(task.terminationStatus == 0 ? "AppIcon.icns written." : "iconutil failed (\(task.terminationStatus)).")
exit(task.terminationStatus)
