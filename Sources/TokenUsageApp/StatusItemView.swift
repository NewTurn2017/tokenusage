import AppKit

enum StatusItemIcon: String, CaseIterable, Sendable {
    case anthropic
    case codex
    case openrouter

    @MainActor
    private static var imageCache: [URL: NSImage] = [:]

    var fallbackMark: String {
        switch self {
        case .anthropic:
            StatusItemPresentation.claudeMark
        case .codex:
            StatusItemPresentation.codexMark
        case .openrouter:
            StatusItemPresentation.openRouterMark
        }
    }

    var accessibilityLabel: String {
        rawValue.capitalized
    }

    @MainActor
    func image() -> NSImage? {
        image(in: .main) ?? image(in: .module)
    }

    @MainActor
    func image(in bundle: Bundle) -> NSImage? {
        let url = bundle.url(
            forResource: rawValue,
            withExtension: "png",
            subdirectory: "MenuBarIcons"
        ) ?? bundle.url(forResource: rawValue, withExtension: "png")
        guard let url else { return nil }
        if let cachedImage = Self.imageCache[url] { return cachedImage }
        guard let image = NSImage(contentsOf: url) else { return nil }

        image.isTemplate = true
        image.size = NSSize(
            width: StatusItemDesignSystem.Layout.providerIconPointSize,
            height: StatusItemDesignSystem.Layout.providerIconPointSize
        )
        Self.imageCache[url] = image
        return image
    }

    @MainActor
    func makeView() -> NSView {
        makeView(in: nil)
    }

    @MainActor
    func makeView(in bundle: Bundle?) -> NSView {
        let loadedImage = bundle.map { image(in: $0) } ?? image()
        if let image = loadedImage {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.setAccessibilityLabel(accessibilityLabel)
            imageView.setAccessibilityIdentifier("token-usage-\(rawValue)-icon")
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(
                    equalToConstant: StatusItemDesignSystem.Layout.providerIconPointSize
                ),
                imageView.heightAnchor.constraint(
                    equalToConstant: StatusItemDesignSystem.Layout.providerIconPointSize
                ),
            ])
            return imageView
        }

        let label = NSTextField(labelWithString: fallbackMark)
        label.font = StatusItemDesignSystem.Typography.symbolFont
        label.textColor = StatusItemDesignSystem.Palette.templateForeground
        label.alignment = .center
        label.setAccessibilityLabel(accessibilityLabel)
        label.setAccessibilityIdentifier("token-usage-\(rawValue)-icon")
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(
                equalToConstant: StatusItemDesignSystem.Layout.providerIconPointSize
            ),
            label.heightAnchor.constraint(
                equalToConstant: StatusItemDesignSystem.Layout.providerIconPointSize
            ),
        ])
        return label
    }
}

@MainActor
final class StatusItemView: NSView {
    private let claudeIconView: NSView
    private let claudeStack: NSStackView
    private var claudeProfileColumns: [NSStackView] = []
    private let codexIconView: NSView
    private let codexStack: NSStackView
    private var codexWeeklyLabels: [NSTextField] = []
    private let openRouterIconView: NSView
    private let openRouterBalanceLabel: NSTextField
    private let staleIndicatorLabel: NSTextField
    private let contentStack: NSStackView

    private(set) var presentation: StatusItemPresentation

    var templateForegroundColor: NSColor {
        StatusItemDesignSystem.Palette.templateForeground
    }

    var valueFont: NSFont {
        StatusItemDesignSystem.Typography.valueFont
    }

    init(presentation: StatusItemPresentation) {
        self.presentation = presentation

        let claudeIconView = StatusItemIcon.anthropic.makeView()
        self.claudeIconView = claudeIconView
        let claudeStack = NSStackView()
        claudeStack.orientation = .horizontal
        claudeStack.alignment = .centerY
        claudeStack.spacing = StatusItemDesignSystem.Spacing.compact
        self.claudeStack = claudeStack
        let codexIconView = StatusItemIcon.codex.makeView()
        self.codexIconView = codexIconView
        let codexStack = NSStackView()
        codexStack.orientation = .vertical
        codexStack.alignment = .leading
        codexStack.spacing = StatusItemDesignSystem.Spacing.codexRow
        self.codexStack = codexStack
        let openRouterIconView = StatusItemIcon.openrouter.makeView()
        self.openRouterIconView = openRouterIconView
        openRouterBalanceLabel = Self.label(
            text: presentation.openRouterBalanceText ?? "",
            font: StatusItemDesignSystem.Typography.valueFont,
            accessibilityLabel: "OpenRouter remaining credit"
        )
        openRouterBalanceLabel.setAccessibilityIdentifier("token-usage-openrouter-balance")
        staleIndicatorLabel = Self.label(
            text: StatusItemPresentation.staleIndicator,
            font: StatusItemDesignSystem.Typography.indicatorFont,
            accessibilityLabel: "Usage data is stale"
        )

        contentStack = NSStackView(views: [
            claudeIconView,
            claudeStack,
            codexIconView,
            codexStack,
            openRouterIconView,
            openRouterBalanceLabel,
            staleIndicatorLabel,
        ])
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = StatusItemDesignSystem.Spacing.compact
        contentStack.setCustomSpacing(StatusItemDesignSystem.Spacing.section, after: claudeStack)
        contentStack.setCustomSpacing(StatusItemDesignSystem.Spacing.section, after: codexStack)

        super.init(frame: .zero)

        let staleWidth = StatusItemDesignSystem.Layout.staleIndicatorWidth(
            for: StatusItemPresentation.staleIndicator,
            using: StatusItemDesignSystem.Typography.indicatorFont
        )
        NSLayoutConstraint.activate([
            staleIndicatorLabel.widthAnchor.constraint(equalToConstant: staleWidth),
        ])

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        update(with: presentation)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusItemView is created programmatically")
    }

    override var intrinsicContentSize: NSSize {
        let fittingSize = contentStack.fittingSize
        return NSSize(
            width: ceil(fittingSize.width),
            height: min(ceil(fittingSize.height), NSStatusBar.system.thickness)
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func renderedImage(appearance: NSAppearance) -> NSImage {
        self.appearance = appearance
        let size = intrinsicContentSize
        frame = NSRect(origin: .zero, size: size)
        layoutSubtreeIfNeeded()

        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: size)
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        image.isTemplate = true
        return image
    }

    func update(with presentation: StatusItemPresentation) {
        self.presentation = presentation
        for column in claudeProfileColumns {
            claudeStack.removeArrangedSubview(column)
            column.removeFromSuperview()
        }
        for label in codexWeeklyLabels {
            codexStack.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        let valueWidth = StatusItemDesignSystem.Layout.valueColumnWidth(
            using: StatusItemDesignSystem.Typography.valueFont
        )
        claudeProfileColumns = presentation.claudeProfiles.map { profile in
            let fiveHour = Self.label(
                text: profile.fiveHourText,
                font: StatusItemDesignSystem.Typography.valueFont,
                accessibilityLabel: "Claude \(profile.name) five hour remaining"
            )
            let weekly = Self.label(
                text: profile.weeklyText,
                font: StatusItemDesignSystem.Typography.valueFont,
                accessibilityLabel: "Claude \(profile.name) \(profile.weeklyAccessibilityName) remaining"
            )
            fiveHour.setAccessibilityIdentifier("token-usage-claude-\(profile.profileID)-five-hour")
            weekly.setAccessibilityIdentifier("token-usage-claude-\(profile.profileID)-weekly")
            fiveHour.widthAnchor.constraint(equalToConstant: valueWidth).isActive = true
            weekly.widthAnchor.constraint(equalToConstant: valueWidth).isActive = true
            let column = NSStackView(views: [fiveHour, weekly])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = .zero
            return column
        }
        claudeProfileColumns.forEach(claudeStack.addArrangedSubview)
        codexWeeklyLabels = presentation.codexProfiles.map { profile in
            let label = Self.label(
                text: profile.weeklyText,
                font: StatusItemDesignSystem.Typography.valueFont,
                accessibilityLabel: "Codex \(profile.name) weekly remaining"
            )
            label.setAccessibilityIdentifier("token-usage-codex-\(profile.profileID)-quota")
            label.widthAnchor.constraint(equalToConstant: valueWidth).isActive = true
            return label
        }
        codexWeeklyLabels.forEach(codexStack.addArrangedSubview)
        openRouterBalanceLabel.stringValue = presentation.openRouterBalanceText ?? ""
        openRouterBalanceLabel.isHidden = presentation.openRouterBalanceText == nil
        openRouterIconView.isHidden = presentation.openRouterBalanceText == nil
        staleIndicatorLabel.alphaValue = presentation.isStale ? 1 : 0
        staleIndicatorLabel.setAccessibilityElement(presentation.isStale)
        setAccessibilityLabel(accessibilityDescription(for: presentation))
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private static func label(
        text: String,
        font: NSFont,
        accessibilityLabel: String
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = StatusItemDesignSystem.Palette.templateForeground
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setAccessibilityLabel(accessibilityLabel)
        return label
    }

    private func accessibilityDescription(for presentation: StatusItemPresentation) -> String {
        let codexDescription = presentation.codexProfiles.isEmpty
            ? "no profiles"
            : presentation.codexProfiles
                .map { "\($0.name) \($0.weeklyText)" }
                .joined(separator: ", ")
        let claudeDescription = presentation.claudeProfiles.isEmpty
            ? "no accounts"
            : presentation.claudeProfiles
                .map {
                    "\($0.name) \($0.fiveHourText), \($0.weeklyAccessibilityName) \($0.weeklyText)"
                }
                .joined(separator: ", ")
        var description = "Claude \(claudeDescription); Codex \(codexDescription)"
        if let balance = presentation.openRouterBalanceText {
            description += "; OpenRouter \(balance)"
        }
        if presentation.isStale {
            description += "; usage data is stale"
        }
        return description
    }
}
