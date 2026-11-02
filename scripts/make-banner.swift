// Draws the README's banner: the name marked with a highlighter, the tagline
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

let background = rgb(0.984, 0.982, 0.975)
let ink = rgb(0.10, 0.10, 0.11)
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

/// A highlighter pen's stroke: the slanted ends of a chisel tip, edges that
/// waver a little, and darker bands where the pen went over it again.
func highlighterStroke(_ rect: NSRect, color: NSColor, degrees: CGFloat) {
    // A fixed wobble, so the banner comes out the same on every run.
    func wobble(_ x: CGFloat, _ seed: CGFloat) -> CGFloat {
        sin(x / 37 + seed) * 1.6 + sin(x / 11 + seed * 2.3) * 0.7
    }
    func pass(_ r: NSRect, alpha: CGFloat, seed: CGFloat) {
        let slant = r.height * 0.22
        let steps = 48
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX + slant, y: r.minY + wobble(r.minX, seed)))
        for i in 1...steps {
            let x = r.minX + slant + (r.width - slant) * CGFloat(i) / CGFloat(steps)
            path.line(to: NSPoint(x: x, y: r.minY + wobble(x, seed)))
        }
        for i in 0...steps {
            let x = r.maxX - slant - (r.width - slant) * CGFloat(i) / CGFloat(steps)
            path.line(to: NSPoint(x: x, y: r.maxY + wobble(x, seed + 1.3)))
        }
        path.close()
        color.withAlphaComponent(alpha).setFill()
        path.fill()
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.compositingOperation = .multiply
    let transform = NSAffineTransform()
    transform.translateX(by: rect.midX, yBy: rect.midY)
    transform.rotate(byDegrees: degrees)
    transform.translateX(by: -rect.midX, yBy: -rect.midY)
    transform.concat()
    pass(rect, alpha: 0.8, seed: 0.4)
    pass(NSRect(x: rect.minX + rect.width * 0.06, y: rect.minY + rect.height * 0.1, width: rect.width * 0.88, height: rect.height * 0.3), alpha: 0.22, seed: 2.1)
    pass(NSRect(x: rect.minX + rect.width * 0.02, y: rect.minY + rect.height * 0.64, width: rect.width * 0.9, height: rect.height * 0.24), alpha: 0.16, seed: 3.7)
    NSGraphicsContext.restoreGraphicsState()
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
    // Over the letters' middle, the way a pen marks a word: the tall letters rise above it.
    highlighterStroke(NSRect(x: left - 20, y: 172, width: nameWidth + 42, height: 92), color: highlighter, degrees: -1.2)
    draw("Callout", nameFont, ink, x: left, baseline: 188, kern: -1)

    let grey = rgb(0.30, 0.30, 0.33)
    line([
        Run(text: "Mark up what AI writes, the way a teacher ", color: grey),
        Run(text: "corrects", color: rgb(0.56, 0.56, 0.58), mark: .strike),
        Run(text: " ", color: grey),
        Run(text: "marks an essay.", color: ink, mark: .underline),
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

    // A faint edge, so the pale banner still shows its shape on GitHub's white page.
    let edge = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
    edge.lineWidth = 1
    rgb(0, 0, 0, 0.10).setStroke()
    edge.stroke()
}
NSGraphicsContext.restoreGraphicsState()

try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
