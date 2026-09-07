import AppKit

@MainActor
enum StatusItemDesignSystem {
    enum Typography {
        static let valuePointSize: CGFloat = 8
        static let symbolPointSize: CGFloat = 18
        static let indicatorPointSize: CGFloat = 8

        static var valueFont: NSFont {
            .monospacedDigitSystemFont(ofSize: valuePointSize, weight: .medium)
        }

        static var symbolFont: NSFont {
            .systemFont(ofSize: symbolPointSize, weight: .medium)
        }

        static var indicatorFont: NSFont {
            .systemFont(ofSize: indicatorPointSize, weight: .semibold)
        }
    }

    enum Spacing {
        static let compact: CGFloat = 3
        static let codexRow: CGFloat = -3
        static let section: CGFloat = 7
    }

    enum Layout {
        static let maximumSize = NSSize(width: 170, height: 24)
        static let maximumValueText = "100%"
        static let providerIconPointSize: CGFloat = 15

        static func valueColumnWidth(using font: NSFont) -> CGFloat {
            ceil((maximumValueText as NSString).size(withAttributes: [.font: font]).width)
        }

        static func staleIndicatorWidth(for text: String, using font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
    }

    enum Palette {
        static var templateForeground: NSColor { .labelColor }
    }
}
