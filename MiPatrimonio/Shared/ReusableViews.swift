import SwiftUI

enum AppDesign {
    static let compactRadius: CGFloat = 12
    static let cardRadius: CGFloat = 18
    static let heroRadius: CGFloat = 24
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 24
    static let itemSpacing: CGFloat = 12

    static var pageBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    static var cardBackground: Color {
        Color(uiColor: .secondarySystemGroupedBackground)
    }

    static var tertiaryBackground: Color {
        Color(uiColor: .tertiarySystemGroupedBackground)
    }
}

struct PrivacyAmountText: View {
    let minorUnits: Int64
    var currencyCode: String = "EUR"
    var font: Font = .body
    var weight: Font.Weight = .regular
    var signed: Bool = false

    @AppStorage("hideAmounts") private var hideAmounts = false

    var body: some View {
        Text(displayValue)
            .font(font)
            .fontWeight(weight)
            .contentTransition(.numericText())
            .accessibilityLabel(
                hideAmounts
                    ? "Importe oculto"
                    : MoneyFormatter.string(minorUnits: minorUnits, currencyCode: currencyCode)
            )
    }

    private var displayValue: String {
        guard !hideAmounts else { return "••••••" }
        let value = MoneyFormatter.string(
            minorUnits: Swift.abs(minorUnits),
            currencyCode: currencyCode
        )
        guard signed else {
            return MoneyFormatter.string(minorUnits: minorUnits, currencyCode: currencyCode)
        }
        if minorUnits > 0 { return "+\(value)" }
        if minorUnits < 0 { return "−\(value)" }
        return value
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.12), in: Circle())

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(AppDesign.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .background(
            AppDesign.cardBackground,
            in: RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
        )
    }
}

struct EmptyStateCard: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
        .frame(maxWidth: .infinity, minHeight: 170)
        .background(
            AppDesign.cardBackground,
            in: RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
        )
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let actionTitle: String?
    let action: (() -> Void)?
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }

            content
        }
        .padding(AppDesign.cardPadding)
        .background(
            AppDesign.cardBackground,
            in: RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
        )
    }
}

struct StatusPill: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.11), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct FilterChip: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .accentColor
    var onRemove: (() -> Void)? = nil

    var body: some View {
        Button {
            onRemove?()
        } label: {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
                if onRemove != nil {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(tint.opacity(0.11), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(onRemove == nil)
        .accessibilityLabel(onRemove == nil ? title : "\(title), eliminar filtro")
    }
}

struct FinancialSummaryTile: View {
    let title: String
    let minorUnits: Int64
    var currencyCode: String = "EUR"
    var tint: Color = .accentColor
    var signed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            PrivacyAmountText(
                minorUnits: minorUnits,
                currencyCode: currencyCode,
                font: .headline,
                weight: .semibold,
                signed: signed
            )
            .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
