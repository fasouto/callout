// Draws the README's banner: the app icon, the name and what the app is for.
//
//     swift scripts/make-banner.swift
//
// Run after scripts/make-icon.swift, whose 1024-point icon it uses.

import AppKit

let size = NSSize(width: 1280, height: 400)
let scale: CGFloat = 2

func serif(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
    var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
    descriptor = descriptor.withDesign(.serif) ?? descriptor
    if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
    return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
}

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
    NSGradient(starting: NSColor(white: 0.985, alpha: 1), ending: NSColor(white: 0.925, alpha: 1))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    let icon = NSImage(contentsOfFile: "App/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")!
    icon.draw(in: NSRect(x: 96, y: (size.height - 280) / 2, width: 280, height: 280))

    let left: CGFloat = 420
    NSAttributedString(string: "Annotator", attributes: [
        .font: serif(80, weight: .bold), .foregroundColor: NSColor(white: 0.11, alpha: 1), .kern: -0.5,
    ]).draw(at: NSPoint(x: left, y: 196))
    NSAttributedString(string: "Mark up what Claude writes, the way a teacher marks an essay.", attributes: [
        .font: serif(27, italic: true), .foregroundColor: NSColor(white: 0.24, alpha: 1),
    ]).draw(at: NSPoint(x: left + 4, y: 150))
    NSAttributedString(string: "A native macOS app, and a plugin for Claude Code.", attributes: [
        .font: NSFont.systemFont(ofSize: 19), .foregroundColor: NSColor(white: 0.45, alpha: 1),
    ]).draw(at: NSPoint(x: left + 5, y: 112))
}
NSGraphicsContext.restoreGraphicsState()

try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/banner.png"))
print("Wrote docs/banner.png")
