import SwiftUI
import TokenUsageCore

/// The compact menu-bar surface's shared visual language.
enum PopoverDesignSystem {
    enum Spacing {
        static let xxSmall: CGFloat = 2
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    enum Size {
        static let popoverWidth: CGFloat = 384
        static let progressHeight: CGFloat = 3
        static let providerIcon: CGFloat = 14
        static let actionIcon: CGFloat = 12
        static let compactProgressWidth: CGFloat = 72
        static let claudeAccountRowHeight: CGFloat = 70
        static let codexAccountRowHeight: CGFloat = 62
    }

    enum Radius {
        static let section: CGFloat = 10
    }

    enum Opacity {
        static let sectionFill: Double = 0.07
        static let activeFill: Double = 0.12
        static let border: Double = 0.16
        static let track: Double = 0.12
        static let badge: Double = 0.14
    }

    enum Scale {
        static let minimumText: CGFloat = 0.78
    }

    enum Provider {
        case claude
        case codex
        case openRouter

        var accent: Color {
            switch self {
            case .claude:
                Color(nsColor: .systemOrange)
            case .codex:
                Color(nsColor: .systemTeal)
            case .openRouter:
                Color(nsColor: .systemIndigo)
            }
        }
    }

    enum Palette {
        static let primary = Color.primary
        static let secondary = Color.secondary
        static let warning = Color(nsColor: .systemOrange)
        static let danger = Color(nsColor: .systemRed)
        static let success = Color(nsColor: .systemGreen)
        static let divider = Color.primary.opacity(Opacity.border)
        static let track = Color.primary.opacity(Opacity.track)
        static let transparent = Color.clear

        static func section(_ provider: Provider) -> Color {
            provider.accent.opacity(Opacity.sectionFill)
        }

        static func quota(
            _ presentation: QuotaWindowPresentation,
            provider: Provider
        ) -> Color {
            if let fraction = presentation.remainingFraction {
                if fraction <= 0.1 { return danger }
                if fraction <= 0.25 { return warning }
            }
            switch presentation.pace {
            case .overspending, .exhausted:
                return danger
            case .onTrack:
                return success
            case .comfortable, .unknown:
                return provider.accent
            }
        }
    }

    /// The system face keeps Latin and Hangul consistent while monospaced digits make quota
    /// columns line up at a glance.
    enum Typography {
        static let title = Font.system(.headline, weight: .bold)
        static let section = Font.system(.subheadline, weight: .bold)
        static let metric = Font.system(.body, weight: .bold)
        static let body = Font.system(.body)
        static let detail = Font.system(.caption)
        static let detailStrong = Font.system(.caption, weight: .semibold)
    }
}

struct ProviderPanelModifier: ViewModifier {
    let provider: PopoverDesignSystem.Provider

    func body(content: Content) -> some View {
        content
            .padding(PopoverDesignSystem.Spacing.medium)
            .background(PopoverDesignSystem.Palette.section(provider))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PopoverDesignSystem.Radius.section,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: PopoverDesignSystem.Radius.section,
                    style: .continuous
                )
                .stroke(provider.accent.opacity(PopoverDesignSystem.Opacity.border))
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(provider.accent)
                    .frame(width: PopoverDesignSystem.Spacing.xxSmall)
                    .padding(.vertical, PopoverDesignSystem.Spacing.medium)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    func providerPanel(_ provider: PopoverDesignSystem.Provider) -> some View {
        modifier(ProviderPanelModifier(provider: provider))
    }
}
