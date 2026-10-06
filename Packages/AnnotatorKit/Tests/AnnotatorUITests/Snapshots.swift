import AppKit

extension NSView {
    /// A picture of the view at two pixels a point, whatever screen the tests
    /// run on, so the screenshots in the README come out the same everywhere.
    @MainActor func snapshotBitmap() -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = bounds.size
        cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }
}

/// A window that draws at two pixels a point even with no Retina screen
/// attached, so SwiftUI's layers come out as sharp as the text.
final class SnapshotWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}
