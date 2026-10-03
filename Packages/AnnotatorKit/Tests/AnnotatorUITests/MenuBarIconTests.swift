import AppKit
import Testing
@testable import AnnotatorUI

/// Set `ANNOTATOR_SNAPSHOT_DIR` to also write the icon at 8× for a look.
@Suite("Menu-bar icon")
struct MenuBarIconTests {
    /// The icon drawn into a bitmap; row 0 is the top.
    private func render(scale: Int) throws -> NSBitmapImageRep {
        let pixels = 18 * scale
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = MenuBarIcon.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        MenuBarIcon.image().draw(in: NSRect(origin: .zero, size: MenuBarIcon.size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    @Test func isATemplateTheSizeOfAMenuBarIcon() {
        let image = MenuBarIcon.image()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.accessibilityDescription == "Annotator")
    }

    @Test func isAnOutlinedTileWithRowsInside() throws {
        let bitmap = try render(scale: 2)
        // Opacity at a point on the 18-point grid, measured from the top left.
        func opacity(_ x: Double, _ y: Double) -> CGFloat {
            bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.alphaComponent ?? 0
        }
        #expect(opacity(1.75, 9) > 0.8, "the tile's left edge")
        #expect(opacity(5, 5.5) > 0.8, "the first row")
        #expect(opacity(13.5, 13.5) == 0, "empty inside the tile")
        #expect(opacity(0.25, 0.25) == 0, "outside the rounded corner")

        if let directory = ProcessInfo.processInfo.environment["ANNOTATOR_SNAPSHOT_DIR"] {
            let large = try render(scale: 8)
            try large.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("menu-bar-icon.png"))
        }
    }
}
