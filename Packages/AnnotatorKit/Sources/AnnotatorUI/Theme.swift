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

    /// The font with figures all of one width, so that the numbers of a column
    /// line up digit under digit.
    static func tabularFigures(_ font: NSFont) -> NSFont {
        let figures: [NSFontDescriptor.FeatureKey: Int] = [
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector,
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [figures]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
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

    // The colours below resolve when they are drawn, so one of each serves
    // every appearance; and a page with one colour object per kind of mark,
    // rather than one per run, compares and coalesces as the same.

    /// The highlighter behind marked words. A translucent yellow over a dark
    /// page turns olive, so in dark mode the wash stays faint and the words
    /// themselves take the highlighter's colour (see `highlightedText`).
    static func highlightWash(selected: Bool) -> NSColor {
        selected ? selectedHighlightWash : plainHighlightWash
    }

    private static let plainHighlightWash = makeHighlightWash(selected: false)
    private static let selectedHighlightWash = makeHighlightWash(selected: true)

    private static func makeHighlightWash(selected: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            if isDark(appearance) {
                return NSColor.systemYellow.withAlphaComponent(selected ? 0.3 : increasesContrast ? 0.2 : 0.13)
            }
            return NSColor.systemYellow.withAlphaComponent(selected ? 0.62 : increasesContrast ? 0.5 : 0.34)
        }
    }

    /// The colour of highlighted words: the page's ink in light mode, the
    /// highlighter's yellow in dark mode.
    static let highlightedText = NSColor(name: nil) { appearance in
        isDark(appearance) ? .systemYellow : .labelColor
    }

    /// The wash behind words marked to keep.
    static func keepWash(selected: Bool) -> NSColor {
        selected ? selectedKeepWash : plainKeepWash
    }

    private static let plainKeepWash = makeKeepWash(selected: false)
    private static let selectedKeepWash = makeKeepWash(selected: true)

    private static func makeKeepWash(selected: Bool) -> NSColor {
        NSColor(name: nil) { _ in
            NSColor.systemGreen.withAlphaComponent(selected ? 0.3 : increasesContrast ? 0.22 : 0.12)
        }
    }

    /// The tint behind text that is new since the previous version of a plan:
    /// purple, which is none of the reviewer's inks. A dark page needs more of
    /// it to show at all.
    static let revisionWash = NSColor(name: nil) { appearance in
        let base: CGFloat = isDark(appearance) ? 0.3 : 0.13
        return NSColor.systemPurple.withAlphaComponent(increasesContrast ? base + 0.12 : base)
    }

    /// The highlighter's colour for a small symbol. Yellow on a white page is
    /// too faint to read as a shape, so in light mode it is a darker amber.
    static var highlighterSymbol: NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? .systemYellow : NSColor(srgbRed: 0.72, green: 0.52, blue: 0.0, alpha: 1)
        }
    }

    /// Increase Contrast in Accessibility settings: tints get stronger.
    static var increasesContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func color(for kind: MarkKind) -> NSColor {
        switch kind {
        case .delete: pen
        case .replace, .insert: ink
        case .comment, .expand, .summarize: highlighter
        case .keep: keep
        }
    }

    // MARK: Page

    /// What a PDF's pages lie on, the margin notes beside them included.
    static var desk: NSColor {
        NSColor(name: "desk") { appearance in
            isDark(appearance) ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.91, alpha: 1)
        }
    }

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

    /// The mark's colour for a small symbol, which has to read against the page.
    var symbolTint: Color {
        switch self {
        case .comment, .expand, .summarize: Color(nsColor: Theme.highlighterSymbol)
        default: tint
        }
    }
}
