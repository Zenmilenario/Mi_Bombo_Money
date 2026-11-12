import Foundation

@main
struct TransactionCategoryModelCheck {
    static func main() {
        let categories = Dictionary(uniqueKeysWithValues: TransactionCategoryModel.syntheticExamples.enumerated().map { index, entry in
            (entry.0, UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!)
        })
        let examples = TransactionCategoryModel.syntheticExamples.flatMap { name, descriptions in
            descriptions.map { TransactionCategoryModel.Example(text: $0, categoryID: categories[name]!, weight: 1) }
        }
        let incomeNames = ["Nómina", "Reembolsos", "Intereses", "Dividendos", "Ventas", "Ingreso de efectivo"]
        let income = Set(incomeNames.map { categories[$0]! })
        let expenses = Set(categories.values).subtracting(income)
        let model = TransactionCategoryModel.train(examples.filter { expenses.contains($0.categoryID) })!
        let incomeModel = TransactionCategoryModel.train(examples.filter { income.contains($0.categoryID) })!
        let holdout: [(String, String)] = [
            ("Supermercado Los Pinos compra tarjeta", "Supermercado"),
            ("Restaurante Mirador cena tarjeta", "Restaurantes"),
            ("Recarga billete metro metropolitano", "Transporte"),
            ("Gasolinera Amanecer combustible", "Coche"),
            ("Farmacia Rivera receta médica", "Farmacia"),
            ("Matrícula universidad ciencias", "Educación"),
            ("Factura telefonía móvil operador Brisa", "Internet y móvil"),
            ("Suscripción streaming plataforma Horizonte", "Suscripciones"),
            ("Póliza seguro de automóvil", "Seguros"),
            ("Reserva alojamiento Hotel Rocío", "Viajes"),
            ("Cuota alquiler de vivienda", "Vivienda"),
            ("Taller de bicicletas El Puente", "Transporte")
        ]
        var proposed = 0, correct = 0
        for (description, expected) in holdout {
            if let prediction = model.predict(description, allowed: expenses) {
                proposed += 1
                if prediction.categoryID == categories[expected] { correct += 1 }
            }
        }
        precondition(correct >= 6, "The model should recognize several unseen descriptions")
        precondition(incomeModel.predict("Abono intereses de mi depósito", allowed: income)?.categoryID == categories["Intereses"])
        precondition(model.predict("Reintegro efectivo cajero 0182", allowed: expenses)?.categoryID == categories["Retirada de efectivo"])
        precondition(incomeModel.predict("Ingreso efectivo cajero sucursal 04", allowed: income)?.categoryID == categories["Ingreso de efectivo"])
        precondition(model.predict("92746172039383", allowed: expenses) == nil)
        precondition(model.predict("Farmacia Plaza medicamentos", allowed: income) == nil)

        let transport = categories["Transporte"]!, purchases = categories["Compras"]!
        let prior = [
            TransactionCategoryModel.Example(text: "Tren billete movilidad", categoryID: transport, weight: 1),
            TransactionCategoryModel.Example(text: "Tienda accesorios compra", categoryID: purchases, weight: 1)
        ]
        let text = "RuedaNube abono trayecto semanal"
        let allowed: Set<UUID> = [transport, purchases]
        func prediction(afterConfirmation label: UUID) -> UUID? {
            let confirmed = TransactionCategoryModel.Example(text: "RuedaNube abono trayecto mensual", categoryID: label, weight: 5)
            return TransactionCategoryModel.train(prior + [confirmed])?.predict(text, allowed: allowed)?.categoryID
        }
        precondition(prediction(afterConfirmation: purchases) == purchases)
        precondition(prediction(afterConfirmation: transport) == transport,
                     "Replacing a confirmation should change prediction on a distinct text")
        // Brand catalogue (OpenStreetMap): the same lookup as Android (Tests/Fixtures/brand_lookup_cases.json),
        // consulted only when the model has nothing to propose.
        precondition(Set(BrandCatalogue.brands.keys).isSubset(of: Set(categories.keys)), "Every brand goes to a starter category")
        guard let data = FileManager.default.contents(atPath: "Tests/Fixtures/brand_lookup_cases.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = root["lookup"] as? [[String: Any]], !cases.isEmpty else { fatalError("Missing brand_lookup_cases.json") }
        for item in cases {
            let text = item["text"] as! String
            precondition(TransactionCategoryModel.brandCategory(text) == item["category"] as? String, "Brand lookup: \(text)")
        }
        precondition(model.predict("ZARA ESPANA SA", allowed: expenses) == nil, "The model alone does not know the brand")
        precondition(TransactionCategoryModel.brandCategory("ZARA ESPANA SA") == "Ropa")
        precondition(TransactionCategoryModel.brandCategory("BIZUM DE MERCADONA COMPAÑERO") == nil)
        print("Synthetic holdout: \(correct)/\(proposed) proposals correct, coverage \(proposed)/\(holdout.count). Correction and abstention passed.")
    }
}
