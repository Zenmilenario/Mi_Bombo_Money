import Foundation
import SwiftData

enum CategoryDefaultsService {
    private static let installationKey = "didInstallDefaultCategoriesV1"

    private struct Template {
        let name: String
        let kind: CategoryKind
        let symbol: String
        let color: String
    }

    private static let cashTemplates: [Template] = [
        .init(name: "Retirada de efectivo", kind: .expense, symbol: "banknote", color: "#B37970"),
        .init(name: "Ingreso de efectivo", kind: .income, symbol: "banknote.fill", color: "#55A78A")
    ]

    private static let templates: [Template] = [
        .init(name: "Vivienda", kind: .expense, symbol: "house.fill", color: "#6677A8"),
        .init(name: "Supermercado", kind: .expense, symbol: "basket.fill", color: "#4F9D69"),
        .init(name: "Restaurantes", kind: .expense, symbol: "fork.knife", color: "#DA814B"),
        .init(name: "Transporte", kind: .expense, symbol: "tram.fill", color: "#478FAA"),
        .init(name: "Coche", kind: .expense, symbol: "car.fill", color: "#667D99"),
        .init(name: "Salud", kind: .expense, symbol: "cross.case.fill", color: "#CC6879"),
        .init(name: "Farmacia", kind: .expense, symbol: "pills.fill", color: "#8A78BA"),
        .init(name: "Educación", kind: .expense, symbol: "graduationcap.fill", color: "#6D78C5"),
        .init(name: "Servicios del hogar", kind: .expense, symbol: "bolt.fill", color: "#D6A341"),
        .init(name: "Internet y móvil", kind: .expense, symbol: "wifi", color: "#5786B1"),
        .init(name: "Seguros", kind: .expense, symbol: "shield.fill", color: "#7590A3"),
        .init(name: "Impuestos y comisiones", kind: .expense, symbol: "percent", color: "#B37970"),
        .init(name: "Suscripciones", kind: .expense, symbol: "repeat", color: "#9A72BA"),
        .init(name: "Compras", kind: .expense, symbol: "bag.fill", color: "#B8799D"),
        .init(name: "Ropa", kind: .expense, symbol: "tshirt.fill", color: "#A679A8"),
        .init(name: "Ocio", kind: .expense, symbol: "gamecontroller.fill", color: "#8A83CA"),
        .init(name: "Viajes", kind: .expense, symbol: "airplane", color: "#4D9CB0"),
        .init(name: "Mascotas", kind: .expense, symbol: "pawprint.fill", color: "#AB865D"),
        .init(name: "Regalos", kind: .expense, symbol: "gift.fill", color: "#C87987"),
        .init(name: "Otros gastos", kind: .expense, symbol: "ellipsis.circle.fill", color: "#818B99"),
        .init(name: "Nómina", kind: .income, symbol: "eurosign.circle.fill", color: "#3B9B78"),
        .init(name: "Otros ingresos", kind: .income, symbol: "arrow.down.circle.fill", color: "#55A78A"),
        .init(name: "Reembolsos", kind: .income, symbol: "arrow.uturn.backward.circle.fill", color: "#56A9A2"),
        .init(name: "Intereses", kind: .income, symbol: "chart.line.uptrend.xyaxis", color: "#4B9C8B"),
        .init(name: "Dividendos", kind: .income, symbol: "chart.bar.fill", color: "#5F9B65"),
        .init(name: "Ventas", kind: .income, symbol: "tag.fill", color: "#7AAB72"),
        .init(name: "Transferencias", kind: .transfer, symbol: "arrow.left.arrow.right.circle.fill", color: "#638BA6")
    ] + cashTemplates

    static func installIfNeeded(in context: ModelContext) throws {
        guard !UserDefaults.standard.bool(forKey: installationKey) else { return }
        try restoreMissing(in: context)
        UserDefaults.standard.set(true, forKey: installationKey)
    }

    static func restoreMissing(in context: ModelContext, stableIDs: Bool = false) throws {
        try restoreMissing(in: context, stableIDs: stableIDs, startingAt: 0)
    }

    static func hasMissingCashCategories(in categories: [FinanceCategory]) -> Bool {
        let keys = Set(categories.map { key(for: $0.name, kind: $0.kind) })
        return cashTemplates.contains { !keys.contains(key(for: $0.name, kind: $0.kind)) }
    }

    static func restoreMissingCashCategories(in context: ModelContext, stableIDs: Bool) throws {
        try restoreMissing(in: context, stableIDs: stableIDs, startingAt: templates.count - cashTemplates.count)
    }

    private static func restoreMissing(in context: ModelContext, stableIDs: Bool, startingAt firstIndex: Int) throws {
        let existing = try context.fetch(FetchDescriptor<FinanceCategory>())
        var names = Set(existing.map { normalized($0.name) })
        var keys = Set(existing.map { key(for: $0.name, kind: $0.kind) })
        let existingIDs = Set(existing.map(\.id))

        for index in firstIndex..<templates.count {
            let template = templates[index]
            let isCash = index >= templates.count - cashTemplates.count
            let missing = isCash ? keys.insert(key(for: template.name, kind: template.kind)).inserted
                : names.insert(normalized(template.name)).inserted
            guard missing else { continue }
            let defaultID = stableID(at: index)
            context.insert(FinanceCategory(
                id: stableIDs && !existingIDs.contains(defaultID) ? defaultID : UUID(),
                name: template.name,
                kind: template.kind,
                systemImage: template.symbol,
                colorHex: template.color,
                sortOrder: existing.count + index - firstIndex
            ))
        }

        try context.save()
    }

    // A reset removes financial records but leaves the category catalog ready to use.
    static func insertDefaults(in context: ModelContext, stableIDs: Bool = false) {
        for (index, template) in templates.enumerated() {
            context.insert(FinanceCategory(
                id: stableIDs ? stableID(at: index) : UUID(),
                name: template.name,
                kind: template.kind,
                systemImage: template.symbol,
                colorHex: template.color,
                sortOrder: index
            ))
        }
    }

    private static func key(for name: String, kind: CategoryKind) -> String {
        "\(kind.rawValue):\(normalized(name))"
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
    }

    private static func stableID(at index: Int) -> UUID {
        UUID(uuidString: String(format: "B0B00000-DEFA-4000-8000-%012d", index + 1))!
    }
}
