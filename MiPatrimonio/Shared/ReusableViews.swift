import SwiftUI
import UIKit

enum AppDesign {
    static let readableContentWidth: CGFloat = 840
    static let overviewContentWidth: CGFloat = 1_200
    static let compactRadius: CGFloat = 12
    static let cardRadius: CGFloat = 18
    static let heroRadius: CGFloat = 24
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    static let itemSpacing: CGFloat = 12

    static var pageBackground: Color {
        adaptiveColor(light: 0xF0F4F8, dark: 0x111D2B, elevated: 0x1A293A)
    }

    static var cardBackground: Color {
        adaptiveColor(light: 0xFFFFFF, dark: 0x203145, elevated: 0x2A3D53)
    }

    static var tertiaryBackground: Color {
        adaptiveColor(light: 0xE7EEF5, dark: 0x2B4056, elevated: 0x354D65)
    }

    static var accent: Color { adaptiveColor(light: 0x176B87, dark: 0x80DBDE) }
    static var income: Color { adaptiveColor(light: 0x176746, dark: 0x91E8BC) }
    static var expense: Color { adaptiveColor(light: 0xA72C40, dark: 0xFFB0BA) }
    static var savings: Color { adaptiveColor(light: 0x275D9E, dark: 0xAFD0FF) }
    static var investment: Color { adaptiveColor(light: 0x714698, dark: 0xD7BDFF) }
    static var warning: Color { adaptiveColor(light: 0x865000, dark: 0xFFD08A) }
    // Keep filled actions dark enough for their white labels in both appearances.
    static let actionFill = Color(hex: "#176B87")
    static var cardOutline: Color {
        Color(uiColor: UIColor { traits in
            if traits.accessibilityContrast == .high { return .separator }
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.40, green: 0.53, blue: 0.66, alpha: 0.45)
                : UIColor(red: 0.65, green: 0.73, blue: 0.81, alpha: 0.45)
        })
    }

    private static func adaptiveColor(light: UInt32, dark: UInt32, elevated: UInt32? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark
                ? (traits.userInterfaceLevel == .elevated ? elevated ?? dark : dark) : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

private struct FinanceCardSurface: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(AppDesign.cardBackground, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(AppDesign.cardOutline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func financeCardSurface(radius: CGFloat = AppDesign.cardRadius) -> some View {
        modifier(FinanceCardSurface(radius: radius))
    }
}

struct BankAccountIdentity: View {
    let account: FinancialAccount

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: account.bankSystemImage)
                .font(.title3)
                .foregroundStyle(Color(hex: account.institution?.colorHex ?? "#1F6B7A"))
                .frame(width: 44, height: 44)
                .background(Color(hex: account.institution?.colorHex ?? "#1F6B7A").opacity(0.12), in: RoundedRectangle(cornerRadius: AppDesign.compactRadius))
            VStack(alignment: .leading, spacing: 4) {
                Text(account.bankDisplayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(account.bankDisplayName == account.name ? account.type.title : account.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
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
    var usesTintedBackground = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.12), in: Circle())

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(usesTintedBackground ? tint : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .padding(AppDesign.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
                    .fill(AppDesign.cardBackground)
                if usesTintedBackground {
                    RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.14), tint.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                }
            }
        }
        .overlay {
            if usesTintedBackground {
                RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            }
        }
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
        .financeCardSurface()
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
            if let actionTitle, let action {
                AdaptiveValueRow {
                    titleBlock
                } value: {
                    Button(actionTitle, action: action)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            } else {
                titleBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            content
        }
        .padding(AppDesign.cardPadding)
        .financeCardSurface()
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
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
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Columns depend on the width proposed by the containing view and the user's text size.
struct AdaptiveCardGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var minimumColumnWidth: CGFloat = 350
    private let maximumColumns: Int
    private let spacing: CGFloat
    private let packsColumns: Bool
    private let content: Content

    init(
        minimumColumnWidth: CGFloat = 350,
        maximumColumns: Int = 2,
        spacing: CGFloat = 16,
        packsColumns: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        _minimumColumnWidth = ScaledMetric(wrappedValue: minimumColumnWidth, relativeTo: .body)
        self.maximumColumns = maximumColumns
        self.spacing = spacing
        self.packsColumns = packsColumns
        self.content = content()
    }

    var body: some View {
        AdaptiveCardLayout(
            minimumColumnWidth: minimumColumnWidth,
            maximumColumns: dynamicTypeSize.isAccessibilitySize ? 1 : maximumColumns,
            spacing: spacing,
            packsColumns: packsColumns
        ) {
            content
        }
    }
}

private struct AdaptiveCardLayout: Layout {
    let minimumColumnWidth: CGFloat
    let maximumColumns: Int
    let spacing: CGFloat
    let packsColumns: Bool

    private func columns(for width: CGFloat, count: Int) -> Int {
        let fitting = Int((width + spacing) / (Swift.max(1, minimumColumnWidth) + spacing))
        return Swift.max(1, Swift.min(Swift.min(maximumColumns, count), fitting))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = Swift.max(0, proposedWidth ?? minimumColumnWidth)
        let count = columns(for: width, count: subviews.count)
        let columnWidth = Swift.max(0, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
        if packsColumns {
            var columnHeights = Array(repeating: CGFloat.zero, count: count)
            for index in heights.indices {
                let column = index % count
                if index >= count { columnHeights[column] += spacing }
                columnHeights[column] += heights[index]
            }
            return CGSize(width: width, height: columnHeights.max() ?? 0)
        }
        var height: CGFloat = 0
        for start in stride(from: 0, to: heights.count, by: count) {
            if start > 0 { height += spacing }
            height += heights[start..<Swift.min(start + count, heights.count)].max() ?? 0
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = columns(for: bounds.width, count: subviews.count)
        let columnWidth = Swift.max(0, (bounds.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let cellProposal = ProposedViewSize(width: columnWidth, height: nil)
        if packsColumns {
            var columnY = Array(repeating: bounds.minY, count: count)
            for index in subviews.indices {
                let column = index % count
                let size = subviews[index].sizeThatFits(cellProposal)
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (columnWidth + spacing), y: columnY[column]),
                    anchor: .topLeading, proposal: cellProposal)
                columnY[column] += size.height + spacing
            }
            return
        }
        var rowY = bounds.minY
        var rowHeight: CGFloat = 0
        for index in subviews.indices {
            let column = index % count
            if column == 0 && index > 0 {
                rowY += rowHeight + spacing
                rowHeight = 0
            }
            let size = subviews[index].sizeThatFits(cellProposal)
            subviews[index].place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (columnWidth + spacing), y: rowY),
                anchor: .topLeading,
                proposal: cellProposal
            )
            rowHeight = Swift.max(rowHeight, size.height)
        }
    }
}

struct AdaptiveValueRow<LabelContent: View, ValueContent: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let label: LabelContent
    private let value: ValueContent

    init(@ViewBuilder label: () -> LabelContent, @ViewBuilder value: () -> ValueContent) {
        self.label = label()
        self.value = value()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            verticalContent
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    label.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    value.fixedSize(horizontal: true, vertical: false)
                }
                verticalContent
            }
        }
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            label
            value
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AdaptiveSummaryPair: View {
    let firstTitle: String
    let firstAmount: Int64
    let firstTint: Color
    let secondTitle: String
    let secondAmount: Int64
    let secondTint: Color

    var body: some View {
        AdaptiveValueRow {
            firstTile
        } value: {
            secondTile
        }
        .frame(minHeight: 54)
    }

    private var firstTile: some View {
        FinancialSummaryTile(title: firstTitle, minorUnits: firstAmount, tint: firstTint)
    }

    private var secondTile: some View {
        FinancialSummaryTile(title: secondTitle, minorUnits: secondAmount, tint: secondTint)
    }
}
