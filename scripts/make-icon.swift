// Renders a full-bleed square artwork into a macOS-style app icon PNG.
// Usage: swift scripts/make-icon.swift <source.png> <output.png> <size>
//
// Follows Apple's macOS icon grid: on a 1024 canvas the rounded square is
// 824x824, inset 100pt, corner radius ~185pt, with a soft drop shadow.
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]), let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift <source.png> <output.png> <size>\n".data(using: .utf8)!)
    exit(2)
}

let canvas = CGFloat(size)
let scale = canvas / 1024
let tileRect = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
let radius = 185.4 * scale

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

let tile = NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius)

// Drop shadow under the tile; skipped at tiny sizes where it only adds mud.
if size >= 64 {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 20 * scale
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.saveGraphicsState()
tile.addClip()
source.draw(in: tileRect, from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
