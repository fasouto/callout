// Draws the README's banner: the name on a highlighter stripe, the tagline
// corrected the way Callout marks text, and the app icon.
//
//     swift scripts/make-banner.swift [output.png] [dark]
//
// Without an output path it writes docs/banner.png. "dark" puts the banner on GitHub's dark
// page colour, to check how its rounded corners look there. Run from the repo root, after
// scripts/make-icon.swift, whose 1024-point icon it uses.

import AppKit

let size = NSSize(width: 1280, height: 400)
let scale: CGFloat = 2
let radius: CGFloat = 30

let arguments = Array(CommandLine.arguments.dropFirst()).filter { $0 != "dark" }
let output = arguments.first ?? "docs/banner.png"
let onDark = CommandLine.arguments.contains("dark")

func serif(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
    var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
    descriptor = descriptor.withDesign(.serif) ?? descriptor
    if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
    return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let background = rgb(0.075, 0.078, 0.09)
let highlighter = rgb(1.0, 0.87, 0.25)
let pen = rgb(0.91, 0.30, 0.25)
let green = rgb(0.20, 0.78, 0.35)
let icon = NSImage(contentsOfFile: "App/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")!

struct Run {
    var text: String
    var color: NSColor
    var mark: Mark = .none
    enum Mark { case none, strike, underline }
}

/// Draws text with its baseline at `baseline`; returns the width it took.
@discardableResult
func draw(_ text: String, _ font: NSFont, _ color: NSColor, x: CGFloat, baseline: CGFloat, kern: CGFloat = 0) -> CGFloat {
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    string.draw(at: NSPoint(x: x, y: baseline + font.descender))
    return string.size().width
}

/// A hand-drawn looking line, the way a pen crosses out or underlines words.
func penLine(from a: NSPoint, to b: NSPoint, color: NSColor, width lineWidth: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.move(to: a)
    path.curve(to: b,
               controlPoint1: NSPoint(x: a.x + (b.x - a.x) * 0.3, y: a.y + 2.5),
               controlPoint2: NSPoint(x: a.x + (b.x - a.x) * 0.7, y: b.y - 2.5))
    color.setStroke()
    path.stroke()
}

/// A highlighter stroke, slightly off square like the one in the icon.
func marker(_ rect: NSRect, color: NSColor, tilt: CGFloat) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: rect.minY - tilt))
    path.line(to: NSPoint(x: rect.maxX, y: rect.minY + tilt))
    path.line(to: NSPoint(x: rect.maxX + 1, y: rect.maxY + tilt))
    path.line(to: NSPoint(x: rect.minX - 1, y: rect.maxY - tilt))
    path.close()
    color.setFill()
    path.fill()
}

/// Lays runs out in one line, struck or underlined as marked.
func line(_ runs: [Run], font: NSFont, x: CGFloat, baseline: CGFloat) {
    var cursor = x
    for run in runs {
        let w = draw(run.text, font, run.color, x: cursor, baseline: baseline)
        switch run.mark {
        case .strike:
            penLine(from: NSPoint(x: cursor + 1, y: baseline + font.pointSize * 0.3),
                    to: NSPoint(x: cursor + w + 2, y: baseline + font.pointSize * 0.33), color: pen, width: 2.6)
        case .underline:
            penLine(from: NSPoint(x: cursor, y: baseline - 5), to: NSPoint(x: cursor + w, y: baseline - 4), color: green, width: 2.4)
        case .none:
            break
        }
        cursor += w
    }
}

func drawIcon(center: NSPoint, side: CGFloat, degrees: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: degrees)
    transform.concat()
    icon.draw(in: NSRect(x: -side / 2, y: -side / 2, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
}

func drawBanner() {
    background.setFill()
    NSRect(origin: .zero, size: size).fill()

    drawIcon(center: NSPoint(x: 1100, y: 205), side: 400, degrees: 7)

    let left: CGFloat = 88
    let nameFont = serif(132, weight: .black)
    let nameWidth = NSAttributedString(string: "Callout", attributes: [.font: nameFont]).size().width - 6
    marker(NSRect(x: left - 18, y: 168, width: nameWidth + 40, height: 130), color: highlighter, tilt: 1.5)
    draw("Callout", nameFont, background, x: left, baseline: 188, kern: -1)

    let grey = rgb(0.80, 0.80, 0.83)
    line([
        Run(text: "Mark up what AI writes, the way a teacher ", color: grey),
        Run(text: "corrects", color: rgb(0.52, 0.52, 0.55), mark: .strike),
        Run(text: " ", color: grey),
        Run(text: "marks an essay.", color: .white, mark: .underline),
    ], font: serif(30, italic: true), x: left + 2, baseline: 104)
}

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
    if onDark {
        rgb(0.051, 0.067, 0.09).setFill()
        NSRect(origin: .zero, size: size).fill()
    }
    // The corners outside the rounded rectangle stay transparent, for GitHub's light and dark pages.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius).addClip()
    drawBanner()
    NSGraphicsContext.restoreGraphicsState()

    // A faint edge, so the dark banner still shows its shape on GitHub's dark page.
    let edge = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
    edge.lineWidth = 1
    rgb(1, 1, 1, 0.14).setStroke()
    edge.stroke()
}
NSGraphicsContext.restoreGraphicsState()

try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
