// Draws the app icon and writes every size the asset catalog needs.
//
//     swift scripts/make-icon.swift
//
// The icon is the app in miniature: a page of text with one phrase struck in
// red pen, the words that replace it in blue ink, and a line under the highlighter.

import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// A bar of "text": a rounded rectangle, measured from the top of the canvas.
func bar(_ context: CGContext, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, fill: CGColor) {
    let rect = CGRect(x: x, y: canvas - top - height, width: width, height: height)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
    context.setFillColor(fill)
    context.fillPath()
}

func drawIcon(in context: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // The sheet: the standard macOS icon shape, with a soft shadow under it.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    context.addPath(shape)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let paper = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xEEEEEA)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(paper, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    let ink = color(0x1D1D1F, 0.9)
    let faded = color(0x1D1D1F, 0.26)
    let left: CGFloat = 214

    // A heading, then three lines of text.
    bar(context, x: left, top: 280, width: 330, height: 74, fill: ink)

    // Line one: some text, a phrase struck out, and the words that replace it.
    let first: CGFloat = 442
    bar(context, x: left, top: first, width: 196, height: 52, fill: ink)
    bar(context, x: left + 234, top: first, width: 160, height: 52, fill: faded)
    bar(context, x: left + 436, top: first, width: 160, height: 52, fill: color(0x0A7AFF))

    // Line two: under the highlighter.
    let second: CGFloat = 562
    let highlight = CGRect(x: left - 22, y: canvas - second - 52 - 20, width: 430, height: 92)
    context.addPath(CGPath(roundedRect: highlight, cornerWidth: 22, cornerHeight: 22, transform: nil))
    context.setFillColor(color(0xFFD426, 0.62))
    context.fillPath()
    bar(context, x: left, top: second, width: 386, height: 52, fill: ink)
    bar(context, x: left + 416, top: second, width: 150, height: 52, fill: ink)

    // Line three.
    bar(context, x: left, top: 682, width: 300, height: 52, fill: ink)

    // The pen stroke: drawn by hand, so not quite level, and a little past the
    // phrase at both ends without touching its neighbours.
    context.setStrokeColor(color(0xFF3B30))
    context.setLineWidth(28)
    context.setLineCap(.round)
    let strikeY = canvas - first - 26
    context.move(to: CGPoint(x: left + 224, y: strikeY - 8))
    context.addCurve(
        to: CGPoint(x: left + 404, y: strikeY + 9),
        control1: CGPoint(x: left + 286, y: strikeY + 6),
        control2: CGPoint(x: left + 344, y: strikeY - 7)
    )
    context.strokePath()
    context.restoreGState()

    // A hairline keeps the sheet's edge crisp on light backgrounds.
    context.addPath(shape)
    context.setStrokeColor(color(0x000000, 0.08))
    context.setLineWidth(2)
    context.strokePath()
}

func render(size: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: context)
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Assets.xcassets")
let iconset = root.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: points * scale).write(to: iconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let info: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) images to \(iconset.path)")
