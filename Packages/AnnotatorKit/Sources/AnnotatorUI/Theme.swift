import AnnotatorCore
import AppKit
import SwiftUI

/// The look of the marked page: a serif reading text, and the four things on a
/// teacher's desk. Red pen strikes, blue ink is your own words, the highlighter
/// carries a comment, green says keep.
enum Theme {
    // MARK: Type

    static let bodySize: CGFloat = 16

    /// New York, the system serif, for the document.
    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        descriptor = descriptor.withDesign(.serif) ?? descriptor
        if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 28
        case 2: 22
        case 3: 18
        default: bodySize
        }
    }

    // MARK: Ink

    static var pen: NSColor { .systemRed }
    static var ink: NSColor { .systemBlue }
    static var highlighter: NSColor { .systemYellow }
    static var keep: NSColor { .systemGreen }
    /// What changed since the previous version. Not one of the reviewer's inks.
    static var revision: NSColor { .systemPurple }

    static func color(for kind: MarkKind) -> NSColor {
        switch kind {
        case .delete: pen
        case .replace, .insert: ink
        case .comment: highlighter
        case .keep: keep
        }
    }

    // MARK: Page

    /// Width of the text column: about seventy characters of body text.
    static let measure: CGFloat = 640
    static let minimumMeasure: CGFloat = 360
    static let gutter: CGFloat = 36
    static let marginWidth: CGFloat = 272
    static let narrowMarginWidth: CGFloat = 216
    static let pageTop: CGFloat = 20
    static let pageBottom: CGFloat = 72
    static let pageSide: CGFloat = 40

    // MARK: Panels behind code and tables

    /// Space between a panel's edge and its text, left and right.
    static let panelPadding: CGFloat = 14
    /// Space above and below the text, inside the panel.
    static let panelInset: CGFloat = 10
    /// Space between the panel and the neighbouring paragraphs.
    static let panelGap: CGFloat = 8
}

extension MarkKind {
    var tint: Color {
        Color(nsColor: Theme.color(for: self))
    }
}
