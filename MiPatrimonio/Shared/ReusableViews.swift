import SwiftUI

struct PrivacyAmountText: View {
    let minorUnits: Int64
    var currencyCode: String = "EUR"
    var font: Font = .body
    var weight: Font.Weight = .regular

    @AppStorage("hideAmounts") private var hideAmounts = false

    var body: some View {
        Text(hideAmounts ? "••••••" : MoneyFormatter.string(minorUnits: minorUnits, currencyCode: currencyCode))
            .font(font)
            .fontWeight(weight)
            .contentTransition(.numericText())
            .accessibilityLabel(hideAmounts ? "Importe oculto" : MoneyFormatter.string(minorUnits: minorUnits, currencyCode: currencyCode))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding()
        .frame(width: 170, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 28, height: 28)
                .padding(10)
        }
    }
}

struct EmptyStateCard: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
