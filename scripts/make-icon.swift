// Draws the app icon and writes every size the asset catalog needs.
//
//     swift scripts/make-icon.swift
//
// The icon is the app in miniature: rows of text on a white tile, one under the
// highlighter, one struck through in red pen, and words added in blue.
// Coordinates are on the 1024-point macOS icon grid, measured from the top.

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

let ink = color(0x3E3E44)
let struck = color(0xCBCCD2)
let pen = color(0xE5483D)
let blue = color(0x3E86F0)
let highlighter = color(0xFFE14D)

/// The macOS icon shape: an 824-point square whose corners ease into the
/// sides instead of meeting them in a circular arc.
func tileShape() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 382.7, y: 100))
    path.addLine(to: CGPoint(x: 641.3, y: 100))
    path.addCurve(to: CGPoint(x: 924, y: 382.7), control1: CGPoint(x: 873.7, y: 100), control2: CGPoint(x: 924, y: 150.3))
    path.addLine(to: CGPoint(x: 924, y: 641.3))
    path.addCurve(to: CGPoint(x: 641.3, y: 924), control1: CGPoint(x: 924, y: 873.7), control2: CGPoint(x: 873.7, y: 924))
    path.addLine(to: CGPoint(x: 382.7, y: 924))
    path.addCurve(to: CGPoint(x: 100, y: 641.3), control1: CGPoint(x: 150.3, y: 924), control2: CGPoint(x: 100, y: 873.7))
    path.addLine(to: CGPoint(x: 100, y: 382.7))
    path.addCurve(to: CGPoint(x: 382.7, y: 100), control1: CGPoint(x: 100, y: 150.3), control2: CGPoint(x: 150.3, y: 100))
    path.closeSubpath()
    return path
}

/// A row of "text": a bar with round ends.
func bar(_ context: CGContext, x: CGFloat, top: CGFloat, width: CGFloat, fill: CGColor) {
    let height: CGFloat = 56
    let rect = CGRect(x: x, y: top, width: width, height: height)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
    context.setFillColor(fill)
    context.fillPath()
}

func drawIcon(in context: CGContext, scale: CGFloat) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let shape = tileShape()

    // The tile, with a soft shadow under it. Shadows are set in device pixels,
    // so they are scaled by hand; the y offset points down in the bitmap.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: color(0x000000, 0.22))
    context.addPath(shape)
    context.setFillColor(color(0xFCFCFD))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let paper = CGGradient(colorsSpace: space, colors: [color(0xFCFCFD), color(0xE4E4E8)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(paper, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    context.restoreGState()

    // The rim: light along the top edge, a faint shade along the bottom.
    context.saveGState()
    context.addPath(shape)
    context.setLineWidth(4)
    context.replacePathWithStrokedPath()
    context.clip()
    let rim = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF, 1), color(0xFFFFFF, 0), color(0x4A5060, 0.18)] as CFArray,
        locations: [0, 0.5, 1]
    )!
    context.drawLinearGradient(rim, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    context.restoreGState()

    // The highlighter: a swipe by hand, a little crooked and past the words.
    context.move(to: CGPoint(x: 204, y: 350))
    context.addLine(to: CGPoint(x: 628, y: 336))
    context.addLine(to: CGPoint(x: 632, y: 434))
    context.addLine(to: CGPoint(x: 208, y: 444))
    context.closePath()
    context.setFillColor(highlighter)
    context.fillPath()

    bar(context, x: 228, top: 244, width: 532, fill: ink)
    bar(context, x: 228, top: 364, width: 380, fill: ink)

    // A row struck out: the words recede and the pen stroke, not quite level,
    // runs past both ends.
    bar(context, x: 228, top: 484, width: 460, fill: struck)
    context.move(to: CGPoint(x: 206, y: 518))
    context.addCurve(to: CGPoint(x: 712, y: 502), control1: CGPoint(x: 360, y: 498), control2: CGPoint(x: 540, y: 530))
    context.setStrokeColor(pen)
    context.setLineWidth(18)
    context.setLineCap(.round)
    context.strokePath()

    // Words added in blue ink.
    bar(context, x: 228, top: 604, width: 148, fill: ink)
    bar(context, x: 420, top: 604, width: 236, fill: blue)

    bar(context, x: 228, top: 724, width: 340, fill: ink)
}

func render(size: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    let scale = CGFloat(size) / canvas
    // Draw top-down, as on the design grid.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)
    drawIcon(in: context, scale: scale)
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
